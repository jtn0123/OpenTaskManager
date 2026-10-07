import OTMKit
import SwiftUI

/// Every TCP and UDP socket on the Mac, by process: what's listening, what's
/// reachable from the network, and who each app is talking to.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("page") private var page: Page = .overview
    @State private var store = ConnectionStore()
    @State private var filter: ConnectionFilter = .all
    @State private var search = ""
    @State private var selection: Connection.ID?
    @State private var openedRequest = false
    /// The window is too narrow for the table and the details side by side.
    @State private var isNarrow = false
    /// In a narrow window, the details cover the table.
    @State private var showsFullDetail = false
    @State private var sortOrder = [KeyPathComparator(\ConnectionRow.processName)]

    var body: some View {
        Group {
            if store.hasLoaded {
                content
            } else {
                ProgressView("Reading sockets…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Process, address or port")
        // Runs only while the page is on screen; SwiftUI cancels it when the
        // page goes away, and restarts it when updates are paused or resumed.
        .task(id: model.isPaused) { await store.run(model: model) }
    }

    private var content: some View {
        let shown = store.rows.filter { filter.matches($0.connection) && $0.matches(search) }.sorted(using: sortOrder)
        let selected = selection.flatMap { id in store.rows.first { $0.id == id } }
        return VStack(spacing: 0) {
            // The five counts and the traffic card share one grid: a single row
            // in the default window, two even rows in the narrowest.
            SummaryCards(summary: store.summary)
                .fixedSize(horizontal: false, vertical: true)
                .padding([.horizontal, .top], 16)
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            // Like the Processes inspector, details only take room once
            // there's something to show, so the table gets the full width.
            InspectorSplit(
                listMinimum: ConnectionTable.minimumWidth,
                wantsInspector: selected != nil,
                coversList: $showsFullDetail,
                isNarrow: $isNarrow,
                widthKey: "connectionInspectorWidth",
                backTitle: "Connections"
            ) {
                VStack(spacing: 0) {
                    // Only as tall as its rows, so no empty stripes follow the
                    // last socket; with more rows than room it fills and scrolls.
                    ConnectionTable(rows: shown, selection: $selection, sortOrder: $sortOrder)
                        .fitsTableToRows(shown.count)
                        .layoutPriority(1)
                    Divider()
                    tableFooter(shown: shown.count)
                    Spacer(minLength: 0)
                }
            } detail: {
                if let selected {
                    ScrollView {
                        ConnectionDetail(row: selected, showProcess: { showProcess(selected.pid) },
                                         close: { selection = nil })
                            .padding(12)
                    }
                }
            }
        }
        .onAppear(perform: selectRequestedConnection)
        // The details come with a selection here, so in a narrow window
        // picking a socket opens them, and Back returns to the table.
        .onChange(of: selection) {
            if isNarrow { showsFullDetail = selection != nil }
        }
        // Back clears the selection, so picking the same socket opens it again.
        .onChange(of: showsFullDetail) {
            if isNarrow, !showsFullDetail { selection = nil }
        }
    }

    /// `--args -openConnection 443` selects the first socket matching that
    /// search (a port, address or process name) once, for screenshots.
    private func selectRequestedConnection() {
        guard !openedRequest, selection == nil, let query = LaunchArgument.string("openConnection") else { return }
        openedRequest = true
        selection = store.rows.sorted(using: sortOrder).first { $0.matches(query) }?.id
    }

    /// The filters, and beside them, right under the counts, how many sockets
    /// the counts and the table cover, and that other users' processes are
    /// left out. In a window too narrow for both, the note takes a line of
    /// its own under the filters.
    private var filterBar: some View {
        FilterBarLayout {
            Picker("Show", selection: $filter) {
                ForEach(ConnectionFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Established TCP connections, TCP listeners, sockets other devices can reach, or UDP only")
            if store.hiddenProcesses > 0 {
                let (visible, hidden) = (store.rows.count, store.hiddenProcesses)
                ViewThatFits(in: .horizontal) {
                    ScopeBadge(visible: visible, hidden: hidden, length: .long)
                    ScopeBadge(visible: visible, hidden: hidden, length: .short)
                    ScopeBadge(visible: visible, hidden: hidden, length: .shortest)
                }
            }
        }
    }

    /// Right under the last row: how many sockets show, and how often they're
    /// read. Detail drops out as the table narrows, so it stays one line.
    private func tableFooter(shown: Int) -> some View {
        let total = store.rows.count
        let sockets = Self.count(total, "socket", "sockets")
        let count = shown == total ? sockets : shown == 0 ? "None of \(sockets) match" : "\(shown.formatted()) of \(sockets)"
        let processes = Self.count(store.summary.processesWithSockets, "process", "processes") + " with sockets"
        return ViewThatFits(in: .horizontal) {
            footerLine(count: count, processes: processes, showsCadence: true)
            footerLine(count: count, processes: nil, showsCadence: true)
            footerLine(count: count, processes: nil, showsCadence: false)
        }
        .font(.metadata)
        .foregroundStyle(.secondaryText)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func footerLine(count: String, processes: String?, showsCadence: Bool) -> some View {
        HStack(spacing: 14) {
            Text(count).foregroundStyle(Color.primary)
            if let processes { Text(processes) }
            if showsCadence {
                Spacer(minLength: 12)
                Text("Updates every \(Int(ConnectionStore.refreshInterval.components.seconds)) s")
                    .help("""
                    Read every \(Int(ConnectionStore.refreshInterval.components.seconds)) s while this page is open. The last \
                    walk of every process's sockets took \(Format.fixed(store.walkDuration * 1000, 1)) ms.
                    """)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    private func showProcess(_ pid: Int32) {
        model.requestedProcess = pid
        page = .processes
    }
}

// MARK: - Summary

/// The filters at the leading edge and the scope badge at the trailing one,
/// or under the filters when the row has no room for even its short form.
/// A layout rather than a `ViewThatFits` of whole rows: that measured the
/// segmented control once per row on every layout pass, which here come
/// every tick, and cost about 1.5% of a core.
private struct FilterBarLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let filters = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        let ideal = filters.width + (subviews.count > 1 ? spacing + subviews[1].sizeThatFits(.unspecified).width : 0)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        guard subviews.count > 1 else { return CGSize(width: width, height: filters.height) }
        let badge = subviews[1]
        if let room = room(beside: filters, in: width, badge: badge) {
            let size = badge.sizeThatFits(ProposedViewSize(width: room, height: nil))
            return CGSize(width: width, height: max(filters.height, size.height))
        }
        let size = badge.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: filters.height + lineSpacing + size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let picker = subviews.first else { return }
        let filters = picker.sizeThatFits(.unspecified)
        guard subviews.count > 1 else {
            picker.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            return
        }
        let badge = subviews[1]
        if let room = room(beside: filters, in: bounds.width, badge: badge) {
            picker.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            badge.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                        proposal: ProposedViewSize(width: room, height: nil))
        } else {
            picker.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
            badge.place(at: CGPoint(x: bounds.minX, y: bounds.minY + filters.height + lineSpacing), anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    /// The width beside the filters, when the badge's narrowest form fits there.
    private func room(beside filters: CGSize, in width: CGFloat, badge: LayoutSubview) -> CGFloat? {
        let room = width - filters.width - spacing
        return badge.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width <= room ? room : nil
    }
}

/// Says how many sockets the counts and the table cover, and how many
/// processes they leave out, in a capsule so it reads with the counts above
/// it rather than as a footnote. So a 0 above a socket in the table reads as
/// a count of something else, not a missing row.
private struct ScopeBadge: View {
    var visible: Int
    var hidden: Int
    var length: Length

    /// Longest first. The shortest keeps the badge beside the filters in a
    /// narrow window; the footer under the table still counts the sockets.
    enum Length {
        case long, short, shortest
    }

    var body: some View {
        let sockets = visible == 1 ? "socket" : "sockets"
        let text = switch length {
        case .long: "\(visible.formatted()) visible \(sockets) · \(hidden.formatted()) processes hidden"
        case .short: "\(visible.formatted()) \(sockets) · \(hidden.formatted()) hidden"
        case .shortest: "\(hidden.formatted()) hidden"
        }
        Label(text, systemImage: "eye.slash")
            .font(.explanation.weight(.medium))
            .foregroundStyle(.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
            .fixedSize()
            .help("""
            The counts above and the table cover the \(visible.formatted()) \(sockets) your own processes hold. macOS only \
            lets an app list its own user's sockets, so \(hidden.formatted()) processes are left out: sockets held by root \
            and other users, such as system daemons, aren't shown. A privileged helper that lifts this is planned.
            """)
    }
}

private struct SummaryCards: View {
    var summary: ConnectionSummary

    var body: some View {
        FillGrid(minimum: 140, spacing: 12) {
            // "Connected", not "Established": the count takes in connected UDP
            // and TCP connections still opening or closing, which the
            // Established filter leaves out.
            SummaryCard(title: "Connected sockets", value: summary.openConnections, symbol: "arrow.left.arrow.right",
                        tint: Theme.cpu, explanation: """
                        Sockets talking to one peer: TCP connections, including ones opening or closing, and connected \
                        UDP. A listening or bound socket waits for anyone, so it isn't counted here.
                        """)
            SummaryCard(title: "Listening / bound ports", value: summary.listeningPorts, symbol: "antenna.radiowaves.left.and.right",
                        tint: Theme.disk, explanation: """
                        Distinct ports waiting for traffic from anyone: TCP sockets listening for connections, and UDP \
                        sockets bound to a port.
                        """)
            SummaryCard(title: "Exposed to network", value: summary.exposedPorts, symbol: "exclamationmark.shield",
                        tint: Theme.network, glow: summary.exposedPorts > 0 ? 0.35 : 0,
                        caption: Self.exposedCaption(summary),
                        explanation: """
                        Listening or bound ports other devices can reach unless the firewall blocks them. Bound to all \
                        interfaces (* in Local, the address 0.0.0.0 or ::) means every network this Mac is on: Wi-Fi, \
                        Ethernet and any VPN. The rest are bound to one network address.
                        """)
            SummaryCard(title: "Remote hosts", value: summary.remoteHosts, symbol: "globe",
                        tint: Theme.memory, explanation: "Distinct addresses at the other end of a connection, not counting this Mac.")
            SummaryCard(title: "Processes with sockets", value: summary.processesWithSockets, symbol: "app.connected.to.app.below.fill",
                        tint: Theme.gpu, explanation: "Processes holding at least one TCP or UDP socket.")
            // Reads the model every tick in a view of its own, so the counts and table aren't rebuilt.
            NetworkTrafficCard(title: "Network traffic", compact: true)
        }
    }

    /// Says outright where an exposed port is open, so "All interfaces" in
    /// the table and the count here read as the same thing.
    private static func exposedCaption(_ summary: ConnectionSummary) -> String? {
        let everywhere = summary.exposedOnAllInterfaces
        guard everywhere > 0 else { return nil }
        return everywhere == summary.exposedPorts ? "on all interfaces" : "\(everywhere.formatted()) on all interfaces"
    }
}

private struct SummaryCard: View {
    private static let valueFont = NSFont.numeric(size: 24, weight: .semibold, rounded: true)

    var title: String
    var value: Int
    var symbol: String
    var tint: Color
    var glow = 0.0
    /// A few words after the number, such as where it's open.
    var caption: String?
    var explanation: String

    var body: some View {
        // Its line box sits on the bottom edge, so the baseline is the descender up.
        let descender = Self.valueFont.descender
        Card(tint: tint, glow: glow) {
            Label {
                Text(title).lineLimit(2)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.metadata.weight(.medium))
            .foregroundStyle(.secondaryText)
            // A title that wraps to two lines makes its card the row's
            // height; the numbers stay on one line across the row.
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                AnimatedNumber(value: Double(value), format: { Format.fixed($0, 0) }, font: Self.valueFont)
                    .alignmentGuide(.lastTextBaseline) { $0.height + descender }
                if let caption {
                    Text(caption)
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .help(explanation)
    }
}
