import OTMKit
import SwiftUI

/// Which extensions the Drivers table shows. Third party comes first: on most
/// Macs everything else is part of macOS.
enum DriversFilter: String, CaseIterable, Identifiable {
    case thirdParty = "Third party"
    case apple = "Apple"
    case all = "All"

    var id: String { rawValue }

    func includes(_ item: ExtensionItem) -> Bool {
        switch self {
        case .thirdParty: item.publisher == .thirdParty
        case .apple: item.publisher == .apple
        case .all: true
        }
    }

    /// Whether rows can differ in publisher. Under Apple or Third party the
    /// column would say the same thing on every row, so it gives its room to Name.
    var showsPublisher: Bool { self == .all }
}

/// What's been added to macOS below the app level: system extensions (network
/// filters and VPNs, DriverKit drivers, endpoint security) and the kernel
/// extensions loaded into the kernel.
///
/// Like the Startup page, it reads once off the main actor when the page
/// opens and again on Refresh. It never follows the sampling tick, and reads
/// nothing from `AppModel`, so it costs nothing while it sits open.
struct DriversView: View {
    @AppStorage("driversFilter") private var filter: DriversFilter = .thirdParty
    @AppStorage("showDriversInspector") private var showInspector = true
    @State private var scan: ExtensionScan?
    @State private var scannedAt: Date?
    @State private var isScanning = false
    @State private var search = ""
    @State private var selection: ExtensionItem.ID?
    @State private var openedRequest = false
    /// The window is too narrow for the table and the details side by side.
    @State private var isNarrow = false
    /// In a narrow window, the details cover the table.
    @State private var showsFullDetail = false
    @State private var sortOrder = [
        KeyPathComparator(\ExtensionItem.publisher), KeyPathComparator(\ExtensionItem.category), KeyPathComparator(\ExtensionItem.name),
    ]

