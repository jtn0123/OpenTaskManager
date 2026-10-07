import Foundation

/// Width maths for a table whose less important columns give way, one at a
/// time, as it runs out of room, so the columns that say what a row is keep
/// theirs instead of everything shrinking or running past the edge.
public enum ColumnFit {
    /// A column the table could show.
    public struct Column<ID: Hashable>: Equatable {
        public var id: ID
        /// Room the column takes when shown, its gap included. For the column
        /// that fills the slack, the narrowest it should get.
        public var width: Double
        /// Lower priorities give way first. Nil for a column that always stays.
        public var priority: Int?

        public init(id: ID, width: Double, priority: Int?) {
            self.id = id
            self.width = width
            self.priority = priority
        }
    }

    /// The columns to hide so the rest fit in `available` points. `columns`
    /// are the ones the user wants, in display order. They give way lowest
    /// priority first, the rightmost of equals first, and one never stays
    /// while a column that outranks it is hidden, so what shows doesn't
    /// jump around as the width changes. Columns that always stay are kept
    /// even when they overflow; the table then scrolls sideways.
    public static func hidden<ID>(_ columns: [Column<ID>], available: Double) -> Set<ID> {
        var used = columns.reduce(0) { $0 + $1.width }
        guard used > available else { return [] }
        let givingWay = columns.indices
            .filter { columns[$0].priority != nil }
            .sorted { lhs, rhs in
                let left = columns[lhs].priority ?? 0
                let right = columns[rhs].priority ?? 0
                return left != right ? left < right : lhs > rhs
            }
        var hidden: Set<ID> = []
        for index in givingWay where used > available {
            hidden.insert(columns[index].id)
            used -= columns[index].width
        }
        return hidden
    }

    /// Width the columns need once every one that can give way has.
    public static func minimumWidth<ID>(_ columns: [Column<ID>]) -> Double {
        columns.filter { $0.priority == nil }.reduce(0) { $0 + $1.width }
    }
}
