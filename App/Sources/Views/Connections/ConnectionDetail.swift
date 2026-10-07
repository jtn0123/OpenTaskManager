import AppKit
import OTMKit
import SwiftUI

/// Everything about one socket: who owns it, both ends, the service, and
/// what its scope means in plain words. Whose socket it is and its state stay
/// at the top and the actions in a footer, and the facts scroll between
/// them, in the pane's only scroll view.
struct ConnectionDetail: View {
    /// Room the facts keep under the pinned top before it scrolls too.
    private static let detailsMinimum: CGFloat = 96

    var row: ConnectionRow
    var showProcess: () -> Void
    /// Closes the pane beside the table; nil while it covers the table, where
    /// the Back button does that.
    var close: (() -> Void)?

    /// The pane's height, and the header's and actions' as laid out.
    @State private var height: CGFloat?
    @State private var headerHeight: CGFloat = 0
    @State private var actionsHeight: CGFloat = 0

    /// A pane's minimum height becomes the page's, so in one too short for
    /// the pinned top and a few lines of facts, the top scrolls with them
    /// and only the actions stay put (as `StartupItemDetail` does).
    ///
    /// Chosen from the measured heights rather than with `ViewThatFits`,
    /// which measured both layouts again on every tick of the traffic card
    /// (about two percent of a core).
    var body: some View {
        let pinsHeader = height.map { $0 >= headerHeight + 24 + Self.detailsMinimum + actionsHeight + 2 } ?? true
        VStack(spacing: 0) {
            if pinsHeader {
                measuredHeader
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ScrollView { details.padding(12) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        measuredHeader
                        details
                    }
                    .padding(12)
                }
            }
            Divider()
            actions
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsHeight = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    private var measuredHeader: some View {
        header.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    // MARK: Sections

    private var header: some View {
        let connection = row.connection
        return HStack(alignment: .top, spacing: 10) {
            Image(nsImage: row.icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.processName).font(.headline).lineLimit(1).help(row.processName)
                    Text(connection.stateLabel)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(connection.kind.tint)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(connection.kind.tint.opacity(0.15), in: Capsule())
                }
                Text(verbatim: "PID \(connection.pid) · descriptor \(connection.id.fd)")
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close the details")
                .accessibilityLabel("Close the details")
            }
        }
    }

    private var details: some View {
        let connection = row.connection
        return VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                EndpointRow(label: "Local", endpoint: connection.local)
                if let remote = connection.remote {
                    EndpointRow(label: "Remote", endpoint: remote)
                } else {
                    FactRow(label: "Remote", value: "—")
                }
                FactRow(label: "Protocol", value: "\(connection.transport.rawValue) over \(connection.family.rawValue)")
                FactRow(label: "Service", value: connection.service.map { "\($0.name) (port \($0.port))" } ?? "—")
                FactRow(label: "Scope", value: connection.scope.label)
            }

            Label {
                Text(Self.explanation(for: connection))
            } icon: {
                Image(systemName: connection.isExposed ? "exclamationmark.shield" : connection.scope.symbol)
                    .foregroundStyle(connection.isExposed ? ConnectionTint.orange : connection.scope.tint)
            }
            .font(.body)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((connection.isExposed ? ConnectionTint.orange : connection.scope.tint).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Side by side while they fit, then without their icons (as in the
    /// default-width pane), else one over the other: wrapped, not cut.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                showProcessButton
                CopyEndpointButton(connection: row.connection)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                showProcessButton
                CopyEndpointButton(connection: row.connection)
                Spacer(minLength: 0)
            }
            .labelStyle(.titleOnly)
            VStack(alignment: .leading, spacing: 8) {
                showProcessButton
                CopyEndpointButton(connection: row.connection)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var showProcessButton: some View {
        Button(action: showProcess) {
            Label("Show Process", systemImage: "list.bullet.rectangle")
        }
        .fixedSize()
        .help("Open the Processes page with this process selected")
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

/// An end of the socket, whole and wrapping if it's long, with a copy
/// button while the pointer is over it.
private struct EndpointRow: View {
    var label: String
    var endpoint: Endpoint

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondaryText).gridColumnAlignment(.leading)
            CopyableText(value: endpoint.formatted, monospaced: false)
                .monospacedDigit()
                .gridColumnAlignment(.leading)
        }
        .font(.callout)
    }
}

/// Copies the socket's local end, or with a remote end, a menu of both.
/// Says "Copied" for a moment after.
private struct CopyEndpointButton: View {
    var connection: Connection
    @State private var copied = false

    var body: some View {
        Group {
            if let remote = connection.remote {
                Menu {
                    Button("Local: \(connection.local.formatted)") { copy(connection.local) }
                    Button("Remote: \(remote.formatted)") { copy(remote) }
                } label: {
                    label
                }
                .help("Copy the local or remote end, address and port")
            } else {
                Button { copy(connection.local) } label: { label }
                    .help("Copy the local end, \(connection.local.formatted)")
            }
        }
        .fixedSize()
    }

    private var label: some View {
        Label(copied ? "Copied" : "Copy Endpoint", systemImage: copied ? "checkmark" : "doc.on.doc")
    }

    private func copy(_ endpoint: Endpoint) {
        ConnectionActions.copy(endpoint)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// What the table's context menu and the details share.
enum ConnectionActions {
    /// The endpoint as the table shows it: `127.0.0.1:54321`, `[::1]:443`, `*:22`.
    static func copy(_ endpoint: Endpoint) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint.formatted, forType: .string)
    }
}
