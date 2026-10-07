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
                ConnectionTable(rows: shown, selection: $selection, sortOrder: $sortOrder)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } detail: {
                if let selected {
                    ScrollView {
                        ConnectionDetail(row: selected, showProcess: { showProcess(selected.pid) },
                                         close: { selection = nil })
                            .padding(12)
                    }
                }
            }
            Divider()
            statusBar(shown: shown.count)
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

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(ConnectionFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Established TCP connections, TCP listeners, sockets other devices can reach, or UDP only")
            Spacer()
            if store.hiddenProcesses > 0 {
                Label("\(store.hiddenProcesses) processes hidden", systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("""
                    macOS only lets an app list the sockets of your own processes. Sockets held by root and \
                    other users, such as system daemons, aren't shown. A privileged helper that lifts this is planned.
                    """)
            }
        }
    }

    private func statusBar(shown: Int) -> some View {
        HStack(spacing: 16) {
            Text("\(shown) of \(store.rows.count) sockets")
            Text("\(store.summary.processesWithSockets) processes with sockets")
            Spacer()
            Text("Updates every \(Int(ConnectionStore.refreshInterval.components.seconds)) s while this page is open")
                .help("The last walk of every process's sockets took \(Format.fixed(store.walkDuration * 1000, 1)) ms.")
        }
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func showProcess(_ pid: Int32) {
        model.requestedProcess = pid
        page = .processes
    }
}

// MARK: - Summary

private struct SummaryCards: View {
    var summary: ConnectionSummary

    var body: some View {
        FillGrid(minimum: 140, spacing: 12) {
            SummaryCard(title: "Open connections", value: summary.openConnections, symbol: "arrow.left.arrow.right",
                        tint: Theme.cpu, explanation: "Sockets with a peer: TCP connections and connected UDP.")
            SummaryCard(title: "Listening ports", value: summary.listeningPorts, symbol: "antenna.radiowaves.left.and.right",
                        tint: Theme.disk, explanation: "Distinct ports taking new traffic: TCP listeners and bound UDP sockets.")
            SummaryCard(title: "Exposed to network", value: summary.exposedPorts, symbol: "exclamationmark.shield",
                        tint: Theme.network, glow: summary.exposedPorts > 0 ? 0.35 : 0,
                        explanation: """
                        Ports bound to every interface (0.0.0.0 or ::) or to a network address, so other devices \
                        can reach them unless the firewall blocks it.
                        """)
            SummaryCard(title: "Remote hosts", value: summary.remoteHosts, symbol: "globe",
                        tint: Theme.memory, explanation: "Distinct addresses at the other end of a connection, not counting this Mac.")
            SummaryCard(title: "Processes with sockets", value: summary.processesWithSockets, symbol: "app.connected.to.app.below.fill",
                        tint: Theme.gpu, explanation: "Processes holding at least one TCP or UDP socket.")
            // Reads the model every tick in a view of its own, so the counts and table aren't rebuilt.
            NetworkTrafficCard(title: "Network traffic", compact: true)
        }
    }
}

private struct SummaryCard: View {
    private static let valueFont = NSFont.numeric(size: 24, weight: .semibold, rounded: true)

    var title: String
    var value: Int
    var symbol: String
    var tint: Color
    var glow = 0.0
    var explanation: String

    var body: some View {
        Card(tint: tint, glow: glow) {
            Label {
                Text(title).lineLimit(2)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            // A title that wraps to two lines makes its card the row's
            // height; the numbers stay on one line across the row.
            Spacer(minLength: 0)
            AnimatedNumber(value: Double(value), format: { Format.fixed($0, 0) }, font: Self.valueFont)
        }
        .help(explanation)
    }
}
