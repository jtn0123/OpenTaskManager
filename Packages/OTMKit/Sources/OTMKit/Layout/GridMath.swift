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
        let fitting = width.isFinite ? Int((width + spacing) / max(minimum + spacing, 1)) : count
        let columns = min(max(fitting, 1), count)
        let rowCount = (count + columns - 1) / columns
        let perRow = (count + rowCount - 1) / rowCount
        return stride(from: 0, to: count, by: perRow).map { $0..<min($0 + perRow, count) }
    }

    /// Width of each of `items` cards sharing a row `width` wide.
    public static func itemWidth(items: Int, width: Double, spacing: Double) -> Double {
        guard items > 0 else { return 0 }
        return max((width - spacing * Double(items - 1)) / Double(items), 0)
    }
}
