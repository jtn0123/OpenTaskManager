import OTMKit
import SwiftUI

/// Which apps the Apps table shows.
enum AppsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case thirdParty = "Third party"
    case appStore = "App Store"
    case apple = "Apple"
    case intel = "Intel only"
    case running = "Running"

    var id: String { rawValue }

    func includes(_ row: AppRow) -> Bool {
        switch self {
        case .all: true
        case .thirdParty: row.app.kind == .thirdParty
        case .appStore: row.app.kind == .appStore
        case .apple: row.app.kind == .apple
        case .intel: row.app.architecture == .intel
        case .running: row.isRunning
        }
    }
}

/// One table row: the app plus what the store learns about it later.
struct AppRow: Identifiable {
    let app: InstalledApp
    /// Nil until it's measured, or when it can't be.
    let size: UInt64?
    let pids: [Int32]

    var id: InstalledApp.ID { app.id }
    var isRunning: Bool { !pids.isEmpty }

    // Sort keys for the columns.
    var name: String { app.name }
    var version: String { app.version ?? app.build ?? "" }
    var kind: AppKind { app.kind }
    var architecture: AppArchitecture { app.architecture }
    var sizeOrder: UInt64 { size ?? 0 }
    var lastOpenedOrder: Date { app.lastOpened ?? .distantPast }
}

