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
    @AppStorage("hiddenConnectionColumns") private var hiddenColumns = HiddenConnectionColumns()
    /// Columns that are on but hidden because the table is too narrow. All
    /// that can give way do until the table has measured its room, so it
    /// never starts out wider than that.
    @State private var hiddenToFit = ConnectionColumn.givingWay
    /// Back from the details, the table shows the row they ended on.
    @State private var scrollTarget: Connection.ID?
    /// The page is wide enough for the six summary cards in one row.
    @State private var cardsFit = true
    /// The details are open, so the summary folds into a strip and the
    /// table beside them gets its height.
    @State private var inspectorFolds = false

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
        .toolbar {
            ToolbarItem {
                columnsMenu
            }
        }
        // Runs only while the page is on screen; SwiftUI cancels it when the
        // page goes away, and restarts it when updates are paused or resumed.
        .task(id: model.isPaused) { await store.run(model: model) }
    }

    private var content: some View {
        let shown = store.rows.filter { filter.matches($0.connection) && $0.matches(search) }.sorted(using: sortOrder)
        let selected = selection.flatMap { id in store.rows.first { $0.id == id } }
        let covered = isNarrow && showsFullDetail
        return VStack(spacing: 0) {
            // Whose sockets the counts are, so a 0 doesn't read as the whole Mac's.
            ScopeHeader(hidden: store.hiddenProcesses)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            // The five counts and the traffic card: cards in one row while they
            // fit it and the table has the page to itself, otherwise a strip of
            // chips (one line beside the details in the default window, two in
            // the narrowest), so the table keeps its height. Only a resize or
            // the details opening switch them, never a tick.
            Group {
                if cardsFit, !inspectorFolds {
                    SummaryCards(summary: store.summary)
                } else {
                    SummaryStrip(summary: store.summary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            // Like the Processes inspector, details only take room once
            // there's something to show, so the table gets the full width.
            InspectorSplit(
                listMinimum: ConnectionColumn.tableMinimum(userHidden: hiddenColumns.columns),
                wantsInspector: selected != nil,
                coversList: $showsFullDetail,
                isNarrow: $isNarrow,
                widthKey: "connectionInspectorWidth",
                backTitle: "Connections",
                // Over a narrow window's table, step through its rows without going back.
                backAccessory: covered ? AnyView(SocketStepper(
                    position: selection.flatMap { ListPosition(of: $0, in: shown.map(\.id)) },
                    select: { selection = $0 }
                )) : nil
            ) {
                VStack(spacing: 0) {
                    // Only as tall as its rows, so no empty stripes follow the
                    // last socket; with more rows than room it fills and scrolls.
                    ConnectionTable(rows: shown, selection: $selection, sortOrder: $sortOrder,
                                    userHidden: hiddenColumns.columns, hiddenToFit: $hiddenToFit,
                                    scrollTarget: $scrollTarget, showProcess: showProcess, open: openDetails)
                        .fitsTableToRows(shown.count)
                        .layoutPriority(1)
                    Divider()
                    tableFooter(shown: shown.count)
                    Spacer(minLength: 0)
                }
            } detail: {
                if let selected {
                    ConnectionDetail(row: selected, showProcess: { showProcess(selected.pid) },
                                     close: covered ? nil : { selection = nil })
                } else if covered {
                    ContentUnavailableView("Socket closed", systemImage: "xmark.circle", description: Text("""
                    It closed after it was picked, by its process or the other end. Go back to the list, or step \
                    to another socket.
                    """))
                }
            }
        }
        // The split view sizes the page by asking for its smallest size with
        // no width to offer. Laid out at the table's narrowest instead, the
        // counts make two rows there, not a column of six too tall for the window.
        .frame(minWidth: ConnectionColumn.tableMinimum(userHidden: hiddenColumns.columns))
        // A Bool, so only crossing the width the cards need runs this.
        .onGeometryChange(for: Bool.self) { SummaryCards.fitOneRow(width: $0.size.width - 32) } action: { cardsFit = $0 }
        .task(id: selected != nil) { await foldSummary(open: selected != nil) }
        .onAppear(perform: selectRequestedConnection)
        // The details come with a selection here, so in a narrow window
        // picking a socket opens them, and Back returns to the table.
        .onChange(of: selection) {
            if isNarrow { showsFullDetail = selection != nil }
        }
        // Back keeps the selection, the filter, the sort and the scroll
        // position; the table scrolls only if Previous and Next moved the
        // selection out of view. Double-click opens the same socket again.
        .onChange(of: showsFullDetail) {
            if isNarrow, !showsFullDetail { scrollTarget = selection }
        }
    }

    /// Folds the summary into its strip while the details are open, and
    /// unfolds it when they close. A click that opens them may be the first
    /// of a double-click, so the fold waits that out: the table doesn't move
    /// up under the pointer and the second click lands on the same row.
    private func foldSummary(open: Bool) async {
        guard open else {
            inspectorFolds = false
            return
        }
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp {
            try? await Task.sleep(for: .seconds(min(NSEvent.doubleClickInterval, 0.5)))
            guard !Task.isCancelled else { return }
        }
        inspectorFolds = true
    }

    /// Double-click: the pane beside a wide window's table opens with the
    /// selection; a narrow window's covers the table.
    private func openDetails() {
        if isNarrow, selection != nil { showsFullDetail = true }
    }

    /// Optional columns, as on the Processes page. Hiding one makes room for
    /// the others; one that's on but hidden to fit the width stays ticked and says so.
    private var columnsMenu: some View {
        Menu {
            ForEach(ConnectionColumn.allCases.filter { $0 != .process }, id: \.self) { column in
                Toggle(column.menuTitle(hiddenToFit: hiddenToFit.contains(column)), isOn: Binding(
                    get: { hiddenColumns.isOn(column) },
                    set: { isOn in
                        if isOn != hiddenColumns.isOn(column) { hiddenColumns.toggle(column) }
                    }
                ))
            }
            if !hiddenToFit.isEmpty {
                Divider()
                Text(ProcessColumn.hiddenToFitNote)
            }
            Divider()
            Button("Default Columns") { hiddenColumns = HiddenConnectionColumns() }
        } label: {
            Label("Columns", systemImage: "tablecells")
        }
        .help(hiddenToFit.isEmpty ? "Columns: choose what the table shows"
            : "Columns: choose what the table shows. Some are hidden until there's room for them")
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
        // The counts are read, not scanned: 12 points, like the rows' captions elsewhere.
        .font(.explanation)
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
                .font(.explanation.weight(.semibold))
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
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            Text("A privileged helper that adds them here is planned.")
                .foregroundStyle(.secondaryText)
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The five counts over the table, as the cards and the strip both show them.
private enum SummaryFigure: CaseIterable {
    case connected, listening, exposed, remoteHosts, processes

    /// The card's title.
    var title: String {
        switch self {
        // "Connected", not "Established": the count takes in connected UDP
        // and TCP connections still opening or closing, which the
        // Established filter leaves out.
        case .connected: "Connected sockets"
        case .listening: "Listening / bound ports"
        case .exposed: "Exposed to network"
        case .remoteHosts: "Remote hosts"
        case .processes: "Processes with sockets"
        }
    }

    /// After the number on a chip: "2 connected".
    var shortTitle: String {
        switch self {
        case .connected: "connected"
        case .listening: "listening"
        case .exposed: "exposed"
        case .remoteHosts: "remote hosts"
        case .processes: "processes"
        }
    }

    var symbol: String {
        switch self {
        case .connected: "arrow.left.arrow.right"
        case .listening: "antenna.radiowaves.left.and.right"
        case .exposed: "exclamationmark.shield"
        case .remoteHosts: "globe"
        case .processes: "app.connected.to.app.below.fill"
        }
    }

    var tint: Color {
        switch self {
        case .connected: Theme.cpu
        case .listening: Theme.disk
        case .exposed: Theme.network
        case .remoteHosts: Theme.memory
        case .processes: Theme.gpu
        }
    }

    var explanation: String {
        switch self {
        case .connected: """
            Sockets talking to one peer: TCP connections, including ones opening or closing, and connected \
            UDP. A listening or bound socket waits for anyone, so it isn't counted here.
            """
        case .listening: """
            Distinct ports waiting for traffic from anyone: TCP sockets listening for connections, and UDP \
            sockets bound to a port.
            """
        case .exposed: """
            Listening or bound ports other devices can reach unless the firewall blocks them. Bound to all \
            interfaces (* in Local, the address 0.0.0.0 or ::) means every network this Mac is on: Wi-Fi, \
            Ethernet and any VPN. The rest are bound to one network address.
            """
        case .remoteHosts: "Distinct addresses at the other end of a connection, not counting this Mac."
        case .processes: "Processes holding at least one TCP or UDP socket."
        }
    }

    func value(_ summary: ConnectionSummary) -> Int {
        switch self {
        case .connected: summary.openConnections
        case .listening: summary.listeningPorts
        case .exposed: summary.exposedPorts
        case .remoteHosts: summary.remoteHosts
        case .processes: summary.processesWithSockets
        }
    }

    /// A few words after the number: where an exposed port is open, so
    /// "All interfaces" in the table and the count here read as the same thing.
    func caption(_ summary: ConnectionSummary) -> String? {
        guard self == .exposed, summary.exposedOnAllInterfaces > 0 else { return nil }
        let everywhere = summary.exposedOnAllInterfaces
        return everywhere == summary.exposedPorts ? "on all interfaces" : "\(everywhere.formatted()) on all interfaces"
    }

    /// Lit up while there's something to look at (an exposed port).
    func isAlert(_ summary: ConnectionSummary) -> Bool {
        self == .exposed && summary.exposedPorts > 0
    }
}

/// The counts and the traffic card in one grid: a single row while the
/// page is wide enough, and the table has it to itself.
private struct SummaryCards: View {
    private nonisolated static let minimum: CGFloat = 140
    private nonisolated static let spacing: CGFloat = 12
    /// The counts and the traffic card.
    private nonisolated static let count = SummaryFigure.allCases.count + 1

    var summary: ConnectionSummary

    /// Whether all six cards fit one row `width` wide. Nonisolated, for the
    /// page's geometry closure.
    nonisolated static func fitOneRow(width: CGFloat) -> Bool {
        GridMath.rows(count: count, width: Double(width), minimum: Double(minimum), spacing: Double(spacing)).count == 1
    }

    var body: some View {
        FillGrid(minimum: Self.minimum, spacing: Self.spacing) {
            ForEach(SummaryFigure.allCases, id: \.self) { figure in
                SummaryCard(figure: figure, summary: summary)
            }
            // Reads the model every tick in a view of its own, so the counts and table aren't rebuilt.
            NetworkTrafficCard(title: "Network traffic", compact: true)
        }
    }
}

private struct SummaryCard: View {
    private static let valueFont = NSFont.numeric(size: 24, weight: .semibold, rounded: true)

    var figure: SummaryFigure
    var summary: ConnectionSummary

    var body: some View {
        // Its line box sits on the bottom edge, so the baseline is the descender up.
        let descender = Self.valueFont.descender
        Card(tint: figure.tint, glow: figure.isAlert(summary) ? 0.35 : 0) {
            Label {
                Text(figure.title).lineLimit(2)
            } icon: {
                Image(systemName: figure.symbol).foregroundStyle(figure.tint)
            }
            .font(.explanation.weight(.medium))
            .foregroundStyle(.secondaryText)
            // A title that wraps to two lines makes its card the row's
            // height; the numbers stay on one line across the row.
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                AnimatedNumber(value: Double(figure.value(summary)), format: { Format.fixed($0, 0) }, font: Self.valueFont)
                    .alignmentGuide(.lastTextBaseline) { $0.height + descender }
                if let caption = figure.caption(summary) {
                    Text(caption)
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .help(figure.explanation)
    }
}

/// The same six as a strip of chips, each in its card's colour with the
/// number and a word or two: one line while it fits, else even columns
/// that line up (`GridMath.stripRows`).
private struct SummaryStrip: View {
    var summary: ConnectionSummary

    var body: some View {
        ChipStrip(spacing: 8) {
            ForEach(SummaryFigure.allCases, id: \.self) { figure in
                SummaryChip(figure: figure, summary: summary)
            }
            TrafficChip()
        }
    }
}

/// Places chips as `GridMath.stripRows` says, each at its row's height.
private struct ChipStrip: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
        let heights = rows(sizes, width: width).map { row in sizes[row.items].map(\.height).max() ?? 0 }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in rows(sizes, width: bounds.width) {
            let height = sizes[row.items].map(\.height).max() ?? 0
            var x = bounds.minX
            for (index, width) in zip(row.items, row.widths) {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: CGFloat(width), height: height))
                x += CGFloat(width) + spacing
            }
            y += height + spacing
        }
    }

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [GridMath.StripRow] {
        GridMath.stripRows(widths: sizes.map { Double($0.width) }, width: Double(width), spacing: Double(spacing))
    }
}

private struct SummaryChip: View {
    private static let valueFont = NSFont.numeric(size: 15, weight: .semibold, rounded: true)

    var figure: SummaryFigure
    var summary: ConnectionSummary

    var body: some View {
        let descender = Self.valueFont.descender
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Image(systemName: figure.symbol).foregroundStyle(figure.tint)
            AnimatedNumber(value: Double(figure.value(summary)), format: { Format.fixed($0, 0) }, font: Self.valueFont)
                .alignmentGuide(.lastTextBaseline) { $0.height + descender }
            Text(figure.shortTitle).fontWeight(.medium)
            if let caption = figure.caption(summary) {
                Text("· \(caption)")
            }
        }
        .modifier(SummaryChipLook(tint: figure.tint, isAlert: figure.isAlert(summary)))
        .help(figure.explanation)
    }
}

/// Receive and send rates across the primary interfaces, as the traffic
/// card shows them. It alone reads the model, every tick, and its rates
/// have fixed widths, so the strip around it never moves.
private struct TrafficChip: View {
    private static let font = NSFont.numeric(size: 13, weight: .medium)
    private static let rateWidth = ceil(("88.8 Mbps" as NSString).size(withAttributes: [.font: font]).width) + 2

    @Environment(AppModel.self) private var model

    var body: some View {
        let links = model.snapshot?.network.filter(\.isPrimary) ?? []
        HStack(spacing: 6) {
            Image(systemName: "network").foregroundStyle(Theme.network)
            rate(links.reduce(0) { $0 + $1.receivedBytesPerSecond }, symbol: "arrow.down", color: Theme.network)
                .help("Receive")
            rate(links.reduce(0) { $0 + $1.sentBytesPerSecond }, symbol: "arrow.up", color: Theme.networkSecondary)
                .help("Send")
        }
        .modifier(SummaryChipLook(tint: Theme.network, isAlert: false))
        .help("Network traffic: the Mac's receive and send rates across its primary network interfaces")
    }

    private func rate(_ value: Double, symbol: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
            AnimatedNumber(value: value, format: Format.bitsPerSecond, font: Self.font)
                .frame(width: Self.rateWidth, alignment: .leading)
        }
    }
}