    var body: some View {
        Group {
            if let scan {
                page(scan)
            } else {
                ProgressView("Reading extensions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await rescan() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
                .help("Ask the kernel and systemextensionsctl again")
            }
            ToolbarItem {
                Button(action: toggleDetails) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(isNarrow ? (showsFullDetail ? "Back to the list" : "Show the selected extension's details")
                    : "Show details for the selected extension")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name, bundle ID or team")
        .task {
            if scan == nil { await rescan() }
        }
        .onChange(of: filter) {
            // Drop a selection the filter hides, so its details go with it.
            guard let scan else { return }
            if !visibleRows(scan.items).contains(where: { $0.id == selection }) { selection = nil }
        }
    }

    private func page(_ scan: ExtensionScan) -> some View {
        let rows = visibleRows(scan.items)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DriverSummaryCards(scan: scan)
                Picker("Show", selection: $filter) {
                    ForEach(DriversFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // A pane beside the table, as on the Startup page, rather than an
            // inspector column, which the toolbar's search field pushes past
            // the window's edges. With nothing to list, both give way to a note.
            if rows.isEmpty {
                Divider()
                emptyState(scan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content(rows, scan: scan)
            }
            Divider()
            DriversStatusBar(shown: rows.count, scan: scan, scannedAt: scannedAt, isScanning: isScanning)
        }
    }

    private func content(_ rows: [ExtensionItem], scan: ExtensionScan) -> some View {
        let selected = rows.first { $0.id == selection }
        return InspectorSplit(
            listMinimum: DriverTable.minimumWidth(showsPublisher: filter.showsPublisher),
            // Like the Processes inspector, the details take room only once
            // something is selected.
            wantsInspector: showInspector && selected != nil,
            coversList: $showsFullDetail,
            isNarrow: $isNarrow,
            widthKey: "driversInspectorWidth",
            backTitle: "Drivers"
        ) {
            DriverTable(rows: rows, showsPublisher: filter.showsPublisher, selection: $selection, sortOrder: $sortOrder,
                        open: openDetails)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            if let selected {
                DriverDetail(item: selected, scan: scan)
            } else {
                ContentUnavailableView("No extension selected", systemImage: "info.circle",
                                       description: Text("Select an extension to see what it does and where it came from."))
            }
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

    @ViewBuilder
    private func emptyState(_ scan: ExtensionScan) -> some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: search)
        } else if filter == .thirdParty {
            let apple = scan.items.filter { $0.publisher == .apple }.count
            EmptyNote(symbol: "checkmark.seal.fill", tint: Theme.disk,
                      title: "No third-party drivers or extensions are loaded",
                      detail: apple > 0
                          ? "Everything loaded on this Mac comes with macOS, including \(apple) of Apple's kernel extensions."
                          : "Nothing from another developer runs in the kernel or as a system extension.") {
                if apple > 0 {
                    Button("Show Apple's Extensions") { filter = .apple }
                }
            }
        } else {
            EmptyNote(symbol: "puzzlepiece.extension", tint: Theme.other, title: "Nothing to show",
                      detail: "No extensions could be read on this Mac.") { EmptyView() }
        }
    }

    private func visibleRows(_ items: [ExtensionItem]) -> [ExtensionItem] {
        items.filter { filter.includes($0) && $0.matches(search) }.sorted(using: sortOrder)
    }

    private func rescan() async {
        isScanning = true
        let scanned = await Task.detached(priority: .userInitiated) { Extensions.scan() }.value
        scan = scanned
        scannedAt = .now
        isScanning = false
        if let selection, !scanned.items.contains(where: { $0.id == selection }) { self.selection = nil }
        // `--args -openDriver <text>` picks the first extension whose name or bundle ID
        // contains it, once, switching the filter if it hides it, for screenshots.
        guard !openedRequest, let query = LaunchArgument.string("openDriver") else { return }
        openedRequest = true
        if let requested = scanned.items.sorted(using: sortOrder).first(where: {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }) {
            if !filter.includes(requested) { filter = requested.publisher == .apple ? .apple : .thirdParty }
            selection = requested.id
            openDetails()
        }
    }
}

// MARK: - Summary

private struct DriverSummaryCards: View {
    var scan: ExtensionScan

    var body: some View {
        let summary = scan.summary
        FillGrid(minimum: 150, spacing: 12) {
            DriverSummaryCard(title: "System extensions", value: summary.systemExtensions, symbol: "puzzlepiece.extension",
                              tint: Theme.gpu, detail: systemDetail,
                              explanation: "Network filters and VPNs, DriverKit drivers and security tools that apps installed "
                                  + "and macOS allowed. They run outside the kernel.")
            DriverSummaryCard(title: "Third-party kexts", value: summary.thirdPartyKernelExtensions, symbol: "shippingbox",
                              tint: Theme.memory,
                              detail: summary.thirdPartyKernelExtensions == 0 ? "None loaded" : "Running inside the kernel",
                              explanation: "Kernel extensions from developers other than Apple. They run inside the kernel "
                                  + "with full access to the Mac.")
            DriverSummaryCard(title: "Loaded kexts", value: summary.loadedKernelExtensions, symbol: "cpu",
                              tint: Theme.cpu, detail: wiredDetail,
                              explanation: "Every kernel extension loaded now, Apple's included, and the memory their code keeps wired.")
            DriverSummaryCard(title: "Needs attention", value: summary.needsAttention, symbol: "exclamationmark.triangle",
                              tint: summary.needsAttention > 0 ? .orange : Theme.disk,
                              glow: summary.needsAttention > 0 ? 0.35 : 0,
                              detail: summary.needsAttention > 0 ? "Waiting for your approval" : "Nothing waiting",
                              explanation: "System extensions macOS won't run until someone allows them in System Settings.")
        }
    }

    /// "1 network · 1 driver", or why there's no count.
    private var systemDetail: String {
        guard scan.readSystemExtensions else { return "Couldn't be read" }
        let system = scan.items.filter(\.category.isSystemExtension)
        guard !system.isEmpty else { return "None installed" }
        let counts: [(ExtensionCategory, String)] = [
            (.network, "network"), (.driver, "driver"), (.endpointSecurity, "security"), (.otherSystem, "other"),
        ]
        return counts.compactMap { category, word in
            let count = system.filter { $0.category == category }.count
            return count > 0 ? "\(count) \(word)" : nil
        }
        .joined(separator: " · ")
    }

    private var wiredDetail: String {
        guard scan.readKernelExtensions else { return "Couldn't be read" }
        let wired = scan.items.compactMap(\.kernelExtension).reduce(UInt64(0)) { $0 + $1.wiredSize }
        return "\(Format.bytes(wired)) wired"
    }
}

private struct DriverSummaryCard: View {
    private static let valueFont = NSFont.numeric(size: 24, weight: .semibold, rounded: true)

    var title: String
    var value: Int
    var symbol: String
    var tint: Color
    var glow = 0.0
    var detail: String
    var explanation: String

    var body: some View {
        Card(tint: tint, glow: glow) {
            Label {
                Text(title).lineLimit(2)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondaryText)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                AnimatedNumber(value: Double(value), format: { Format.fixed($0, 0) }, font: Self.valueFont)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
        }
        .help(explanation)
    }
}

/// What the page says when the filter leaves nothing to list. Smaller than
/// `ContentUnavailableView`, so the sentence stays on one line.
private struct EmptyNote<Actions: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(tint)
                .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondaryText)
            actions
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }
}

// MARK: - Table

private struct DriverTable: View {
    typealias Column = TableColumnContent<ExtensionItem, KeyPathComparator<ExtensionItem>>

