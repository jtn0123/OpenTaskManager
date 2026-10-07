import Foundation

/// Row maths for card grids that always span the full width.
public enum GridMath {
    /// Splits `count` items into rows for a container `width` wide, using as
    /// many columns as fit at `minimum` width each and spreading the items
    /// evenly, so four cards that fit three across become two rows of two
    /// rather than three and one. Every row is filled edge to edge, so a
    /// missing card never leaves a hole.
    public static func rows(count: Int, width: Double, minimum: Double, spacing: Double) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let columns = columnCount(count: count, width: width, minimum: minimum, spacing: spacing)
        let rowCount = (count + columns - 1) / columns
        let perRow = (count + rowCount - 1) / rowCount
        return stride(from: 0, to: count, by: perRow).map { $0..<min($0 + perRow, count) }
    }

    /// How many columns of at least `minimum` fit in `width`, from one up to
    /// `count`, so a few cards still span the width.
    public static func columnCount(count: Int, width: Double, minimum: Double, spacing: Double) -> Int {
        let fitting = width.isFinite ? Int((width + spacing) / max(minimum + spacing, 1)) : count
        return min(max(fitting, 1), max(count, 1))
    }

    /// Where cards of the given heights go in `columns` columns that each
    /// run their own length: in order, each under whichever column is
    /// shortest so far (the leftmost of equals). A short card beside a long
    /// one then leaves no hole, as a row of even heights would inside it or
    /// a row of own heights would below it.
    public static func packColumns(heights: [Double], columns: Int, spacing: Double) -> ColumnPacking {
        // Each column's bottom, as if a spacing sat above its first card.
        var bottoms = [Double](repeating: -spacing, count: max(columns, 1))
        var packing = ColumnPacking(columns: [], tops: [], height: 0)
        for height in heights {
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            packing.columns.append(column)
            packing.tops.append(bottoms[column] + spacing)
            bottoms[column] += spacing + height
        }
        packing.height = max(bottoms.max() ?? 0, 0)
        return packing
    }

    /// Width of each of `items` cards sharing a row `width` wide.
    public static func itemWidth(items: Int, width: Double, spacing: Double) -> Double {
        guard items > 0 else { return 0 }
        return max((width - spacing * Double(items - 1)) / Double(items), 0)
    }

    /// Splits items of the given widths into rows, in order, using as few
    /// rows as fit in `width` and spreading the items evenly over them, so
    /// seven readings that fit six across become rows of four and three
    /// rather than six and one. An item wider than the row gets a row alone.
    public static func flowRows(widths: [Double], width: Double, spacing: Double) -> [Range<Int>] {
        let fewest = greedyRows(widths, limit: width, spacing: spacing)
        guard fewest.count > 1 else { return fewest }
        // Narrow the limit as far as it goes without needing another row.
        var low = widths.max() ?? 0
        var high = width
        for _ in 0..<40 where high - low > 0.5 {
            let middle = (low + high) / 2
            if greedyRows(widths, limit: middle, spacing: spacing).count <= fewest.count {
                high = middle
            } else {
                low = middle
            }
        }
        return greedyRows(widths, limit: high, spacing: spacing)
    }

    /// Widths for items sharing a row `width` wide: each its own width plus
    /// an even share of the room left over, so the row spans the width.
    public static func spread(_ widths: [Double], across width: Double, spacing: Double) -> [Double] {
        guard !widths.isEmpty else { return [] }
        let spare = width - widths.reduce(0, +) - spacing * Double(widths.count - 1)
        let extra = max(spare, 0) / Double(widths.count)
        return widths.map { $0 + extra }
    }

    /// Cards packed into columns by `packColumns`.
    public struct ColumnPacking: Equatable, Sendable {
        /// Each card's column, in order.
        public var columns: [Int]
        /// Each card's top, from the top of the grid.
        public var tops: [Double]
        /// The longest column's length.
        public var height: Double
    }

    /// As many items on each row as fit within `limit`, in order.
    private static func greedyRows(_ widths: [Double], limit: Double, spacing: Double) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var used = 0.0
        for (index, width) in widths.enumerated() {
            if index > start, used + spacing + width > limit + 1e-9 {
                rows.append(start..<index)
                start = index
                used = width
            } else {
                used += index > start ? spacing + width : width
            }
        }
        if start < widths.count { rows.append(start..<widths.count) }
        return rows
    }
}
