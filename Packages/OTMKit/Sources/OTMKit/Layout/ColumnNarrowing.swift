import Foundation

public extension ColumnFit {
    /// Widths for columns that run `excess` points past their table's edge.
    /// Each gives up a share in proportion to its room above its minimum,
    /// so the widest narrow most and none goes under its minimum; with less
    /// room than that in all, every column ends at its minimum.
    ///
    /// `widths` and `minimums` are in the same order, one per shown column.
    static func narrowed(widths: [Double], minimums: [Double], by excess: Double) -> [Double] {
        let room = zip(widths, minimums).map { max(0, $0 - $1) }
        let total = room.reduce(0, +)
        guard excess > 0, total > 0 else { return widths }
        let share = min(excess, total) / total
        return zip(widths, room).map { $0 - $1 * share }
    }
}
