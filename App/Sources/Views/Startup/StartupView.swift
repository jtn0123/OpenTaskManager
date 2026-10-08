import OTMKit
import SwiftUI

/// Which items the Startup table shows.
enum StartupFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case thirdParty = "Third party"
    case apple = "Apple"
    case running = "Running"
    case agents = "Agents"
    case daemons = "Daemons"
    case problems = "Problems"

    var id: String { rawValue }

    func includes(_ item: LaunchItem, health: LaunchJobHealth) -> Bool {
        switch self {
        case .all: true
        case .thirdParty: item.publisher == .thirdParty
        case .apple: item.publisher == .apple
        case .running: item.pid != nil
        case .agents: item.scope.isAgent
        case .daemons: item.scope == .daemon
        case .problems: health.needsAttention
        }
    }

    /// Whether rows can differ in publisher. Under Apple or Third party the
    /// column would say the same thing on every row, so it gives its room to Name.
    var showsPublisher: Bool { self != .apple && self != .thirdParty }
}

/// A row of the Startup table: the item, how its job looks, and, while the
/// table is sorted by them, its process's CPU and memory.
struct StartupRow: Identifiable, Equatable {
    let item: LaunchItem
    let health: LaunchJobHealth
    /// What the job is doing, as the Status column and the details' header
    /// both say it, apart from whether launchd has it loaded.
    let status: LaunchItemStatus
    /// The latest sample's figures, filled in only while the table sorts by
    /// them, so the rows aren't rebuilt every tick otherwise. -1 when the
    /// job isn't running or isn't in the sample.
    var cpu = -1.0
    var memory: UInt64 = 0

    init(item: LaunchItem, health: LaunchJobHealth) {
        self.item = item
        self.health = health
        status = LaunchItemStatus(item: item, health: health)
    }

    var id: LaunchItem.ID { item.id }
}

/// Everything launchd starts by itself: the agents and daemons in the
/// LaunchAgents and LaunchDaemons folders, with what launchd says about each.
///
/// The scan runs off the main actor when the page opens and on Refresh. While
/// the page is on screen launchd is asked again every few seconds, without
/// reading the property lists, so restarts are seen (`LaunchJobStore`). The
/// table's CPU and Memory cells read the latest sample themselves, a lookup
/// by the PID launchd reports, so a tick redraws them and not the table.
struct StartupView: View {
    @Environment(AppModel.self) private var model
    @CurrentPage private var page
    @AppStorage("startupFilter") private var filter: StartupFilter = .all
    @AppStorage("showStartupInspector") private var showInspector = true
    @State private var items: [LaunchItem]?
    @State private var scannedAt: Date?
    @State private var isScanning = false
    @State private var search = ""
    @State private var selection: LaunchItem.ID?
    /// A row to bring into view, once: the selection's, when it comes from a
    /// launch argument or another page, after the filter, search or sort
    /// changes, and on Show in List. Never set by a tick or launchd's reads,
    /// so the table doesn't move under the pointer.
    @State private var scrollTarget: LaunchItem.ID?
    @State private var sortOrder = [KeyPathComparator(\StartupRow.item.publisher), KeyPathComparator(\StartupRow.item.name)]
    /// The item waiting on the Disable confirmation.
    @State private var disabling: LaunchItem?
    @State private var switchError: String?
    /// The window is too narrow for the table and the details side by side.
    @State private var isNarrow = false
    /// In a narrow window, the details cover the table.
    @State private var showsFullDetail = false
    @State private var openedRequest = false
    /// The item the Apps page asked for, selected after the first read.
    @State private var requestedItem: LaunchItem.ID?
    @FocusState private var tableFocused: Bool