    var rows: [ExtensionItem]
    /// Off while the filter leaves one publisher, as every row would say it.
    var showsPublisher: Bool
    @Binding var selection: ExtensionItem.ID?
    @Binding var sortOrder: [KeyPathComparator<ExtensionItem>]
    var open: () -> Void

    /// Narrowest each column gets: room for its usual values (a version
    /// like "2811.160.7"), so Name is the one that gives way. All five fit
    /// the narrowest window.
    private enum Minimum {
        static let name: CGFloat = 121
        static let kind: CGFloat = 115
        static let status: CGFloat = 115
        static let publisher: CGFloat = 70
        static let version: CGFloat = 84
    }

    /// The columns at their narrowest, the gaps between them, and the
    /// table's own insets and scroller.
    static func minimumWidth(showsPublisher: Bool) -> CGFloat {
        let columns = Minimum.name + Minimum.kind + Minimum.status + Minimum.version + (showsPublisher ? Minimum.publisher : 0)
        return columns + (showsPublisher ? 5 : 4) * 17 + 32
    }

    var body: some View {
        // Brings a row picked before the table appeared (`-openDriver`) into view.
        ScrollViewReader { proxy in
            table.onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    /// The other columns hold short values that repeat down the table, so they
    /// start at the width those need and stop soon after; Name takes the rest.
    private var table: some View {
        Group {
            // Two tables rather than a conditional column, which needs macOS 14.4.
            if showsPublisher {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    nameColumn
                    kindColumn
                    statusColumn
                    publisherColumn
                    versionColumn
                }
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    nameColumn
                    kindColumn
                    statusColumn
                    versionColumn
                }
            }
        }
        .contextMenu(forSelectionType: ExtensionItem.ID.self) { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                if let path = DriverActions.revealablePath(item) {
                    Button("Reveal in Finder") { DriverActions.reveal(path) }
                }
                if item.systemExtension != nil {
                    Button("Open Login Items & Extensions Settings") { DriverActions.openSettings() }
                }
                Divider()
                Button("Copy Bundle ID") { DriverActions.copy(item.bundleID) }
            }
        } primaryAction: { _ in
            open()
        }
    }

    private var nameColumn: some Column {
        TableColumn("Name", value: \.name) { item in
            HStack(spacing: 6) {
                ExtensionIcon(item: item, size: 16)
                Text(item.name).lineLimit(1)
            }
            // The whole name, for when the column cuts it short.
            .help("\(item.name)\n\(item.bundleID)")
        }
        .width(min: Minimum.name, ideal: 260)
    }

