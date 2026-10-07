import OTMKit
import SwiftUI

/// Sockets in a sortable table. Rows change only when the store refreshes
/// (every few seconds), never on the main sampler's tick.
struct ConnectionTable: View {
    var rows: [ConnectionRow]
    @Binding var selection: Connection.ID?
    @Binding var sortOrder: [KeyPathComparator<ConnectionRow>]

    /// The columns' minimum widths and the gaps between them.
    static let minimumWidth: CGFloat = 90 + 38 + 56 + 80 + 80 + 60 + 80 + 7 * 17

    // Ideal widths are the least each column needs for typical content (an
    // IPv4 address and port, "All interfaces"). They add up to what's left
    // beside the details pane in a 1290-point window; with more room the
    // table stretches the columns to fill it.
    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.processName) { row in
                HStack(spacing: 6) {
                    Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                    Text(row.processName).lineLimit(1)
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn("PID", value: \.pid) { row in
                Text(verbatim: String(row.pid)).monospacedDigit().foregroundStyle(.secondaryText)
            }
            .width(min: 38, ideal: 46, max: 80)

            TableColumn("Protocol", value: \.protocolName) { row in
                ProtocolLabel(connection: row.connection)
            }
            .width(min: 56, ideal: 72, max: 110)

            TableColumn("Local", value: \.localOrder) { row in
                Text(row.connection.local.formatted).monospacedDigit().lineLimit(1).truncationMode(.middle)
            }
            .width(min: 80, ideal: 124)

            TableColumn("Remote", value: \.remoteOrder) { row in
                if let remote = row.connection.remote {
                    Text(remote.formatted).monospacedDigit().lineLimit(1).truncationMode(.middle)
                } else {
                    Text("—").foregroundStyle(.tertiaryText)
                }
            }
            .width(min: 80, ideal: 130)

            TableColumn("State", value: \.stateOrder) { row in
                Text(row.connection.stateLabel).lineLimit(1).foregroundStyle(row.connection.kind.tint)
            }
            .width(min: 60, ideal: 76, max: 130)

            TableColumn("Scope", value: \.scopeOrder) { row in
                // The symbol alone once the column is too narrow for the words.
                ViewThatFits(in: .horizontal) {
                    ScopeLabel(connection: row.connection)
                    ScopeLabel(connection: row.connection).labelStyle(.iconOnly)
                }
                .help(row.connection.scope.label)
            }
            .width(min: 80, ideal: 114, max: 170)
        }
    }
}

/// "UDP IPv4" while it fits, then netstat's shorter "UDP4", so a narrow
/// window doesn't cut it to "U…".
private struct ProtocolLabel: View {
    var connection: Connection

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Text(connection.transport.rawValue)
                Text(connection.family.shortLabel).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 0) {
                Text(connection.transport.rawValue)
                Text(connection.family.digits).foregroundStyle(.secondaryText)
            }
        }
        .lineLimit(1)
        .help("\(connection.transport.rawValue) over \(connection.family.rawValue)")
    }
}

/// Scope with its icon; exposed sockets get a warning tint.
struct ScopeLabel: View {
    var connection: Connection

    var body: some View {
        Label {
            Text(connection.scope.label).lineLimit(1)
        } icon: {
            Image(systemName: connection.scope.symbol)
                .foregroundStyle(connection.isExposed ? ConnectionTint.orange : connection.scope.tint)
        }
    }
}

// MARK: - Styling

/// The system colours, deepened in light mode (see `Theme.data`), where the
/// plain ones are too pale to read as text on white.
enum ConnectionTint {
    static let green = Theme.data(.systemGreen)
    static let blue = Theme.data(.systemBlue)
    static let orange = Theme.data(.systemOrange)
    static let teal = Theme.data(.systemTeal)
    static let purple = Theme.data(.systemPurple)
}

extension ConnectionKind {
    /// State text colour: listening green, established blue, and the rest
    /// fading as they wind down.
    var tint: Color {
        switch self {
        case .listening: ConnectionTint.green
        case .established: ConnectionTint.blue
        case .connecting: ConnectionTint.orange
        case .closing: .gray
        case .closed: .secondary
        case .udpBound: ConnectionTint.teal
        case .udpConnected: ConnectionTint.purple
        }
    }
}

extension AddressScope {
    var symbol: String {
        switch self {
        case .loopback: "arrow.uturn.backward"
        case .localNetwork: "house"
        case .internet: "globe"
        case .allInterfaces: "dot.radiowaves.left.and.right"
        }
    }

    var tint: Color {
        switch self {
        case .loopback: .secondary
        case .localNetwork: ConnectionTint.teal
        case .internet: ConnectionTint.blue
        case .allInterfaces: ConnectionTint.orange
        }
    }
}

extension Connection.Family {
    var shortLabel: String {
        switch self {
        case .ipv4: "IPv4"
        case .ipv6: "IPv6"
        case .dual: "IPv4/6"
        }
    }

    /// The version alone, as netstat appends it ("tcp46").
    var digits: String {
        switch self {
        case .ipv4: "4"
        case .ipv6: "6"
        case .dual: "46"
        }
    }
}
