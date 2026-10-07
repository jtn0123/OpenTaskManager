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
                    // A closed socket's last state is in its timeline.
                    let tint = row.isOpen ? connection.kind.tint : Color.secondary
                    Text(row.isOpen ? connection.stateLabel : "Closed")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(row.isOpen ? AnyShapeStyle(tint) : AnyShapeStyle(.secondaryText))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.15), in: Capsule())
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

            // What the scope means is for a socket that's still there.
            if row.isOpen {
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

            ObservedTimeline(socket: row.socket)
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
        // A closed socket's process may have ended, and its PID gone to another.
        .disabled(!row.processRunning)
        .help(row.processRunning ? "Open the Processes page with this process selected" : "Its process has ended")
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

/// What the page saw the socket do, oldest first: when a walk first found
/// it, each change of state or peer, stretches the page didn't watch, and
/// its closing. Times are the walks', never the kernel's, which keeps none.
private struct ObservedTimeline: View {
    /// A step, or the steps left out of a long timeline after its first.
    private enum Step {
        case event(ConnectionEvent)
        case dropped(Int)
    }

    var socket: ObservedConnection

    var body: some View {
        let steps = steps
        let seconds = Int(ConnectionStore.refreshInterval.components.seconds)
        VStack(alignment: .leading, spacing: 8) {
            Text("Seen by this page").font(.callout.weight(.semibold))
            Text(socket.seenSummary(time: ConnectionClock.time))
                .font(.explanation)
                .foregroundStyle(.secondaryText)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps.indices, id: \.self) { index in
                    row(steps[index], isLast: index == steps.count - 1)
                }
            }
            .padding(.top, 2)
            Text("""
            The page reads sockets every \(seconds) s while it's open, so each step happened in the \(seconds) s \
            before its time.
            """)
            .font(.explanation)
            .foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var steps: [Step] {
        var steps = socket.timeline.map(Step.event)
        if socket.droppedEvents > 0 { steps.insert(.dropped(socket.droppedEvents), at: min(1, steps.count)) }
        return steps
    }

    /// A dot on the rail, then what happened and when. The rail runs on to
    /// the next step, dashed over a stretch the page didn't watch.
    private func row(_ step: Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                marker(step).frame(width: 9, height: 9).padding(.top, 3)
                if !isLast {
                    RailLine()
                        .stroke(Color.secondary.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1.5, dash: isGap(step) ? [3, 3] : []))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(step)).font(.callout)
                if let caption = caption(step) {
                    Text(caption).font(.explanation).foregroundStyle(.secondaryText)
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
        // Inside the pane's scroll view, so the rail can take the text's height.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func marker(_ step: Step) -> some View {
        switch step {
        case let .event(event):
            switch event.kind {
            case let .opened(phase), let .changed(phase): Circle().fill(phase.kind.tint)
            case .unwatched: Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            case .closed: Circle().fill(Color.secondary)
            }
        case .dropped:
            Circle().fill(Color.secondary.opacity(0.4)).padding(2)
        }
    }

    private func isGap(_ step: Step) -> Bool {
        if case let .event(event) = step, event.kind == .unwatched { return true }
        return false
    }

    private func title(_ step: Step) -> String {
        switch step {
        case let .event(event): event.title
        case let .dropped(count): count == 1 ? "1 more step" : "\(count.formatted()) more steps"
        }
    }

    /// When: the walk's time, or for a stretch not watched, its start; and
    /// a note where the time alone would claim too much.
    private func caption(_ step: Step) -> String? {
        guard case let .event(event) = step else { return "Left out to keep the list short" }
        let time = ConnectionClock.time(event.kind == .unwatched ? event.after ?? event.time : event.time)
        return event.note(time: ConnectionClock.time).map { "\(time) · \($0)" } ?? time
    }
}

/// A vertical line down the middle of its frame.
private struct RailLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
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