    private var kindColumn: some Column {
        TableColumn("Kind", value: \.category) { item in
            Text(item.kind).lineLimit(1).help(item.kind)
        }
        .width(min: Minimum.kind, ideal: 120, max: 140)
    }

    private var statusColumn: some Column {
        TableColumn("Status", value: \.status) { item in
            ExtensionStatusLabel(status: item.status).help(item.status.title)
        }
        .width(min: Minimum.status, ideal: 120, max: 160)
    }

    private var publisherColumn: some Column {
        TableColumn("Publisher", value: \.publisher) { item in
            Text(item.publisher.title)
                .foregroundStyle(item.publisher == .apple ? .secondary : .primary)
        }
        .width(min: Minimum.publisher, ideal: 75, max: 100)
    }

    private var versionColumn: some Column {
        TableColumn("Version", value: \.version) { item in
            Text(item.version.isEmpty ? "—" : item.version)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                .help(item.version)
        }
        .width(min: Minimum.version, ideal: 90, max: 120)
    }
}

/// The installing app's icon for a system extension, or a symbol for its kind.
struct ExtensionIcon: View {
    var item: ExtensionItem
    var size: CGFloat

    var body: some View {
        // An extension can outlive its app until the next restart.
        if let app = item.systemExtension?.appPath, FileManager.default.fileExists(atPath: app) {
            Image(nsImage: IconCache.icon(forBundle: app))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: item.category.symbol)
                .font(.system(size: size * 0.75))
                .foregroundStyle(item.isKernelInterface ? Theme.other : item.category.tint)
                .frame(width: size, height: size)
        }
    }
}

/// A coloured dot and the status, like the Startup page's state label.
struct ExtensionStatusLabel: View {
    var status: ExtensionStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 7, height: 7)
            Text(status.title)
                .fontWeight(status.needsAttention ? .semibold : .regular)
        }
        .lineLimit(1)
    }
}

extension ExtensionStatus {
    var color: Color {
        switch self {
        case .needsApproval: .orange
        case .active, .loaded: Theme.disk
        case .notStarted, .enabled: Theme.cpu
        case .disabled: Theme.other
        case .uninstalling: Theme.swap
        case .other: Theme.power
        }
    }
}

extension ExtensionCategory {
    var symbol: String {
        switch self {
        case .network: "network"
        case .driver: "cable.connector"
        case .endpointSecurity: "lock.shield"
        case .otherSystem: "puzzlepiece.extension"
        case .kernel: "puzzlepiece"
        }
    }

    var tint: Color {
        switch self {
        case .network: Theme.network
        case .driver: Theme.gpu
        case .endpointSecurity: Theme.disk
        case .otherSystem: Theme.memory
        case .kernel: Theme.cpu
        }
    }
}

// MARK: - Status bar

private struct DriversStatusBar: View {
    var shown: Int
    var scan: ExtensionScan
    var scannedAt: Date?
    var isScanning: Bool

    var body: some View {
        let total = scan.items.count
        HStack(spacing: 12) {
            Text(shown == total ? "\(total) extensions" : "\(shown) of \(total) extensions")
            if isScanning {
                Text("Reading…")
            } else if let scannedAt {
                Text("Read at \(scannedAt.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            if !scan.readSystemExtensions {
                Label("System extensions couldn't be read", systemImage: "exclamationmark.triangle")
                    .help("systemextensionsctl didn't answer, so system extensions are unknown rather than absent.")
            }
            if !scan.readKernelExtensions {
                Label("Kernel extensions couldn't be read", systemImage: "exclamationmark.triangle")
                    .help("Neither the kernel nor kmutil answered, so kernel extensions are unknown rather than absent.")
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// Shared by the context menu and the detail pane.
@MainActor
enum DriverActions {
    static let extensionsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    /// The installing app for a system extension, or the kext's bundle,
    /// when it's still on disk.
    static func revealablePath(_ item: ExtensionItem) -> String? {
        let path = item.systemExtension?.appPath ?? item.kernelExtension?.path
        return path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openSettings() {
        if let url = extensionsSettings { NSWorkspace.shared.open(url) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