/// A chip's text, wash and border: its card's, in small. One with something
/// to look at (an exposed port) is washed and outlined more strongly.
private struct SummaryChipLook: ViewModifier {
    var tint: Color
    var isAlert: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let wash = tint.fillShade
        content
            .font(.explanation)
            .foregroundStyle(.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [wash.opacity(isAlert ? 0.26 : 0.16), wash.opacity(isAlert ? 0.10 : 0.04)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(isAlert ? 0.6 : 0.28), lineWidth: 1))
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Narrow window

/// Previous and Next on the Back bar while the details cover a narrow
/// window's table, and where the socket sits in the table as filtered and
/// sorted. Moving the selection here moves the table's with it.
private struct SocketStepper: View {
    /// Nil when the table doesn't show the socket: a filter or search hides
    /// it, or it closed.
    var position: ListPosition<Connection.ID>?
    var select: (Connection.ID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let position {
                Text("Socket \(position.number.formatted()) of \(position.count.formatted())")
                    .font(.explanation)
                    .monospacedDigit()
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
            ControlGroup {
                Button {
                    position?.previous.map(select)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(position?.previous == nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Previous socket in the table (⌘↑)")
                .accessibilityLabel("Previous socket")
                Button {
                    position?.next.map(select)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(position?.next == nil)
                .keyboardShortcut(.downArrow, modifiers: .command)
                .help("Next socket in the table (⌘↓)")
                .accessibilityLabel("Next socket")
            }
            .fixedSize()
        }
    }
}
