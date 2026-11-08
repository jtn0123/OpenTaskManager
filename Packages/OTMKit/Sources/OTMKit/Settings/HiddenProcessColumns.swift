import Foundation

/// The columns switched off in the Columns menu, and the ones this Mac can't
/// fill that were switched on anyway, saved as "kind,threads,+power".
public struct HiddenProcessColumns: RawRepresentable, Equatable, Sendable {
    public var columns: Set<ProcessColumn>
    /// Unreported columns (see `ProcessColumn.unreported`) the user turned
    /// on, to see the dashes. The others stay hidden.
    public var shownAnyway: Set<ProcessColumn> = []

    public static let defaults = HiddenProcessColumns(columns: [.threads, .wakeups, .kind, .topTier])

    public init(columns: Set<ProcessColumn>) {
        self.columns = columns
    }

    public init?(rawValue: String) {
        let entries = rawValue.split(separator: ",")
        columns = Set(entries.compactMap { ProcessColumn(rawValue: String($0)) })
        shownAnyway = Set(entries.compactMap { $0.first == "+" ? ProcessColumn(rawValue: String($0.dropFirst())) : nil })
    }

    public var rawValue: String {
        (columns.map(\.rawValue) + shownAnyway.map { "+" + $0.rawValue }).sorted().joined(separator: ",")
    }

    /// Hidden by choice, or because this Mac doesn't report it.
    public func hidden(unreported: Set<ProcessColumn>) -> Set<ProcessColumn> {
        columns.union(unreported.subtracting(shownAnyway))
    }

    public func isOn(_ column: ProcessColumn, unreported: Set<ProcessColumn>) -> Bool {
        !hidden(unreported: unreported).contains(column)
    }

    /// Switches a column on or off. An unreported column switched off goes
    /// back to hiding by itself, so it shows again on a Mac that reports it.
    public mutating func toggle(_ column: ProcessColumn, unreported: Set<ProcessColumn>) {
        guard column != .name else { return }
        if isOn(column, unreported: unreported) {
            if unreported.contains(column) { shownAnyway.remove(column) } else { columns.insert(column) }
        } else {
            columns.remove(column)
            if unreported.contains(column) { shownAnyway.insert(column) }
        }
    }
}
