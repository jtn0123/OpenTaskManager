import AppKit
import OTMKit
import SwiftUI

/// Sockets in a sortable table. Rows change only when the store refreshes
/// (every few seconds), never on the main sampler's tick.
///
/// Columns can be resized and reordered while the page is open. Which ones
/// show is the Columns menu's, saved, less any the width can't hold
/// (`ConnectionColumn.priority`), so the header's own menu doesn't offer it.
struct ConnectionTable: View {
    typealias Column = TableColumnContent<ConnectionRow, KeyPathComparator<ConnectionRow>>

    var rows: [ConnectionRow]
    @Binding var selection: ObservedConnection.ID?
    @Binding var sortOrder: [KeyPathComparator<ConnectionRow>]
    /// Switched off in the Columns menu.
    var userHidden: Set<ConnectionColumn>
    /// On, but hidden while the table is too narrow for them.
    @Binding var hiddenToFit: Set<ConnectionColumn>
    /// A row to bring into view, scrolling no further than that takes.
    @Binding var scrollTarget: ObservedConnection.ID?
    var showProcess: (Int32) -> Void
    /// Double-click: the details, over the table in a narrow window.
    var open: () -> Void

    /// Widths and order as the user left them, and which columns show. Not
    /// saved, as on the Apps and Startup tables: widths saved in a wide window
    /// come back whole in a narrower one, and push the last columns out of sight.
    @State private var columns = TableColumnCustomization<ConnectionRow>()

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target)
                    scrollTarget = nil
                }
        }
        // The table asks for its columns' minimum widths. Taking what it's
        // given instead, the room it has is what's measured, and its columns
        // never push the page, and the sidebar, out of a narrow window.
        .frame(minWidth: 0, maxWidth: .infinity)
        // Measured in a view of its own, so resizing the window re-runs that,
        // not the rows, and the columns change only when one has to give way.
        .background(ColumnFitter(userHidden: userHidden, hiddenToFit: $hiddenToFit))
        .background(ColumnSqueeze(shown: shownCount))
        .onChange(of: userHidden.union(hiddenToFit), initial: true, showColumns)
    }

    /// How many columns the table has been told to show.
    private var shownCount: Int {
        ConnectionColumn.allCases.filter { columns[visibility: $0.rawValue] != .hidden }.count
    }

    private func showColumns() {
        let hidden = userHidden.union(hiddenToFit)
        for column in ConnectionColumn.allCases where column != .process {
            let visibility: Visibility = hidden.contains(column) ? .hidden : .visible
            if columns[visibility: column.rawValue] != visibility { columns[visibility: column.rawValue] = visibility }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            processColumn
            pidColumn
            transportColumn
            localColumn
            remoteColumn
            stateColumn
            ageColumn
            scopeColumn
        }
        .contextMenu(forSelectionType: ObservedConnection.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Copy Local Endpoint") { ConnectionActions.copy(row.connection.local) }
                Button("Copy Remote Endpoint") { row.connection.remote.map(ConnectionActions.copy) }
                    .disabled(row.connection.remote == nil)
                Divider()
                Button("Show Process") { showProcess(row.pid) }
                    // A closed socket's process may have ended, and its PID gone to another.
                    .disabled(!row.processRunning)
            }
        } primaryAction: { _ in
            open()
        }
    }

    private var processColumn: some Column {
        TableColumn("Process", value: \.processName) { row in
            HStack(spacing: 6) {
                Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                Text(row.processName).lineLimit(1)
            }
            .help(row.processName)
        }
        .sized(.process)
    }

    private var pidColumn: some Column {
        TableColumn("PID", value: \.pid) { row in
            Text(verbatim: String(row.pid)).monospacedDigit().foregroundStyle(.secondaryText)
        }
        .sized(.pid)
    }

    private var transportColumn: some Column {
        TableColumn("Protocol", value: \.protocolName) { row in
            ProtocolLabel(connection: row.connection)
        }
        .sized(.transport)
    }

    private var localColumn: some Column {
        TableColumn("Local", value: \.localOrder) { row in
            EndpointLabel(endpoint: row.connection.local)
        }
        .sized(.local)
    }

    private var remoteColumn: some Column {
        TableColumn("Remote", value: \.remoteOrder) { row in
            if let remote = row.connection.remote {
                EndpointLabel(endpoint: remote)
            } else {
                Text("—")
                    .foregroundStyle(.secondaryText)
                    .help(row.connection.kind.acceptsInbound ? "No remote end: it waits for traffic from anyone" : "No remote end: not connected")
            }
        }
        .sized(.remote)
    }

    private var stateColumn: some Column {
        TableColumn("State", value: \.stateOrder) { row in
            StateLabel(row: row)
        }
        .sized(.state)
    }

    private var ageColumn: some Column {
        TableColumn("Seen for", value: \.seenForOrder) { row in
            Text(ObservedConnection.span(row.socket.seenFor))
                .monospacedDigit()
                .lineLimit(1)
                .help(row.socket.seenSummary(time: ConnectionClock.time))
        }
        .sized(.age)
    }

    private var scopeColumn: some Column {
        TableColumn("Scope", value: \.scopeOrder) { row in
            // The symbol alone once the column is too narrow for the words.
            ViewThatFits(in: .horizontal) {
                ScopeLabel(connection: row.connection)
                ScopeLabel(connection: row.connection).labelStyle(.iconOnly)
            }
            .help(row.connection.scope.label)
        }
        .sized(.scope)
    }
}