    var body: some View {
        Group {
            if let items {
                page(items)
            } else {
                ProgressView("Reading startup items…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                InventoryRefresh(readAt: scannedAt, isReading: isScanning, help: "Read the launchd folders and ask launchd again") {
                    Task { await scan() }
                }
            }
            ToolbarItem {
                Button(action: toggleDetails) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(isNarrow ? (showsFullDetail ? "Back to the list" : "Show the selected item's details")
                    : "Show details for the selected item")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Label, program or path")
        .task {
            // "Show in Startup" on the Apps page searches for that app's
            // items, and one of them picked there is selected once they're read.
            if let query = model.requestedStartupSearch {
                model.requestedStartupSearch = nil
                search = query
                filter = .all
            }
            requestedItem = model.requestedStartupItem
            model.requestedStartupItem = nil
            if items == nil { await scan() }
        }
        // The selected row may have moved out of view; these are the user's
        // own changes, never a tick or a read of launchd's list.
        .onChange(of: filter) { revealSelection() }
        .onChange(of: search) { revealSelection() }
        .onChange(of: sortOrder) { revealSelection() }
        // Only while the page is on screen, and not while updates are paused.
        .task(id: model.isPaused) { await followLaunchd() }
        .confirmationDialog("Disable \(disabling?.name ?? "this item")?", isPresented: Binding(
            get: { disabling != nil }, set: { if !$0 { disabling = nil } }
        ), presenting: disabling) { item in
            Button("Disable") { Task { await perform(.disable, on: item) } }
        } message: { _ in
            Text("It stops now and won't start at login until you enable it again. Only your account is affected.")
        }
        .alert("Couldn't switch this item", isPresented: Binding(
            get: { switchError != nil }, set: { if !$0 { switchError = nil } }
        )) {
            Button("OK") { switchError = nil }
        } message: {
            Text(switchError ?? "")
        }
    }

    private func page(_ items: [LaunchItem]) -> some View {
        let watch = model.launchJobs.watch
        let rows = visibleRows(items, watch: watch)
        // Like the Processes inspector, the details take room only once
        // something is selected. Beside the table, Publisher gives its room
        // to Name and a badge marks the third-party rows instead.
        let wantsInspector = showInspector && selection != nil
        let besideTable = wantsInspector && !isNarrow
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                summary(items, watch: watch)
                    .padding(.bottom, 2)
                Picker("Show", selection: $filter) {
                    ForEach(StartupFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                LoginItemsNote()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            InspectorSplit(
                listMinimum: StartupColumn.tableMinimum(userHidden: []),
                wantsInspector: wantsInspector,
                coversList: $showsFullDetail,
                isNarrow: $isNarrow,
                widthKey: "startupInspectorWidth",
                backTitle: "Startup"
            ) {
                VStack(spacing: 0) {
                    // Only as tall as its rows, so a short list, as Problems
                    // usually is, isn't followed by empty stripes.
                    StartupTable(model: model, rows: rows, showsPublisher: filter.showsPublisher && !besideTable,
                                 filterShowsPublisher: filter.showsPublisher,
                                 selection: $selection, sortOrder: $sortOrder, scrollTarget: $scrollTarget,
                                 focus: $tableFocused, toggle: toggle, open: openDetails)
                        .fitsTableToRows(rows.count)
                        .layoutPriority(1)
                    if rows.isEmpty, filter == .problems, search.isEmpty {
                        NoProblemsNote(since: watch.since)
                            .padding(16)
                    }
                    Spacer(minLength: 0)
                }
            } detail: {
                if let item = items.first(where: { $0.id == selection }) {
                    StartupItemDetail(
                        model: model, item: item, health: watch.health(of: item), record: watch.record(for: item),
                        refreshID: scannedAt, toggle: { toggle(item) },
                        control: { action in Task { await perform(action, on: item) } },
                        showProcess: showProcess,
                        showInList: showInList
                    )
                } else {
                    ContentUnavailableView("No item selected", systemImage: "info.circle",
                                           description: Text("Select an item to see what it runs and when."))
                }
            }
            Divider()
            StartupStatusBar(shown: rows.count, total: items.count, scannedAt: scannedAt, isScanning: isScanning,
                             watchedSince: watch.since)
        }
    }

    /// Double-click: the pane in a wide window, the full-width details in a narrow one.
    private func openDetails() {
        showInspector = true
        if isNarrow { showsFullDetail = true }
    }

    private func toggleDetails() {
        if isNarrow {
            if showsFullDetail { showsFullDetail = false } else { openDetails() }
        } else {
            showInspector.toggle()
        }
    }

    private func summary(_ items: [LaunchItem], watch: LaunchJobWatch) -> some View {
        let problems = items.filter { watch.health(of: $0).needsAttention }.count
        return FillGrid(minimum: 140, spacing: 12) {
            SummaryCard(title: "Total", value: items.count, tint: Theme.cpu,
                        help: "Property lists in the five LaunchAgents and LaunchDaemons folders")
            SummaryCard(title: "Running", value: items.filter { $0.pid != nil }.count, tint: Theme.disk,
                        help: "Jobs with a process running right now")
            SummaryCard(title: "Third party", value: items.filter { $0.publisher == .thirdParty }.count, tint: Theme.network,
                        help: "Installed by something other than macOS")
            // Its caption says what's counted, so the note below about the
            // Login Items it leaves out reads as a distinction, not a contradiction.
            SummaryCard(title: "Start at login", value: items.filter(\.startsAutomatically).count, tint: Theme.memory,
                        caption: "Launch jobs set to run at login",
                        help: "launchd agents and daemons set to run as soon as they're loaded: agents when you log in, "
                            + "daemons when the Mac starts up, unless they're disabled. The Login Items in System "
                            + "Settings aren't in this count: macOS keeps them private.")
            SummaryCard(title: "Problems", value: problems, tint: problems > 0 ? LaunchJobHealth.tint : Theme.other,
                        glow: problems > 0 ? 0.35 : 0,
                        help: "Jobs whose last run crashed or failed, or that were seen restarting again and again. "
                            + "The Problems filter lists them.")
        }
    }

    private func visibleRows(_ items: [LaunchItem], watch: LaunchJobWatch) -> [StartupRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.compactMap { item -> StartupRow? in
            let health = watch.health(of: item)
            guard filter.includes(item, health: health), Self.matches(item, query) else { return nil }
            var row = StartupRow(item: item, health: health)
            // The samples are read only while the table sorts by them; otherwise
            // a tick would rebuild every row for figures only their cells show.
            if sortsByUsage, let point = item.pid.flatMap(model.latestProcessPoint) {
                row.cpu = point.cpuPercent
                row.memory = point.memory
            }
            return row
        }
        .sorted(using: sortOrder)
    }

    /// Whether the search finds the item: its name, label, program or property list path.
    private static func matches(_ item: LaunchItem, _ query: String) -> Bool {
        query.isEmpty || [item.name, item.label, item.program ?? "", item.plistPath].contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private var sortsByUsage: Bool {
        let usage: [PartialKeyPath<StartupRow>] = [\.cpu, \.memory]
        return sortOrder.first.map { usage.contains($0.keyPath) } ?? false
    }

    /// Brings the selected row into view, once, if the list shows it.
    private func revealSelection() {
        if let selection { scrollTarget = selection }
    }

    /// The details' Show in List: the row of the item they show, in view and
    /// selected as a click would leave it. A filter or search that hides it
    /// gives way, and in a narrow window the list comes back over the details.
    private func showInList() {
        guard let selection, let item = items?.first(where: { $0.id == selection }) else { return }
        if !filter.includes(item, health: model.launchJobs.watch.health(of: item)) { filter = .all }
        if !Self.matches(item, search.trimmingCharacters(in: .whitespaces)) { search = "" }
        showsFullDetail = false
        select(selection)
    }

    /// Enables an item straight away; disabling asks first, since it stops the job.
    private func toggle(_ item: LaunchItem) {
        if item.isDisabled {
            Task { await perform(.enable, on: item) }
        } else {
            disabling = item
        }
    }

    private func perform(_ action: LaunchControl.Action, on item: LaunchItem) async {
        let result = await Task.detached(priority: .userInitiated) { () -> LaunchControlError? in
            do throws(LaunchControlError) {
                try LaunchControl.perform(action, for: item)
                return nil
            } catch {
                return error
            }
        }.value
        switchError = result?.message
        // A stopped job takes a moment to exit, and a started one to appear.
        if [.start, .restart, .stop].contains(action) { try? await Task.sleep(for: .milliseconds(500)) }
        await scan()
    }

    private func showProcess(_ pid: Int32) {
        model.requestedProcess = pid
        page = .processes
    }

    private func scan() async {
        isScanning = true
        let scanned = await Task.detached(priority: .userInitiated) { LaunchItems.scan() }.value
        apply(scanned)
        scannedAt = .now
        isScanning = false
        // An item picked among an app's launch items on the Apps page, once.
        if let requested = requestedItem {
            requestedItem = nil
            if scanned.contains(where: { $0.id == requested }) {
                await LaunchArgument.afterTableLayout()
                select(requested)
                // Beside the list, not over it, so the row shows in a narrow window too.
                showInspector = true
            }
        }
        // `--args -openStartupItem <text>` picks the first item whose label or name contains it, once, for screenshots.
        if !openedRequest, let query = LaunchArgument.string("openStartupItem") {
            openedRequest = true
            await LaunchArgument.afterTableLayout()
            select(visibleRows(scanned, watch: model.launchJobs.watch).first {
                $0.item.label.localizedCaseInsensitiveContains(query) || $0.item.name.localizedCaseInsensitiveContains(query)
            }?.id)
            openDetails()
        }
    }

    /// Selects a row picked somewhere other than the table, and brings it
    /// into view. As a click would, the row shows the selection's colour,
    /// not the grey of a table without the focus.
    private func select(_ id: LaunchItem.ID?) {
        selection = id
        scrollTarget = id
        Task { tableFocused = true }
    }

    /// Shows a read of launchd's list and notes it for the restart counts.
    private func apply(_ read: [LaunchItem]) {
        if read != items { items = read }
        model.launchJobs.observe(read, processes: model.snapshot?.processes ?? [])
        if let selection, !read.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// Asks launchd again every `LaunchJobStore.readInterval` while the page
    /// is on screen: its job list, as on Refresh, but not the property lists.
    /// Nothing here follows the sampling tick.
    private func followLaunchd() async {
        guard !model.isPaused else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: LaunchJobStore.readInterval)
            guard !Task.isCancelled, !isScanning, let before = items else { continue }
            let read = await Task.detached(priority: .utility) { LaunchItems.withCurrentStatus(before) }.value
            // A full read, after Refresh or an action, finished meanwhile: its list is newer.
            guard !Task.isCancelled, !isScanning, items == before else { continue }
            apply(read)
        }
    }
}

private struct SummaryCard: View {
    var title: String
    var value: Int
    var tint: Color
    var glow = 0.0
    /// What the number counts, under it, where a tooltip alone wouldn't be seen.
    var caption: String?
    var help: String

    var body: some View {
        Card(tint: tint, glow: glow) {
            VStack(alignment: .leading, spacing: 3) {
                Stat(label: title, value: String(value), color: tint)
                if let caption {
                    Text(caption)
                        .font(.metadata)
                        .foregroundStyle(.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .help(help)
    }
}

// MARK: - Table

/// The columns, their widths and the order they give way in are
/// `StartupColumn` in OTMKit: Launches, Publisher, Memory, CPU, then Kind.
extension StartupColumn: FittingColumn {}

private struct StartupTable: View {
    typealias Column = TableColumnContent<StartupRow, KeyPathComparator<StartupRow>>

    /// For the CPU and Memory cells, which read the latest sample.
    let model: AppModel
    var rows: [StartupRow]
    /// Off while the filter leaves one publisher, as every row would say it,
    /// and while the details sit beside the table, which say it once.
    var showsPublisher: Bool
    /// Whether rows can differ in publisher, so a third-party mark in Name
    /// says something once Publisher is off.
    var filterShowsPublisher: Bool
    @Binding var selection: LaunchItem.ID?
    @Binding var sortOrder: [KeyPathComparator<StartupRow>]
    /// A row to scroll into view, cleared once it's done.
    @Binding var scrollTarget: LaunchItem.ID?
    var focus: FocusState<Bool>.Binding
    var toggle: (LaunchItem) -> Void
    var open: () -> Void
    /// Which columns show, set in place rather than by swapping tables (a
    /// conditional column needs macOS 14.4), so the scroll position survives.
    /// Not saved: widths saved in a wide window come back whole in a
    /// narrower one, and push the last columns out of sight.
    @State private var columns = TableColumnCustomization<StartupRow>()
    /// Columns too wide for the table now, lowest priority first.
    @State private var hiddenToFit = StartupColumn.givingWay
    /// Where the asked-for row is in `rows`, until it's been brought into view.
    @State private var revealRow: Int?

    private var userHidden: Set<StartupColumn> { showsPublisher ? [] : [.publisher] }

    var body: some View {
        table
            .onChange(of: scrollTarget, initial: true) { _, target in
                guard let target else { return }
                scrollTarget = nil
                revealRow = rows.firstIndex { $0.id == target }
            }
    }

    private var table: some View {
        let hidden = userHidden.union(hiddenToFit)
        return Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            nameColumn(badgesThirdParty: filterShowsPublisher && hidden.contains(.publisher))
            kindColumn
            statusColumn
            cpuColumn
            memoryColumn
            launchesColumn
            publisherColumn
        }
        .focused(focus)
        .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id })?.item {
                if LaunchControl.restriction(for: item) == nil {
                    Button(item.isDisabled ? "Enable" : "Disable…") { toggle(item) }
                    Divider()
                }
                Button("Reveal in Finder") { StartupActions.reveal(item) }
                Button("Show plist") { StartupActions.openPlist(item) }
                Divider()
                Button("Copy Label") { StartupActions.copyLabel(item) }
                Button("Copy Path") { StartupActions.copyPath(item) }
            }
        } primaryAction: { _ in
            open()
        }
        // The table asks for its columns' minimum widths. Taking what it's
        // given instead, the room it has is what's measured, and its columns
        // never push the page, and the sidebar, out of a narrow window.
        .frame(minWidth: 0, maxWidth: .infinity)
        // In views of their own, so resizing the window re-runs those, not
        // the rows, and the columns change only when one has to give way.
        .background(TableColumnFitter(userHidden: userHidden, hiddenToFit: $hiddenToFit))
        .background(TableColumnSqueeze(columns: StartupColumn.allCases.count, shown: shownCount))
        .background(TableRowReveal(row: $revealRow, rows: rows.count))
        .onChange(of: hidden, initial: true, showColumns)
        // The table writes its columns back as it resizes them, and a write
        // made between Publisher going (the details opening) and the others
        // hiding for the narrower table brought back a column that should
        // have stayed hidden. So any write is checked against what should show.
        .onChange(of: columns, showColumns)
    }

    /// How many columns the table has been told to show.
    private var shownCount: Int {
        StartupColumn.allCases.filter { columns[visibility: $0.rawValue] != .hidden }.count
    }

    private func showColumns() {
        let hidden = userHidden.union(hiddenToFit)
        for column in StartupColumn.allCases where column.priority != nil {
            let visibility: Visibility = hidden.contains(column) ? .hidden : .visible
            if columns[visibility: column.rawValue] != visibility { columns[visibility: column.rawValue] = visibility }
        }
    }

    private func nameColumn(badgesThirdParty: Bool) -> some Column {
        TableColumn("Name", value: \.item.name) { row in
            let item = row.item
            HStack(spacing: 6) {
                Image(nsImage: IconCache.icon(forBundle: item.appBundlePath))
                    .resizable()
                    .frame(width: 16, height: 16)
                if badgesThirdParty, item.publisher == .thirdParty {
                    // The mark shrinks to a symbol before the name is cut short.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text(item.name).lineLimit(1)
                            ThirdPartyBadge(isCompact: false)
                        }
                        HStack(spacing: 6) {
                            Text(item.name).lineLimit(1)
                            ThirdPartyBadge(isCompact: true)
                        }
                    }
                } else {
                    Text(item.name).lineLimit(1)
                }
            }
            // The whole name, for when the column cuts it short.
            .help("\(item.name)\n\(item.label)")
        }
        .fitted(StartupColumn.name)
    }

    private var kindColumn: some Column {
        TableColumn("Kind", value: \.item.scope) { row in
            // "Agent" once the column is too narrow for "System agent".
            ViewThatFits(in: .horizontal) {
                Text(row.item.scope.title)
                Text(row.item.scope.shortTitle)
            }
            .lineLimit(1)
            .help(row.item.scope.title)
        }
        .fitted(StartupColumn.kind)
    }

    /// "Failed exit code 1", "Failed exit 1" in a narrow column, and the
    /// whole of it in the tooltip where only "Failed" fits.
    private var statusColumn: some Column {
        TableColumn("Status", value: \.status) { row in
            LaunchStateLabel(status: row.status)
                .help("\(row.status.summary)\n\(row.status.explanation)\nlaunchd: \(row.status.registration.title)")
        }
        .fitted(StartupColumn.status)
    }

    /// Highest first on the first click, as on the Processes table.
    private var cpuColumn: some Column {
        TableColumn("CPU", sortUsing: KeyPathComparator(\StartupRow.cpu, order: .reverse)) { row in
            JobUsage(model: model, pid: row.item.pid, figure: .cpu)
        }
        .fitted(StartupColumn.cpu)
    }

    private var memoryColumn: some Column {
        TableColumn("Memory", sortUsing: KeyPathComparator(\StartupRow.memory, order: .reverse)) { row in
            JobUsage(model: model, pid: row.item.pid, figure: .memory)
        }
        .fitted(StartupColumn.memory)
    }

    private var launchesColumn: some Column {
        TableColumn("Launches", value: \.item.timing) { row in
            Text(row.item.launchSummary).lineLimit(1).help(row.item.launchSummary)
        }
        .fitted(StartupColumn.launches)
    }

    private var publisherColumn: some Column {
        TableColumn("Publisher", value: \.item.publisher) { row in
            Text(row.item.publisher.title)
                .lineLimit(1)
                .foregroundStyle(row.item.publisher == .apple ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
        }
        .fitted(StartupColumn.publisher)
    }
}

/// A running job's CPU or memory in the latest sample, looked up by the PID
/// launchd gave. It reads the model itself, so a tick redraws only these
/// cells, and only the ones on screen.
///
/// The model is handed in rather than read from the environment: read with
/// `@Environment`, a cell in a narrow window, where columns hide to fit,
/// found no model there, and a missing environment object stops the app.
private struct JobUsage: View {
    enum Figure { case cpu, memory }

    let model: AppModel
    var pid: Int32?
    var figure: Figure

    var body: some View {
        if let pid {
            if let point = model.latestProcessPoint(pid: pid) {
                Text(figure == .cpu ? model.cpuScale.format(point.cpuPercent) : Format.bytes(point.memory))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("—")
                    .foregroundStyle(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(JobUsageText.notSampled(pid))
            }
        }
    }
}

enum JobUsageText {
    /// Why a running job has no figures: launchd's PID is from its last
    /// read, a few seconds old, and that process has gone since.
    static func notSampled(_ pid: Int32) -> String {
        "PID \(String(pid)) isn't in the latest sample: it has probably ended since launchd was last asked."
    }
}

/// Marks a third-party item in the Name column while Publisher is hidden:
/// the words, or a symbol in a narrow column.
private struct ThirdPartyBadge: View {
    var isCompact: Bool
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        // On a selected row the accent colour is behind it, so it turns white like the row's text.
        let selected = prominence == .increased
        Group {
            if isCompact {
                Image(systemName: "shippingbox.fill").imageScale(.small)
            } else {
                Text("Third party")
            }
        }
        .font(.metadata.weight(.medium))
        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.network))
        .padding(.horizontal, isCompact ? 4 : 6)
        .padding(.vertical, 1)
        .background(selected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(Theme.network.fillShade.opacity(0.18)), in: Capsule())
        .fixedSize()
        .help("Third party: installed by something other than macOS")
    }
}