/// Every app on this Mac: where it came from, what it's built for, who
/// signed it, how much space it takes and whether it starts by itself.
///
/// The folders are read off the main actor when the page opens and on
/// Refresh, then sizes fill in. Nothing follows the sampling tick, and the
/// page reads nothing from `AppModel` as it draws, so once the sizes are in
/// it costs nothing while it sits open.
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("page") private var page: Page = .overview
    @AppStorage("appsFilter") private var filter: AppsFilter = .all
    @AppStorage("showAppsInspector") private var showInspector = true
    @State private var store = InstalledAppStore()
    @State private var search = ""
    @State private var selection: InstalledApp.ID?
    @State private var sortOrder = [KeyPathComparator(\AppRow.name)]
    /// Bumped by Refresh, which restarts the scan.
    @State private var refreshes = 0
    /// A row to bring into view once, for `-openApp`.
    @State private var scrollTarget: InstalledApp.ID?
    @State private var openedRequest = false
    /// The window is too narrow for the table and the details side by side.
    @State private var isNarrow = false
    /// In a narrow window, the details cover the table.
    @State private var showsFullDetail = false
    /// The app whose removal review is open.
    @State private var removing: InstalledApp?
    @FocusState private var tableFocused: Bool

    var body: some View {
        Group {
            if let apps = store.apps {
                page(apps)
            } else {
                ProgressView("Reading applications…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                InventoryRefresh(readAt: store.scannedAt, isReading: store.isScanning,
                                 help: "Look for apps again and measure their sizes again") {
                    refreshes += 1
                }
            }
            ToolbarItem {
                Button(action: toggleDetails) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(isNarrow ? (showsFullDetail ? "Back to the list" : "Show the selected app's details")
                    : "Show details for the selected app")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name, bundle ID, path or team")
        .task(id: refreshes) {
            await store.scan(refresh: refreshes > 0)
            guard !Task.isCancelled, let apps = store.apps else { return }
            await select(in: apps)
            await store.measureSizes()
        }
        .task { await store.followRunningApps() }
        .sheet(item: $removing) { app in
            AppRemovalSheet(app: app, otherApps: store.apps ?? []) {
                store.forget(app.id)
                // Its details go too; in a narrow window that means back to the list.
                if selection == app.id {
                    selection = nil
                    showsFullDetail = false
                }
            }
        }
        .onChange(of: filter) {
            // Drop a selection the filter hides, so its details go with it.
            guard let selection, let app = store.apps?.first(where: { $0.id == selection }) else { return }
            if !filter.includes(AppRow(app: app, size: nil, pids: store.running[selection] ?? [])) {
                self.selection = nil
                showsFullDetail = false
            }
        }
    }

    private func page(_ apps: [InstalledApp]) -> some View {
        let all = apps.map { AppRow(app: $0, size: store.sizes[$0.id], pids: store.running[$0.id] ?? []) }
        let rows = visibleRows(all)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                AppsSummary(rows: all, sizesLeft: store.sizesLeft)
                Picker("Show", selection: $filter) {
                    ForEach(AppsFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            InspectorSplit(
                listMinimum: AppsTable.minimumWidth,
                // Like the Processes inspector, the details take room only once
                // something is selected.
                wantsInspector: showInspector && selection != nil,
                coversList: $showsFullDetail,
                isNarrow: $isNarrow,
                widthKey: "appsInspectorWidth",
                backTitle: "Apps"
            ) {
                AppsTable(rows: rows, isMeasuring: store.sizesLeft > 0, selection: $selection, sortOrder: $sortOrder,
                          scrollTarget: $scrollTarget, focus: $tableFocused, showInStartup: showInStartup,
                          moveToTrash: { removing = $0 }, open: openDetails)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } detail: {
                if let row = all.first(where: { $0.id == selection }) {
                    AppDetail(app: row.app, size: row.size, isMeasuring: store.sizesLeft > 0, pids: row.pids,
                              launchJobs: model.launchJobs.watch,
                              showInStartup: { showInStartup(row.app, item: $0) },
                              moveToTrash: AppActions.offersRemoval(row.app) ? { removing = row.app } : nil)
                } else {
                    ContentUnavailableView("No app selected", systemImage: "info.circle",
                                           description: Text("Select an app to see who signed it and what it starts."))
                }
            }
            Divider()
            AppsStatusBar(shown: rows.count, total: all.count, scannedAt: store.scannedAt, isScanning: store.isScanning,
                          sizesLeft: store.sizesLeft)
        }
    }

    private func visibleRows(_ rows: [AppRow]) -> [AppRow] {
        rows.filter { filter.includes($0) && $0.app.matches(search) }.sorted(using: sortOrder)
    }

    /// Drops a selection a refresh no longer finds, and picks the app
    /// `-openApp` names once (for screenshots).
    private func select(in apps: [InstalledApp]) async {
        if let selection, !apps.contains(where: { $0.id == selection }) { self.selection = nil }
        guard !openedRequest, let query = LaunchArgument.string("openApp") else { return }
        openedRequest = true
        await LaunchArgument.afterTableLayout()
        guard let app = InstalledApps.find(query, in: apps) else { return }
        let row = AppRow(app: app, size: nil, pids: store.running[app.id] ?? [])
        if !filter.includes(row) { filter = .all }
        if !app.matches(search) { search = "" }
        selection = app.id
        scrollTarget = app.id
        openDetails()
        // As a click would: the row shows the selection's colour, not the
        // grey of a table without the focus.
        Task { tableFocused = true }
        // `-openAppRemoval YES` opens its removal review too.
        if LaunchArgument.string("openAppRemoval") != nil, AppActions.offersRemoval(app) { removing = app }
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

    /// Opens the Startup page searching for this app's launch items.
    private func showInStartup(_ app: InstalledApp) {
        showInStartup(app, item: nil)
    }

    /// The same, with `item` selected there and its row in view.
    private func showInStartup(_ app: InstalledApp, item: LaunchItem?) {
        guard let query = app.startupSearchText else { return }
        model.requestedStartupSearch = query
        model.requestedStartupItem = item?.id
        page = .startup
    }
}

// MARK: - Summary

private struct AppsSummary: View {
    var rows: [AppRow]
    var sizesLeft: Int

    var body: some View {
        let sized = rows.filter { $0.size != nil }
        let total = sized.reduce(0) { $0 + Double($1.size ?? 0) }
        let largest = sized.max { $0.sizeOrder < $1.sizeOrder }
        let intel = rows.filter { $0.app.architecture == .intel }.count
        // Apps whose executable couldn't be read: any of them might need Rosetta.
        let unknown = rows.filter { $0.app.architecture == .unknown }
        let running = rows.filter(\.isRunning).count
        let selfStarting = rows.filter { $0.app.startsItself }.count
        let thirdParty = rows.filter { $0.app.kind == .thirdParty }.count
        let appStore = rows.filter { $0.app.kind == .appStore }.count

        FillGrid(minimum: 140, spacing: 12) {
            AppsCard(tint: Theme.cpu, detail: "\(thirdParty) third party, \(appStore) App Store",
                     help: "Apps in the Applications folders, plus any others Spotlight knows about") {
                Stat(label: "Apps", value: String(rows.count), color: Theme.cpu)
            }
            AppsCard(tint: Theme.memory,
                     detail: sizesLeft > 0 ? "Measuring, \(sizesLeft) to go" : largest.map { "Largest: \($0.app.name)" } ?? "Nothing measured",
                     help: "Space the bundles take on disk. Documents, caches and settings each app keeps in your Library aren't counted.") {
                Stat(label: "Total size", number: total, color: Theme.memory, format: Format.bytes)
            }
            AppsCard(tint: Theme.network, detail: AppText.intelDetail(intel: intel, unknown: unknown.count),
                     help: AppText.intelHelp(unknown: unknown.map(\.app.name))) {
                Stat(label: "Intel only", value: String(intel), color: Theme.network)
            }
            AppsCard(tint: Theme.disk, detail: selfStarting == 1 ? "1 app starts by itself" : "\(selfStarting) apps start by themselves",
                     help: "Apps open right now. Below: apps with a launch agent or daemon that starts without being asked.") {
                Stat(label: "Running now", value: String(running), color: Theme.disk)
            }
        }
    }
}

private struct AppsCard<Content: View>: View {
    var tint: Color
    var detail: String
    var help: String
    @ViewBuilder var content: Content

    var body: some View {
        Card(tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                content
                // Two lines in the narrowest window; the grid keeps the cards level.
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(2)
            }
        }
        .help(help)
    }
}

// MARK: - Table

private struct AppsTable: View {
    typealias Column = TableColumnContent<AppRow, KeyPathComparator<AppRow>>

    /// Narrowest each column gets. The columns after Name hold short values,
    /// so they also stop soon after their ideal width and Name takes the rest.
    private enum Minimum {
        static let name: CGFloat = 130
        static let version: CGFloat = 45
        static let kind: CGFloat = 75
        static let architecture: CGFloat = 85
        static let size: CGFloat = 55
        static let lastOpened: CGFloat = 70
    }

    /// The gaps between `count` columns, plus the table's side insets and a
    /// vertical scroller for when scroll bars always show. Without those the
    /// table scrolled sideways at 1100 points.
    private static func chrome(columns count: Int) -> CGFloat {
        CGFloat(count) * 17 + 2 * 10 + 16
    }

    /// Narrowest the table goes without scrolling sideways: Name, Version,
    /// Size and Last opened, the columns a narrow table keeps.
    static let minimumWidth = Minimum.name + Minimum.version + Minimum.size + Minimum.lastOpened + chrome(columns: 4)

    /// Name's width when there's room.
    private static let nameIdeal: CGFloat = 190

    /// Below this, where Name would go under its ideal width (as in the
    /// narrowest window with the sidebar shown), Kind and Architecture make
    /// way: their values repeat down the table and the details give both.
    /// Name then tags the apps whose architecture is worth a look.
    static let fullWidth = nameIdeal + Minimum.version + Minimum.kind + Minimum.architecture + Minimum.size
        + Minimum.lastOpened + chrome(columns: 6)

    private static let kindID = "kind"
    private static let architectureID = "architecture"

    var rows: [AppRow]
    var isMeasuring: Bool
    @Binding var selection: InstalledApp.ID?
    @Binding var sortOrder: [KeyPathComparator<AppRow>]
    @Binding var scrollTarget: InstalledApp.ID?
    var focus: FocusState<Bool>.Binding
    var showInStartup: (InstalledApp) -> Void
    var moveToTrash: (InstalledApp) -> Void
    var open: () -> Void
    /// Hides Kind and Architecture in place, rather than swapping tables (a
    /// conditional column needs macOS 14.4), so the scroll position survives.
    @State private var columns = TableColumnCustomization<AppRow>()
    @State private var isCompact = false

    var body: some View {
        let fullWidth = Self.fullWidth
        ScrollViewReader { proxy in
            table
                .onChange(of: scrollTarget, initial: true) { _, target in
                    guard let target else { return }
                    // Leading, not centre: centring would also scroll the columns sideways.
                    proxy.scrollTo(target, anchor: .leading)
                    scrollTarget = nil
                }
        }
        // Only crossing the breakpoint changes anything, not every resize.
        .onGeometryChange(for: Bool.self) { $0.size.width < fullWidth } action: { isCompact = $0 }
        .onChange(of: isCompact, initial: true, showColumns)
    }

    private func showColumns() {
        let visibility: Visibility = isCompact ? .hidden : .visible
        for id in [Self.kindID, Self.architectureID] where columns[visibility: id] != visibility {
            columns[visibility: id] = visibility
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            nameColumn
            versionColumn
            kindColumn
            architectureColumn
            sizeColumn
            lastOpenedColumn
        }
        .focused(focus)
        .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
            if let id = ids.first, let app = rows.first(where: { $0.id == id })?.app {
                Button("Open") { AppActions.open(app) }
                Button("Reveal in Finder") { AppActions.reveal(app) }
                Button("Show in Startup") { showInStartup(app) }
                    .disabled(app.launchItems.isEmpty)
                Divider()
                Button("Copy Bundle ID") { AppActions.copy(app.bundleIdentifier ?? "") }
                    .disabled(app.bundleIdentifier == nil)
                Button("Copy Path") { AppActions.copy(app.path) }
                if AppActions.offersRemoval(app) {
                    Divider()
                    Button("Move to Trash…") { moveToTrash(app) }
                }
            }
        } primaryAction: { _ in
            open()
        }
    }

    private var nameColumn: some Column {
        TableColumn("Name", value: \.name) { row in
            AppNameCell(row: row, tagsArchitecture: isCompact)
        }
        .width(min: Minimum.name, ideal: Self.nameIdeal)
    }

    private var versionColumn: some Column {
        TableColumn("Version", value: \.version) { row in
            Text(row.app.version ?? row.app.build ?? "—")
                .lineLimit(1)
                .help(row.app.versionText)
        }
        .width(min: Minimum.version, ideal: 55, max: 100)
    }

    private var kindColumn: some Column {
        TableColumn("Kind", value: \.kind) { row in
            Text(row.app.kind.title)
                .foregroundStyle(row.app.kind == .apple ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
        }
        .width(min: Minimum.kind, ideal: 80, max: 110)
        .customizationID(Self.kindID)
        // Shown and hidden with the table's width, not from the header's menu.
        .disabledCustomizationBehavior(.visibility)
    }

    private var architectureColumn: some Column {
        TableColumn("Architecture", value: \.architecture) { row in
            ArchitectureLabel(app: row.app)
        }
        .width(min: Minimum.architecture, ideal: 95, max: 130)
        .customizationID(Self.architectureID)
        .disabledCustomizationBehavior(.visibility)
    }

    private var sizeColumn: some Column {
        TableColumn("Size", value: \.sizeOrder) { row in
            Text(row.size.map(Format.bytes) ?? (isMeasuring ? "…" : "—"))
                .monospacedDigit()
                .foregroundStyle(row.size == nil ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: Minimum.size, ideal: 65, max: 90)
    }

    private var lastOpenedColumn: some Column {
        TableColumn("Last opened", value: \.lastOpenedOrder) { row in
            Text(AppText.lastOpened(row.app.lastOpened))
                .foregroundStyle(row.app.lastOpened == nil ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
                .help(row.app.lastOpened.map { $0.formatted(date: .complete, time: .shortened) } ?? "Spotlight has no record of it being opened")
        }
        .width(min: Minimum.lastOpened, ideal: 75, max: 110)
    }
}

/// The icon and name, a dot while it runs, and a sunrise when it starts by
/// itself. While Architecture is hidden, a tag on the apps that need Rosetta,
/// can't run, or couldn't be read.
private struct AppNameCell: View {
    var row: AppRow
    var tagsArchitecture = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(forBundle: row.app.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(row.app.name).lineLimit(1)
            if row.isRunning {
                Circle().fill(Theme.disk).frame(width: 6, height: 6)
                    .help("Running")
                    .accessibilityLabel("Running")
            }
            if row.app.startsItself {
                Image(systemName: "sunrise.fill")
                    .imageScale(.small)
                    .foregroundStyle(Theme.power)
                    .help("Has a launch agent or daemon that starts by itself")
                    .accessibilityLabel("Starts by itself")
            }
            if tagsArchitecture, let tag = ArchitectureTag(row.app.architecture) {
                tag
            }
        }
        .help(row.app.path)
    }
}

/// A small tag for an architecture worth a look: Intel only (Rosetta),
/// 32-bit or PowerPC (can't run) and unknown. Nothing for native apps.
private struct ArchitectureTag: View {
    @Environment(\.backgroundProminence) private var prominence
    let title: String
    let color: Color
    let help: String

    init?(_ architecture: AppArchitecture) {
        switch architecture {
        case .intel:
            (title, color, help) = ("Intel only", Theme.network, "Built only for Intel processors: runs under Rosetta")
        case .unsupported:
            (title, color, help) = ("Can't run", .red, "Built only for 32-bit or PowerPC processors, which current macOS can't run")
        case .unknown:
            (title, color, help) = ("Architecture unknown", Theme.smallerItems,
                                    "Its executable is missing or isn't a Mach-O program (a script, say), so it may need Rosetta")
        case .appleSilicon, .universal:
            return nil
        }
    }

    var body: some View {
        // On a selected row the accent colour is behind it, so it turns white like the row's text.
        let selected = prominence == .increased
        Text(title)
            .font(.metadata.weight(.medium))
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(selected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(color.fillShade.opacity(0.18)), in: Capsule())
            .fixedSize()
            .help(help)
    }
}

/// The architecture, with Intel-only apps called out since they need Rosetta.
struct ArchitectureLabel: View {
    var app: InstalledApp

    var body: some View {
        switch app.architecture {
        case .intel:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                Text(app.architecture.title)
            }
            .foregroundStyle(Theme.network)
            .help("Built only for Intel processors: runs under Rosetta")
        case .unsupported:
            Text(app.architecture.title)
                .foregroundStyle(.red)
                .help("Built only for 32-bit or PowerPC processors, which current macOS can't run")
        case .unknown:
            Text(app.architecture.title)
                .foregroundStyle(.secondaryText)
                .help("Its executable is missing or isn't a Mach-O program (a script, say)")
        case .appleSilicon, .universal:
            Text(app.architecture.title)
                .help(app.sliceNames ?? "")
        }
    }
}

// MARK: - Status bar

private struct AppsStatusBar: View {
    var shown: Int
    var total: Int
    var scannedAt: Date?
    var isScanning: Bool
    var sizesLeft: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(shown == total ? "\(total) apps" : "\(shown) of \(total) apps")
            if isScanning {
                Text("Reading…")
            } else if let scannedAt {
                Text("Read at \(scannedAt.formatted(date: .omitted, time: .shortened))")
            }
            if sizesLeft > 0 {
                Text("Measuring sizes, \(sizesLeft) to go")
            }
            Spacer()
            Text("Last opened is what Spotlight recorded")
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .help("Spotlight notes when an app is opened from Finder, the Dock or Launchpad. Apps opened other "
                    + "ways, or on a volume Spotlight doesn't index, show a dash.")
        }
        .font(.metadata)
        .monospacedDigit()
        .foregroundStyle(.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: - Shared

/// Shared by the context menu and the detail pane.
@MainActor
enum AppActions {
    static func open(_ app: InstalledApp) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }

    static func reveal(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whether "Move to Trash…" is offered: never for Apple's apps, macOS's
    /// own or OpenTaskManager (any copy of it).
    static func offersRemoval(_ app: InstalledApp) -> Bool {
        AppRemoval.refusal(for: app, ownBundleIdentifier: Bundle.main.bundleIdentifier, ownBundlePath: Bundle.main.bundlePath) == nil
    }
}

enum AppText {
    /// The Intel card's line. "Nothing needs Rosetta" only when every app's
    /// architecture is known; otherwise the unknowns are counted beside the
    /// confirmed ones, since any of them might be Intel-only.
    static func intelDetail(intel: Int, unknown: Int) -> String {
        if unknown > 0 { return "\(intel) confirmed · \(unknown) unknown" }
        return intel == 0 ? "Nothing needs Rosetta" : "Run under Rosetta"
    }

    static func intelHelp(unknown names: [String]) -> String {
        let intel = "Apps built only for Intel processors. On Apple silicon they run under Rosetta translation."
        guard !names.isEmpty else { return intel }
        let shown = names.count > 3 ? names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
            : ListFormatter.localizedString(byJoining: names)
        return intel + " Unknown: \(shown). Their executable is missing or isn't a Mach-O program (a script, say), so "
            + "what they're built for can't be read, and they aren't counted above."
    }

    /// "Today", "Yesterday" or the date ("Aug 18", "Mar 3, 2024"); a dash when Spotlight doesn't know.
    static func lastOpened(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        // The year only when it isn't this one, so the column stays narrow.
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
