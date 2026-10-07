import OTMKit
import SwiftUI

/// Everything about one socket: who owns it, both ends, the service, and
/// what its scope means in plain words.
struct ConnectionDetail: View {
    var row: ConnectionRow
    var showProcess: () -> Void
    var close: () -> Void

    var body: some View {
        let connection = row.connection
        Card {
            HStack(spacing: 8) {
                Text("Connection").font(.metadata.weight(.medium)).foregroundStyle(.secondaryText)
                Text(connection.stateLabel)
                    .font(.metadata.weight(.semibold))
                    .foregroundStyle(connection.kind.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(connection.kind.tint.opacity(0.15), in: Capsule())
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close the details")
            }
            HStack(spacing: 10) {
                Image(nsImage: row.icon).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.processName).font(.headline).lineLimit(1)
                    Text(verbatim: "PID \(connection.pid) · descriptor \(connection.id.fd)")
                        .font(.metadata).foregroundStyle(.secondaryText).lineLimit(1)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                FactRow(label: "Local", value: connection.local.formatted)
                FactRow(label: "Remote", value: connection.remote?.formatted ?? "—")
                FactRow(label: "Protocol", value: "\(connection.transport.rawValue) over \(connection.family.rawValue)")
                FactRow(label: "Service", value: connection.service.map { "\($0.name) (port \($0.port))" } ?? "—")
                FactRow(label: "Scope", value: connection.scope.label)
            }

            Label {
                Text(Self.explanation(for: connection))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: connection.isExposed ? "exclamationmark.shield" : connection.scope.symbol)
                    .foregroundStyle(connection.isExposed ? ConnectionTint.orange : connection.scope.tint)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((connection.isExposed ? ConnectionTint.orange : connection.scope.tint).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8))

            Button(action: showProcess) {
                Label("Show Process", systemImage: "list.bullet.rectangle")
            }
            .help("Open the Processes page with this process selected")
        }
    }

    /// What the scope means for this socket.
    static func explanation(for connection: Connection) -> String {
        let connected = connection.remote != nil
        switch connection.scope {
        case .loopback:
            return "Only programs on this Mac can reach this socket. Loopback traffic never leaves the computer."
        case .allInterfaces:
            switch connection.kind {
            case .listening:
                return "Listening on every network interface, so other devices can connect unless the macOS firewall blocks it."
            case .udpBound:
                return "Bound on every network interface, so it takes datagrams from other devices unless the macOS firewall blocks them."
            default:
                return "Bound to every network interface, but not accepting connections."
            }
        case .localNetwork:
            return connected
                ? "The other end has a private, link-local or unique-local address: a device on your network, or a VPN peer."
                : "Bound to an address on your local network, so devices on that network can reach it."
        case .internet:
            return connected
                ? "The other end has a public internet address."
                : "Bound to a public address, so it can be reached from the internet unless a firewall blocks it."
        }
    }
}