private extension TableColumn where RowValue == ConnectionRow, Sort == KeyPathComparator<ConnectionRow>, Label == Text {
    /// The column's widths and customization ID. Which columns show is the
    /// Columns menu's and the width's, so the header's menu leaves it alone.
    ///
    /// Columns start at their narrowest and the table shares out the rest.
    /// A table with column customization keeps its starting widths when they
    /// add up to more than its room, and scrolls sideways for good, so
    /// starting any wider can push State and Scope out of a narrow window.
    @MainActor func sized(_ column: ConnectionColumn) -> some TableColumnContent<ConnectionRow, KeyPathComparator<ConnectionRow>> {
        width(min: column.minWidth, ideal: column.minWidth, max: column.maxWidth)
            .customizationID(column.rawValue)
            .disabledCustomizationBehavior(.visibility)
    }
}

/// Watches the table's width and reports the columns that don't fit it.
private struct ColumnFitter: View {
    var userHidden: Set<ConnectionColumn>
    @Binding var hiddenToFit: Set<ConnectionColumn>
    @State private var width: CGFloat?

    var body: some View {
        let fitted = width.map { ConnectionColumn.hiddenToFit(width: $0, userHidden: userHidden) }
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: fitted, initial: true) {
                if let fitted, fitted != hiddenToFit { hiddenToFit = fitted }
            }
    }
}

/// Brings the shown columns back inside the table's edge once some have
/// hidden to fit. A table already running past its edge, as it does for a
/// moment when the details pane opens beside it, gives a hidden column's
/// width to the others instead of narrowing, and would go on scrolling
/// sideways. Runs when the columns shown or the table's size change, never
/// on the store's refresh, and leaves a table that fits alone.
private struct ColumnSqueeze: NSViewRepresentable {
    var shown: Int

    func makeNSView(context: Context) -> ColumnSqueezeView {
        ColumnSqueezeView()
    }

    func updateNSView(_ view: ColumnSqueezeView, context: Context) {
        view.shown = shown
    }
}

private final class ColumnSqueezeView: NSView {
    /// Setting it fits the columns again, once the table shows that many.
    var shown = 0 {
        didSet { if shown != oldValue { scheduleFit() } }
    }

    private weak var table: NSTableView?
    private var isScheduled = false
    /// Tries left to find the table showing `shown` columns: SwiftUI makes
    /// it, and hides its columns, an update or two after this view's.
    private var triesLeft = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFit()
    }

    @objc private func scrollViewResized(_ notification: Notification) {
        scheduleFit()
    }

    private func scheduleFit() {
        triesLeft = 10
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    private func fit() {
        isScheduled = false
        guard window != nil else { return }
        guard let table = table ?? nearestTable(),
              let scrollView = table.enclosingScrollView,
              table.tableColumns.filter({ !$0.isHidden }).count == shown
        else {
            retry()
            return
        }
        if self.table !== table {
            self.table = table
            // The clip view, which narrows when the window or the details
            // pane does, and when a scroller comes in.
            scrollView.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollViewResized),
                                                   name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        }
        let excess = table.frame.width - scrollView.contentView.bounds.width
        guard excess > 0.5 else { return }
        let columns = table.tableColumns.filter { !$0.isHidden }
        let widths = ColumnFit.narrowed(widths: columns.map { Double($0.width) },
                                        minimums: columns.map { Double($0.minWidth) },
                                        by: Double(excess))
        for (column, width) in zip(columns, widths) {
            column.width = CGFloat(width)
        }
    }

    private func retry() {
        guard triesLeft > 0, !isScheduled else { return }
        triesLeft -= 1
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fit() }
    }

    /// The socket table: the first table with all its columns in the
    /// closest enclosing view that has one.
    private func nearestTable() -> NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let table = Self.socketTable(in: view) { return table }
            ancestor = view.superview
        }
        return nil
    }

    private static func socketTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.tableColumns.count == ConnectionColumn.allCases.count { return table }
        for subview in view.subviews {
            if let table = socketTable(in: subview) { return table }
        }
        return nil
    }
}