/// What a job is doing: a coloured dot and the state, with its detail (the
/// PID, the exit code, the signal) where there's room, shortened ("exit 1")
/// where there's less. A job that needs a look has a warning sign for its
/// dot. The table's Status column and the details' header both show this,
/// so the two never disagree; whether launchd has the job loaded is the
/// header's line of its own.
struct LaunchStateLabel: View {
    var status: LaunchItemStatus
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        ViewThatFits(in: .horizontal) {
            label(detail: status.detail)
            if let compact = status.compactDetail {
                label(detail: compact)
            }
            label(detail: nil)
        }
        .accessibilityElement(children: .combine)
    }

    private func label(detail: String?) -> some View {
        HStack(spacing: 6) {
            if status.needsAttention {
                // On a selected row it turns white like the row's text.
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(LaunchJobHealth.tint))
            } else {
                Circle().fill(status.color).frame(width: 7, height: 7)
            }
            Text(status.title)
            if let detail {
                // Verbatim, so a PID isn't grouped like a quantity ("4,673").
                Text(verbatim: detail).foregroundStyle(.secondaryText).monospacedDigit()
            }
        }
        .lineLimit(1)
    }
}

extension LaunchItemStatus {
    /// The dot's colour. The states that need a look show a warning sign instead.
    var color: Color {
        switch execution {
        case .running: Theme.disk
        case .notRunning: Theme.cpu
        case .disabled: Theme.swap
        case .notLoaded: Theme.other
        case .restarting, .crashed, .failed: LaunchJobHealth.tint
        }
    }
}

