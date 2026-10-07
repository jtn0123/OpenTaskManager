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
            // Whose sockets the counts are, so a 0 doesn't read as the whole Mac's.
            ScopeHeader(hidden: store.hiddenProcesses)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            // The five counts and the traffic card share one grid: a single row
            // in the default window, two even rows in the narrowest.
            SummaryCards(summary: store.summary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
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

    /// The filters. Whose sockets they filter, and how many processes are
    /// left out, is the header's over the counts.
    private var filterBar: some View {
        Picker("Show", selection: $filter) {
            ForEach(ConnectionFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Established TCP connections, TCP listeners, sockets other devices can reach, or UDP only")
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Over the counts: whose sockets they are, and how many processes macOS
/// keeps out of them, so "0 connected sockets" reads as none of yours
/// rather than none on the Mac. The hidden count opens why. One plain row,
/// no `ViewThatFits`: layout passes here come every tick (the traffic card).
private struct ScopeHeader: View {
    var hidden: Int
    @State private var explains = false

    var body: some View {
        HStack(spacing: 10) {
            Label(hidden > 0 ? "Your account's sockets" : "Every process's sockets",
                  systemImage: hidden > 0 ? "person.crop.circle" : "desktopcomputer")
                .font(.metadata.weight(.semibold))
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                .help(hidden > 0
                    ? "The counts and the table cover the sockets of processes running as \(NSUserName())."
                    : "Every process's sockets could be read, so the counts cover the whole Mac.")
            Spacer(minLength: 8)
            if hidden > 0 {
                Button {
                    explains.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "eye.slash")
                        Text("\(hidden.formatted()) \(hidden == 1 ? "process" : "processes") hidden")
                        Image(systemName: "info.circle").imageScale(.small)
                    }
                    .font(.explanation.weight(.medium))
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(explains ? 0.11 : 0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Why other processes' sockets aren't counted")
                .accessibilityHint("Explains why")
                .popover(isPresented: $explains, arrowEdge: .bottom) {
                    HiddenProcessesNote(hidden: hidden)
                        .padding(16)
                        .frame(width: 330)
                }
            }
        }
    }
}

/// Why some processes' sockets are missing, and what shows them.
private struct HiddenProcessesNote: View {
    var hidden: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why \(hidden.formatted()) \(hidden == 1 ? "process is" : "processes are") hidden")
                .font(.headline)
            Text("""
            macOS lets an app read the sockets of processes running under your own account, and no others. These run \
            as root or as another user (system daemons, and the apps of anyone else logged in), so their sockets aren't \
            in the counts or the table.
            """)
            Text("""
            An administrator account doesn't change this: the apps you open still run as you, not as root. Running \
            OpenTaskManager itself as root isn't supported.
            """)
            VStack(alignment: .leading, spacing: 4) {
                Text("To list every socket now, run this in Terminal:")
                Text("sudo lsof -i -n -P")
                    .font(.explanation.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            Text("A privileged helper that adds them here is planned.")
                .foregroundStyle(.secondaryText)
        }
        .font(.explanation)
        .fixedSize(horizontal: false, vertical: true)
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
