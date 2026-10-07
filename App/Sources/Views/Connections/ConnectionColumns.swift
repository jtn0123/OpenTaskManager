import AppKit
import OTMKit

/// Columns of the socket table. The raw value is the column's customization ID.
enum ConnectionColumn: String, CaseIterable {
    case process, pid, transport = "protocol", local, remote, state, scope

    var title: String {
        switch self {
        case .process: "Process"
        case .pid: "PID"
        case .transport: "Protocol"
        case .local: "Local"
        case .remote: "Remote"
        case .state: "State"
        case .scope: "Scope"
        }
    }

    /// Narrowest the column gets, and the width it starts at before the table
    /// shares out its room: enough for its usual values whole at the table's
    /// 13 points ("47744", "Established", "127.0.0.1:54321"). Longer
    /// addresses are cut in the middle, never their port; Scope keeps just its
    /// symbol, and Protocol the short "TCP4".
    var minWidth: CGFloat {
        switch self {
        case .process: 100
        case .pid: 46
        case .transport: 54
        case .local, .remote: 112
        case .state: 74
        case .scope: 44
        }
    }

    /// Short values stop growing here; Process and the endpoints take the rest.
    var maxWidth: CGFloat? {
        switch self {
        case .pid: 80
        case .transport: 110
        case .state: 130
        case .scope: 170
        case .process, .local, .remote: nil
        }
    }

    /// When the table runs short of room, columns give way lowest priority
    /// first (`ColumnFit`, as on the Processes table), so the ones that say
    /// whose socket a row is, between which ends and in what state, keep
    /// their width. The details pane gives all three that hide.
    var priority: Int? {
        switch self {
        case .process, .local, .remote, .state: nil
        case .scope: 3
        case .pid: 2
        // The State column already tells TCP ("Listening") from UDP ("Bound").
        case .transport: 1
        }
    }

    /// The columns that give way when there isn't room.
    static let givingWay = Set(allCases.filter { $0.priority != nil })

    /// The column's line in the Columns menu; says why when it's on but hidden.
    func menuTitle(hiddenToFit: Bool) -> String {
        hiddenToFit ? "\(title) (hidden to fit)" : title
    }

    /// NSTableView's gap between columns, which SwiftUI's table keeps.
    private static let spacing: CGFloat = 17

    /// The table's side insets, and a vertical scroller where scroll bars
    /// always show (a mouse rather than a trackpad), which takes room of its own.
    @MainActor private static var chrome: CGFloat {
        2 * 10 + (NSScroller.preferredScrollerStyle == .legacy ? 16 : 0)
    }

    /// The columns the user has on, in order, with the room each needs.
    private static func wanted(userHidden: Set<ConnectionColumn>) -> [ColumnFit.Column<ConnectionColumn>] {
        allCases.filter { !userHidden.contains($0) }.map {
            ColumnFit.Column(id: $0, width: Double($0.minWidth + spacing), priority: $0.priority)
        }
    }

    /// Columns that are on but don't fit a table `width` points wide.
    @MainActor static func hiddenToFit(width: CGFloat, userHidden: Set<ConnectionColumn>) -> Set<ConnectionColumn> {
        ColumnFit.hidden(wanted(userHidden: userHidden), available: Double(width - chrome))
    }

    /// Narrowest the table goes without scrolling sideways, once every
    /// column that can has given way. Beside the details pane it never gets less.
    @MainActor static func tableMinimum(userHidden: Set<ConnectionColumn>) -> CGFloat {
        CGFloat(ColumnFit.minimumWidth(wanted(userHidden: userHidden))) + chrome
    }
}

/// The columns switched off in the Columns menu, saved as "pid,protocol".
/// Process can't be.
struct HiddenConnectionColumns: RawRepresentable, Equatable {
    var columns: Set<ConnectionColumn>

    init(columns: Set<ConnectionColumn> = []) {
        self.columns = columns.subtracting([.process])
    }

    init?(rawValue: String) {
        self.init(columns: Set(rawValue.split(separator: ",").compactMap { ConnectionColumn(rawValue: String($0)) }))
    }

    var rawValue: String {
        columns.map(\.rawValue).sorted().joined(separator: ",")
    }

    func isOn(_ column: ConnectionColumn) -> Bool {
        !columns.contains(column)
    }

    mutating func toggle(_ column: ConnectionColumn) {
        guard column != .process else { return }
        if columns.contains(column) { columns.remove(column) } else { columns.insert(column) }
    }
}