/// An address and its port on one line. Short of room, the address is cut
/// in the middle and the port stays whole, so two sockets on one host still
/// read apart; the whole endpoint is in the tooltip.
struct EndpointLabel: View {
    var endpoint: Endpoint

    var body: some View {
        let parts = endpoint.formattedParts
        HStack(spacing: 0) {
            Text(parts.host).truncationMode(.middle)
            if let port = parts.port {
                Text(port).layoutPriority(1)
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .help(endpoint.formatted)
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

/// The state in its colour, which turns white with the row's text on a
/// selected row, where green or blue over the accent colour is hard to read.
/// A listener the page saw open a short while ago is tagged New (a dot,
/// short of room); a closed socket says how long ago it went.
private struct StateLabel: View {
    @Environment(\.backgroundProminence) private var prominence
    var row: ConnectionRow

    var body: some View {
        if let ago = row.closedAgo {
            ViewThatFits(in: .horizontal) {
                // Gone while nothing watched, it may have closed long before
                // the walk that noticed, so it doesn't say when.
                if !closedUnwatched { Text("Closed \(Self.ago(ago))") }
                Text("Closed")
            }
            .lineLimit(1)
            .foregroundStyle(.secondaryText)
            .help(closedHelp)
        } else if row.isNewListener {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    state
                    NewTag(prominent: prominence == .increased)
                }
                HStack(spacing: 4) {
                    Circle().fill(prominence == .increased ? Color.primary : ConnectionTint.green).frame(width: 6, height: 6)
                    state
                }
            }
            .help(newHelp)
        } else {
            state
        }
    }

    private var state: some View {
        Text(row.connection.stateLabel)
            .lineLimit(1)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(row.connection.kind.tint))
    }

    private var closedUnwatched: Bool { row.socket.timeline.last?.isAfterGap == true }

    private var closedHelp: String {
        let last = "\(row.connection.stateLabel) when last seen, at \(ConnectionClock.time(row.socket.lastSeen))"
        let gap = closedUnwatched ? ", while the page wasn't watching" : ""
        return row.socket.closedBy.map { "Closed: \(last), and gone by \(ConnectionClock.time($0))\(gap)" } ?? last
    }

    private var newHelp: String {
        let since = row.socket.listeningSince.map { " at \(ConnectionClock.time($0))" } ?? ""
        return "New: this page saw it start listening\(since). It's marked for "
            + "\(Format.timeSpan(ConnectionWatch.newListenerWindow)) after that."
    }

    /// Seconds for the first minute, so the list's first minute doesn't all
    /// read "just now"; the walks are 3 s apart, so 0 is the latest one.
    private static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 3 { return "just now" }
        return seconds < 60 ? "\(ObservedConnection.span(seconds)) ago" : Format.ago(seconds)
    }
}

/// The tag on a listener the page saw open a short while ago: the state's
/// green, white like the row's text on a selected row.
private struct NewTag: View {
    var prominent: Bool

    var body: some View {
        Text("New")
            .font(.callout.weight(.semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(ConnectionTint.green))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((prominent ? Color.white.opacity(0.25) : ConnectionTint.green.opacity(0.14)), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// Scope with its icon; exposed sockets get a warning tint, white like the
/// row's text on a selected row.
struct ScopeLabel: View {
    @Environment(\.backgroundProminence) private var prominence
    var connection: Connection

    var body: some View {
        Label {
            Text(connection.scope.label).lineLimit(1)
        } icon: {
            Image(systemName: connection.scope.symbol)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
        }
    }

    private var tint: Color {
        connection.isExposed ? ConnectionTint.orange : connection.scope.tint
    }
}

// MARK: - Styling

/// Clock times on this page: when a walk saw a socket open, change or go.
enum ConnectionClock {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

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
