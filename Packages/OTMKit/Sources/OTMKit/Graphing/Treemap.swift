import CoreGraphics
import Foundation

/// Squarified treemap layout: tiles whose areas are proportional to their
/// values, laid in rows chosen so each tile stays as close to square as it
/// can (after Bruls, Huizing and van Wijk's squarified treemaps).
public enum Treemap {
    /// One rectangle per value, in the order given, together filling
    /// `bounds`. The largest value lands in the top-left corner and the rest
    /// follow in falling order. Values that are zero, negative or not finite
    /// get an empty rectangle at the bottom-right corner.
    public static func squarify(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        var rects = Array(repeating: CGRect(x: bounds.maxX, y: bounds.maxY, width: 0, height: 0), count: values.count)
        let order = values.indices
            .filter { values[$0] > 0 && values[$0].isFinite }
            .sorted { values[$0] != values[$1] ? values[$0] > values[$1] : $0 < $1 }
        let total = order.reduce(0.0) { $0 + values[$1] }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return rects }

        let scale = Double(bounds.width * bounds.height) / total
        var layout = RowLayout(remaining: bounds)
        var row = Row()
        var position = 0
        while position < order.count {
            let index = order[position]
            let area = values[index] * scale
            let side = Double(min(layout.remaining.width, layout.remaining.height))
            if row.isEmpty || row.adding(area).worstAspect(side: side) <= row.worstAspect(side: side) {
                row = row.adding(area, index: index)
                position += 1
            } else {
                layout.place(row, isLast: false, into: &rects)
                row = Row()
            }
        }
        layout.place(row, isLast: true, into: &rects)
        return rects
    }

    /// The tiles in one strip, with what the aspect test needs.
    private struct Row {
        var indices: [Int] = []
        var areas: [Double] = []
        var sum = 0.0
        var smallest = Double.infinity
        var largest = 0.0

        var isEmpty: Bool { indices.isEmpty }

        func adding(_ area: Double, index: Int = -1) -> Row {
            var row = self
            row.indices.append(index)
            row.areas.append(area)
            row.sum += area
            row.smallest = min(smallest, area)
            row.largest = max(largest, area)
            return row
        }

        /// The most elongated tile's aspect ratio (≥ 1) if the row lies along a side `side` long.
        func worstAspect(side: Double) -> Double {
            guard sum > 0, side > 0 else { return .infinity }
            let squaredSide = side * side
            let squaredSum = sum * sum
            return max(squaredSide * largest / squaredSum, squaredSum / (squaredSide * smallest))
        }
    }

    /// The part of the bounds still empty, which each placed row shrinks.
    private struct RowLayout {
        var remaining: CGRect

        /// Lays a row along the shorter side of the space left: a column at
        /// the left when it's wider than tall, a strip at the top otherwise.
        /// The last tile of each row, and the last row, take whatever is left
        /// so rounding never leaves a sliver uncovered.
        mutating func place(_ row: Row, isLast: Bool, into rects: inout [CGRect]) {
            guard !row.isEmpty else { return }
            if remaining.width >= remaining.height {
                let width = isLast ? remaining.width : CGFloat(row.sum / Double(remaining.height))
                var y = remaining.minY
                for (offset, index) in row.indices.enumerated() {
                    let height = offset == row.indices.count - 1 ? remaining.maxY - y : CGFloat(row.areas[offset]) / width
                    rects[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                let height = isLast ? remaining.height : CGFloat(row.sum / Double(remaining.width))
                var x = remaining.minX
                for (offset, index) in row.indices.enumerated() {
                    let width = offset == row.indices.count - 1 ? remaining.maxX - x : CGFloat(row.areas[offset]) / height
                    rects[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(remaining.height - height, 0))
            }
        }
    }
}