extension LaunchJobHealth {
    /// The app's warning colour, as on the Drivers page's extensions that need attention.
    static var tint: Color { .orange }
}

// MARK: - Status bar

private struct StartupStatusBar: View {
    var shown: Int
    var total: Int
    var scannedAt: Date?
    var isScanning: Bool
    /// The first read of launchd's list this session, which restarts count from.
    var watchedSince: Date?

    var body: some View {
        HStack(spacing: 12) {
            Text(shown == total ? "\(total) items" : "\(shown) of \(total) items")
            if isScanning {
                Text("Reading…")
            } else if let scannedAt {
                Text("Read at \(scannedAt.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            if let watchedSince {
                Text("Restarts counted since \(watchedSince.formatted(date: .omitted, time: .shortened))")
                    .help("OpenTaskManager notes each job's process when it reads launchd's list: when this page opens, "
                        + "on Refresh, and every \(Int(LaunchJobStore.readInterval.components.seconds)) seconds while "
                        + "it's on screen. A new process for the same job counts as a restart.")
            }
        }
        .font(.metadata)
        .monospacedDigit()
        .foregroundStyle(.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// Under an empty Problems list: what would put a job there.
private struct NoProblemsNote: View {
    var since: Date?

    var body: some View {
        let watched = since.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        Label("No problems seen. A job shows here when its last run crashed or failed, or when it's seen "
            + "restarting again and again while this page is open\(watched).", systemImage: "checkmark.circle")
            .font(.explanation)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the table can't show, above it where it reads as the table's scope:
/// Login Items live where only an administrator can read them, so neither
/// the list nor the Start at login card (whose caption says it counts launch
/// jobs) has them. The text wraps rather than truncating in a narrow window.
private struct LoginItemsNote: View {
    static let settings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Login Items (System Settings > General > Login Items) aren't in this list or the Start at login "
                + "count: macOS doesn't let other apps read them.",
                  systemImage: "info.circle")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .help("This page lists launchd's agents and daemons, from the LaunchAgents and LaunchDaemons folders. "
                    + "Apps that open at login, and background items apps register with macOS, are kept where only "
                    + "an administrator can read them, so they aren't here or in Start at login.")
            Spacer(minLength: 0)
            Button("Open Login Items Settings") {
                if let url = Self.settings { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// Shared by the context menu and the detail pane.
@MainActor
enum StartupActions {
    static func reveal(_ item: LaunchItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
    }

    static func openPlist(_ item: LaunchItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: item.plistPath))
    }

    static func copyLabel(_ item: LaunchItem) {
        copy(item.label)
    }

    /// The property list's path, the file Reveal in Finder shows.
    static func copyPath(_ item: LaunchItem) {
        copy(item.plistPath)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
