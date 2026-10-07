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

    var id: String { rawValue }

    func includes(_ item: LaunchItem) -> Bool {
        switch self {
        case .all: true
        case .thirdParty: item.publisher == .thirdParty
        case .apple: item.publisher == .apple
        case .running: item.pid != nil
        case .agents: item.scope.isAgent
        case .daemons: item.scope == .daemon
        }
    }
}

/// Everything launchd starts by itself: the agents and daemons in the
/// LaunchAgents and LaunchDaemons folders, with what launchd says about each.
///
/// The scan runs off the main actor when the page opens and on Refresh. It
/// never follows the sampling tick, and the page reads nothing from
/// `AppModel`, so it costs nothing while it sits open.
struct StartupView: View {
    @AppStorage("startupFilter") private var filter: StartupFilter = .all
    @AppStorage("showStartupInspector") private var showInspector = true
    @State private var items: [LaunchItem]?
    @State private var scannedAt: Date?
    @State private var isScanning = false
    @State private var search = ""
    @State private var selection: LaunchItem.ID?
    @State private var sortOrder = [KeyPathComparator(\LaunchItem.publisher), KeyPathComparator(\LaunchItem.name)]

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
                Button {
                    Task { await scan() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
                .help("Read the launchd folders and ask launchd again")
            }
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show details for the selected item")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Label, program or path")
        .task {
            if items == nil { await scan() }
        }
    }

    private func page(_ items: [LaunchItem]) -> some View {
        let rows = visibleRows(items)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                summary(items)
                Picker("Show", selection: $filter) {
                    ForEach(StartupFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // A pane beside the table, like the Connections details, rather than
            // an inspector column: with the toolbar's search field, an inspector
            // pushed the window's content past both of its edges.
            HStack(spacing: 0) {
                StartupTable(rows: rows, selection: $selection, sortOrder: $sortOrder)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    Divider()
                    Group {
                        if let item = items.first(where: { $0.id == selection }) {
                            StartupItemDetail(item: item)
                        } else {
                            ContentUnavailableView("No item selected", systemImage: "info.circle",
                                                   description: Text("Select an item to see what it runs and when."))
                        }
                    }
                    .frame(width: 300)
                }
            }
            Divider()
            StartupStatusBar(shown: rows.count, total: items.count, scannedAt: scannedAt, isScanning: isScanning)
        }
    }

    private func summary(_ items: [LaunchItem]) -> some View {
        FillGrid(minimum: 140, spacing: 12) {
            SummaryCard(title: "Total", value: items.count, tint: Theme.cpu,
                        help: "Property lists in the five LaunchAgents and LaunchDaemons folders")
            SummaryCard(title: "Running", value: items.filter { $0.pid != nil }.count, tint: Theme.disk,
                        help: "Jobs with a process running right now")
            SummaryCard(title: "Third party", value: items.filter { $0.publisher == .thirdParty }.count, tint: Theme.network,
                        help: "Installed by something other than macOS")
            SummaryCard(title: "Launch at login", value: items.filter(\.startsAutomatically).count, tint: Theme.memory,
                        help: "Agents that start when you log in and daemons that start at boot, unless they're disabled")
        }
    }

    private func visibleRows(_ items: [LaunchItem]) -> [LaunchItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            filter.includes(item) && (query.isEmpty || [item.name, item.label, item.program ?? "", item.plistPath].contains {
                $0.localizedCaseInsensitiveContains(query)
            })
        }
        .sorted(using: sortOrder)
    }

    private func scan() async {
        isScanning = true
        let scanned = await Task.detached(priority: .userInitiated) { LaunchItems.scan() }.value
        items = scanned
        scannedAt = .now
        isScanning = false
        if selection == nil || !scanned.contains(where: { $0.id == selection }) {
            // `--args -openStartupItem <text>` picks the first item whose label or name contains it, for screenshots.
            let rows = visibleRows(scanned)
            let requested = LaunchArgument.string("openStartupItem").flatMap { query in
                rows.first { $0.label.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
            }
            selection = (requested ?? rows.first)?.id
        }
    }
}

private struct SummaryCard: View {
    var title: String
    var value: Int
    var tint: Color
    var help: String

    var body: some View {
        Card(tint: tint) {
            Stat(label: title, value: String(value), color: tint)
        }
        .help(help)
    }
}

// MARK: - Table

private struct StartupTable: View {
    var rows: [LaunchItem]
    @Binding var selection: LaunchItem.ID?
    @Binding var sortOrder: [KeyPathComparator<LaunchItem>]

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(forBundle: item.appBundlePath))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name).lineLimit(1)
                }
                .help(item.label)
            }
            .width(min: 130, ideal: 200)
            TableColumn("Kind", value: \.scope) { item in
                Text(item.scope.title)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Status", value: \.state) { item in
                LaunchStateLabel(state: item.state)
            }
            .width(min: 110, ideal: 155)
            TableColumn("Launches", value: \.timing) { item in
                Text(item.launchSummary).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Publisher", value: \.publisher) { item in
                Text(item.publisher.title)
                    .foregroundStyle(item.publisher == .apple ? .secondary : .primary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                Button("Reveal in Finder") { StartupActions.reveal(item) }
                Button("Show plist") { StartupActions.openPlist(item) }
                Divider()
                Button("Copy Label") { StartupActions.copyLabel(item) }
            }
        }
    }
}

/// A coloured dot and the state, with the PID while it runs.
struct LaunchStateLabel: View {
    var state: LaunchItemState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(state.title)
            if case let .running(pid) = state {
                // Verbatim, so the PID isn't grouped like a quantity ("4,673").
                Text(verbatim: "PID \(pid)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .lineLimit(1)
    }
}

extension LaunchItemState {
    var color: Color {
        switch self {
        case .running: Theme.disk
        case .loaded: Theme.cpu
        case .disabled: Theme.swap
        case .notLoaded: Theme.other
        }
    }
}

// MARK: - Status bar

private struct StartupStatusBar: View {
    static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    var shown: Int
    var total: Int
    var scannedAt: Date?
    var isScanning: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(shown == total ? "\(total) items" : "\(shown) of \(total) items")
            if isScanning {
                Text("Reading…")
            } else if let scannedAt {
                Text("Read at \(scannedAt.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Text("Login Items aren't listed: macOS keeps them private")
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .help("Apps that open at login, and background items apps register with macOS, are kept where only "
                    + "an administrator can read them. System Settings shows and changes them.")
            Button("Open Login Items Settings") {
                if let url = Self.loginItemsSettings { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
        }
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.label, forType: .string)
    }
}
