import Foundation

extension GridMath {
    /// A row of a chip strip: which chips, and how wide each is drawn.
    public struct StripRow: Equatable, Sendable {
        public var items: Range<Int>
        public var widths: [Double]
    }

    /// Chips of the given widths as a strip `width` wide. While they all fit
    /// one row, each is its own width plus an even share of the room left
    /// (`spread`), so the strip spans the width. Otherwise they go in even
    /// columns as wide as the widest chip, as many as fit, spread evenly over
    /// the rows (`rows`), so the rows line up under each other rather than
    /// each sharing out its own room. A chip wider than the strip gets the
    /// strip's width.
    public static func stripRows(widths: [Double], width: Double, spacing: Double) -> [StripRow] {
        guard !widths.isEmpty else { return [] }
        let total = widths.reduce(0, +) + spacing * Double(widths.count - 1)
        if total <= width + 1e-9 {
            return [StripRow(items: widths.indices, widths: spread(widths, across: width, spacing: spacing))]
        }
        let widest = min(widths.max() ?? 0, max(width, 0))
        let rows = rows(count: widths.count, width: width, minimum: widest, spacing: spacing)
        // A short last row keeps the columns' width, so it lines up too.
        let each = itemWidth(items: rows.first?.count ?? 1, width: width, spacing: spacing)
        return rows.map { StripRow(items: $0, widths: Array(repeating: each, count: $0.count)) }
    }
}
