import Foundation

/// The columns switched off in the Columns menu, saved as "pid,protocol".
/// Process can't be.
public struct HiddenConnectionColumns: RawRepresentable, Equatable, Sendable {
    public var columns: Set<ConnectionColumn>

    public init(columns: Set<ConnectionColumn> = []) {
        self.columns = columns.subtracting([.process])
    }

    public init?(rawValue: String) {
        self.init(columns: Set(rawValue.split(separator: ",").compactMap { ConnectionColumn(rawValue: String($0)) }))
    }

    public var rawValue: String {
        columns.map(\.rawValue).sorted().joined(separator: ",")
    }

    public func isOn(_ column: ConnectionColumn) -> Bool {
        !columns.contains(column)
    }

    public mutating func toggle(_ column: ConnectionColumn) {
        guard column != .process else { return }
        if columns.contains(column) { columns.remove(column) } else { columns.insert(column) }
    }
}
