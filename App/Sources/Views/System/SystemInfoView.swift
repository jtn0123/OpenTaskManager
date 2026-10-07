import AppKit
import OTMKit
import SwiftUI

/// What this Mac is: model, chip and memory up top, then a card each for the
/// processor, memory, graphics, displays, storage, controllers and readers,
/// network, its configuration and shares, the firewall, attached devices,
/// battery, software and security. Read once when the page opens and again
/// on Refresh (displays also when they change), never per sample; the
/// slower hardware report once a session (`HardwareInventoryStore`). A jump
/// bar over the cards goes to a group of them, and the toolbar's search
/// narrows them to what matches (`SystemReportSearch`), marking each find
/// (`SearchMarks`) and going to each match.
struct SystemInfoView: View {
    /// Below this page width the toolbar's buttons drop their titles, so an
    /// 820-point window keeps Save Report out of the overflow menu.
    private nonisolated static let titledButtonsWidth: CGFloat = 900

    @Environment(AppModel.self) private var model
    @AppStorage("page") private var page: Page = .overview
    @State private var info: SystemInfo?
    @State private var displays: [DisplayInfo] = []
    @State private var devices: PeripheralInventory?
    /// When `system_profiler` last ran, for a saved report.
    @State private var devicesReadAt: Date?
    @State private var readingDevices = false
    @State private var security: SecurityStatus?
    @State private var firewall: FirewallStatus?
    @State private var readingFirewall = false
    @State private var showsButtonTitles = true
    /// Serial number, hardware UUID and MAC addresses stay masked until asked for.
    @State private var showsIdentifiers = false
    @State private var copied = false
    @State private var saving = false
    @State private var query = ""
    @State private var navigator = SystemNavigator()
    @State private var openedRequest = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let info {
                content(info)
            } else {
                ProgressView("Reading system information…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.titledButtonsWidth } action: { showsButtonTitles = $0 }
        .searchable(text: $query, placement: .toolbar, prompt: "Label or value")
        .modifier(SearchFocus(isFocused: $searchFocused))
        .onSubmit(of: .search) { navigator.step(match: 1) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        // The card at the top stays put while the reads arrive.
                        navigator.holdPosition()
                        await refresh()
                        try? await Task.sleep(for: .milliseconds(500))
                        navigator.releasePosition()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(readingDevices || HardwareInventoryStore.shared.isReading)
                .help("Read this page again: free space, network settings and shares, the firewall, memory and controller "
                    + "details, and the attached USB, Thunderbolt, Bluetooth, audio and video devices")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: copySummary) {
                    Label(copied ? "Copied" : "Copy Summary", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(ToolbarLabelStyle(showsTitle: showsButtonTitles))
                .disabled(info == nil)
                .help(showsIdentifiers
                    ? "Copy this page as plain text, including the serial number, hardware UUID and MAC addresses"
                    : "Copy this page as plain text. The serial number, hardware UUID and MAC addresses stay out while hidden.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: saveReport) {
                    Label("Save Report…", systemImage: "square.and.arrow.down")
                }
                .labelStyle(ToolbarLabelStyle(showsTitle: showsButtonTitles))
                .disabled(info == nil || saving)
                .help("Save this page as a Markdown or JSON file. Identifiers stay out unless you include them.")
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayReader.read()
        }
    }

    private func content(_ info: SystemInfo) -> some View {
        // Only the uptime moves, so a minute is often enough.
        TimelineView(.everyMinute) { context in
            let sections = SystemReport.sections(info, displays: displays, devices: devices, security: security, firewall: firewall,
                                                 hardware: HardwareInventoryStore.shared.inventory, now: context.date)
            let search = SystemReportSearch(sections, query: query, overview: SystemReport.overview(info.hardware),
                                            includesIdentifiers: showsIdentifiers)
            let shown = search.isActive ? sections.filter { search.card($0.kind) != nil } : sections
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    SystemJumpBar(navigator: navigator, categories: SystemCategory.present(in: shown.map(\.kind)), search: search,
                                  query: $query) { searchFocused = true }
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !search.isActive || search.matches.contains(.overview) {
                                HeroCard(info: info, showsIdentifiers: $showsIdentifiers)
                                    .systemCardMark(.overview, navigator: navigator)
                                    .systemTarget(.overview, navigator: navigator)
                            }
                            if search.isActive, search.matches.isEmpty {
                                NoMatches(query: query)
                            }
                            cards(shown, info: info, search: search)
                        }
                        // Every find in the cards' titles, labels and values is marked.
                        .environment(\.searchTerms, search.terms)
                        .padding(20)
                        .background(SystemScrollTracker(navigator: navigator))
                        .coordinateSpace(.named(SystemNavigator.space))
                    }
                    .defaultScrollAnchor(LaunchArgument.string("openScroll") == "bottom" ? .bottom : .top)
                }
                .onAppear { navigator.proxy = proxy }
            }
        }
    }

    private func cards(_ sections: [InfoSection], info: SystemInfo, search: SystemReportSearch) -> some View {
        let links = networkLinks(info)
        let exposedSockets: () -> Void = { openExposedSockets() }
        // Columns that each run their own length, so a short card
        // (Displays, an empty Bluetooth) beside a long one (Storage,
        // a full USB list) leaves no hole, inside it or below it.
        // One column in a narrow window.
        return ColumnGrid(minimum: 340) {
            ForEach(sections) { section in
                let found = search.card(section.kind)
                InfoCard(section: section, shown: found?.rows, opens: found?.opens ?? [], showsIdentifiers: showsIdentifiers,
                         navigator: navigator, links: section.kind.isNetwork ? links : nil,
                         showExposedSockets: section.kind == .firewall ? exposedSockets : nil)
                    .systemTarget(.card(section.kind), navigator: navigator)
            }
        }
    }

    /// The ports Performance graphs (Wi-Fi, Ethernet and cellular with an
    /// address), and each port's last Internet quality test. The history
    /// changes only when a test finishes, not per tick.
    private func networkLinks(_ info: SystemInfo) -> NetworkLinks {
        let graphed: Set<NetworkInterfaceKind> = [.wifi, .ethernet, .cellular]
        var tests: [String: NetworkQualityResult] = [:]
        for result in NetworkQualityStore.shared.history where tests[result.historyKey] == nil {
            tests[result.historyKey] = result
        }
        return NetworkLinks(
            interfaces: Set(info.network.filter { $0.isUp && !$0.addresses.isEmpty && graphed.contains($0.kind) }.map(\.name)),
            lastTests: tests
        ) { interface in
            model.requestedNetworkInterface = interface
            page = .performance
        }
    }

    /// Opens the Connections page on the sockets other devices could try to
    /// reach, which the firewall's settings alone can't say.
    private func openExposedSockets() {
        model.requestedConnectionFilter = .exposed
        page = .connections
    }

    private func load() async {
        displays = DisplayReader.read()
        // The device report takes longest, so it starts first and runs alongside.
        async let deviceRead: Void = readDevices()
        async let firewallRead: Void = readFirewall()
        if info == nil {
            let topology = model.topology
            info = await Task.detached(priority: .userInitiated) { SystemInfoReader.read(topology: topology) }.value
        }
        if security == nil {
            security = await SecurityReader.read()
        }
        // Each port's last Internet quality test, loaded once a session.
        await NetworkQualityStore.shared.load()
        await firewallRead
        await deviceRead
        // The memory, controller and reader details, once a session, after
        // the devices so two system_profiler runs don't compete.
        await HardwareInventoryStore.shared.load()
        await openRequest()
    }

    /// `-openSystemSearch <text>` searches and `-openSystemCategory <group>`
    /// (hardware, network, devices…) jumps, once the page is read, for screenshots.
    private func openRequest() async {
        guard !openedRequest else { return }
        openedRequest = true
        if let text = LaunchArgument.string("openSystemSearch") { query = text }
        if let name = LaunchArgument.string("openSystemCategory"), let category = SystemCategory(rawValue: name.lowercased()) {
            // After the cards are laid out.
            try? await Task.sleep(for: .milliseconds(300))
            navigator.jump(to: category)
        }
    }

    /// Reads the hardware, network configuration, firewall and devices again.
    private func refresh() async {
        async let deviceRead: Void = readDevices()
        async let firewallRead: Void = readFirewall()
        let topology = model.topology
        info = await Task.detached(priority: .userInitiated) { SystemInfoReader.read(topology: topology) }.value
        displays = DisplayReader.read()
        await firewallRead
        await deviceRead
        await HardwareInventoryStore.shared.read()
    }

    /// The firewall's settings change rarely but can at any time, so they're
    /// read each time the page opens, unlike the hardware.
    private func readFirewall() async {
        guard !readingFirewall else { return }
        readingFirewall = true
        firewall = await FirewallReader.read()
        readingFirewall = false
    }

    /// Runs `system_profiler` on a background queue, so waiting for it doesn't
    /// hold up a Swift concurrency thread.
    private func readDevices() async {
        guard !readingDevices else { return }
        readingDevices = true
        devices = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: PeripheralReader.read())
            }
        }
        devicesReadAt = Date()
        readingDevices = false
    }

    /// Asks where, then saves the page. The hardware is read again so free
    /// space, addresses and up time are as of now; devices and security are
    /// the page's last reads, and the report says when the devices were read.
    private func saveReport() {
        guard let info else { return }
        saving = true
        Task {
            defer { saving = false }
            let day = Date.now.formatted(.iso8601.year().month().day())
            let name = "\(info.hardware.displayName) System Report \(day)".replacingOccurrences(of: "/", with: "-")
            guard let choice = await SystemReportSavePanel.choose(name: name) else { return }
            let topology = model.topology
            let fresh = await Task.detached(priority: .userInitiated) { SystemInfoReader.read(topology: topology) }.value
            self.info = fresh
            displays = DisplayReader.read()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let generator = "OpenTaskManager \(version)".trimmingCharacters(in: .whitespaces)
            let hardware = HardwareInventoryStore.shared
            let report = SystemReportDocument(info: fresh, displays: displays, devices: devices, devicesCollectedAt: devicesReadAt,
                                              security: security, firewall: firewall, hardware: hardware.inventory,
                                              hardwareCollectedAt: hardware.readAt, generator: generator)
            await SystemReportSavePanel.write(report, as: choice)
        }
    }

    private func copySummary() {
        guard let info else { return }
        let text = SystemReport.text(info, displays: displays, devices: devices, security: security, firewall: firewall,
                                     hardware: HardwareInventoryStore.shared.inventory, includeIdentifiers: showsIdentifiers)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

// MARK: - Header

/// The Mac's picture, name, chip, memory and macOS version, with its
/// serial number and hardware UUID behind a Show button.
private struct HeroCard: View {
    private static let mask = String(repeating: "•", count: 12)

    var info: SystemInfo
    @Binding var showsIdentifiers: Bool

    var body: some View {
        let hardware = info.hardware
        Card(tint: Theme.cpu, glow: 0.2) {
            HStack(alignment: .center, spacing: 22) {
                Image(systemName: SystemStyle.symbol(for: hardware.kind))
                    .font(.system(size: 68, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [Theme.cpu, Theme.memory], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 120, height: 96)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        MarkedText(hardware.displayName).font(.largeTitle.weight(.semibold))
                        MarkedText(([info.software.computerName, hardware.modelIdentifier].compactMap { $0 }).joined(separator: " · "))
                            .font(.title3)
                            .foregroundStyle(.secondaryText)
                    }
                    .textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { chips(info) }
                        VStack(alignment: .leading, spacing: 6) { chips(info) }
                    }
                    identifiers(hardware)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func chips(_ info: SystemInfo) -> some View {
        Chip(symbol: "cpu", text: info.hardware.chip, color: Theme.cpu)
        Chip(symbol: "memorychip", text: SystemFacts.memorySize(info.hardware.physicalMemory) + " memory", color: Theme.memory)
        Chip(symbol: "macwindow", text: info.software.macOSDescription, color: Theme.gpu)
    }

    /// On one line while it fits; otherwise a line each, rather than
    /// labels cut down to "Serial num…".
    private func identifiers(_ hardware: MacHardware) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                identifierRows(hardware)
                showButton
            }
            VStack(alignment: .leading, spacing: 4) {
                identifierRows(hardware)
                showButton
            }
        }
        .font(.callout)
    }

    private func identifierRows(_ hardware: MacHardware) -> some View {
        ForEach(SystemReport.identifiers(hardware), id: \.label) { row in
            HStack(spacing: 5) {
                MarkedText(row.label).foregroundStyle(.secondaryText)
                if showsIdentifiers {
                    CopyableText(value: row.value)
                } else {
                    Text(Self.mask).foregroundStyle(.tertiaryText).accessibilityLabel("Hidden")
                }
            }
            .lineLimit(1)
        }
    }

    private var showButton: some View {
        Button {
            showsIdentifiers.toggle()
        } label: {
            Label(showsIdentifiers ? "Hide" : "Show", systemImage: showsIdentifiers ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .help(showsIdentifiers
            ? "Hide the serial number, hardware UUID and MAC addresses"
            : "Show the serial number, hardware UUID and MAC addresses, and include them when copying")
    }
}

private struct Chip: View {
    var symbol: String
    var text: String
    var color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.75))
            .textSelection(.enabled)
    }
}

// MARK: - Cards

/// What a network port's heading links to: its traffic on the Performance
/// page, where that page graphs it, and its last Internet quality test.
private struct NetworkLinks {
    var interfaces: Set<String>
    var lastTests: [String: NetworkQualityResult]
    var showTraffic: (String) -> Void

    /// "Last Internet test, 3 Oct: 412 Mbps down, 48 Mbps up, good responsiveness".
    static func summary(_ result: NetworkQualityResult) -> String {
        let rates = [(result.downloadBitsPerSecond, "down"), (result.uploadBitsPerSecond, "up")].compactMap { rate, direction in
            rate.map { Format.bitsPerSecond($0 / 8) + " " + direction }
        }
        let rating = result.rating.map { ["\($0.title.lowercased()) responsiveness"] } ?? []
        return "Last Internet test, \(result.date.formatted(date: .abbreviated, time: .omitted)): "
            + (rates + rating).joined(separator: ", ")
    }
}

/// One section as label/value rows. Headings (a display, a drive, a network
/// port) start a group and indent the rows under them. On an attached-device
/// card each device is one compact row instead, opening onto its details.
/// During a search it shows only the rows found (`shown`, by index among the
/// section's rows), with the devices whose facts matched opened, the words
/// found marked wherever they are (`MarkedText`) and the match gone to
/// outlined.
private struct InfoCard: View {
    var section: InfoSection
    /// nil shows every row.
    var shown: [Int]?
    /// Device headings a search opens.
    var opens: Set<Int> = []
    var showsIdentifiers: Bool
    /// Outlines the row a search goes to.
    let navigator: SystemNavigator
    /// On the Network card: each port's link to its traffic.
    var links: NetworkLinks?
    /// On the Firewall card: opens the Connections page's exposed sockets.
    var showExposedSockets: (() -> Void)?
    /// Devices opened to show their details, by place in the card and name.
    @State private var opened: Set<String> = []
    /// Those a search opened, closed again when the search moves on.
    @State private var searchOpened: Set<String> = []

    var body: some View {
        let style = SystemStyle(section.kind)
        Card(tint: style.tint) {
            Label {
                MarkedText(section.title)
            } icon: {
                Image(systemName: style.symbol)
            }
            .font(.headline)
            .foregroundStyle(style.tint)
            Group {
                if section.hasDetails {
                    deviceList
                } else {
                    rowGrid
                }
            }
            .font(.callout)
            .markedRowBackground(flashing: navigator.mark != nil)
            // A card cut down by a search leaves out what explains the whole.
            if let note = section.note, shown == nil || shown?.count == section.rows.count {
                Text(note)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let showExposedSockets {
                Button("Show exposed sockets", action: showExposedSockets)
                    .buttonStyle(.link)
                    .font(.explanation)
                    .help("Open the Connections page on the sockets listening on addresses other devices could try to reach")
            }
        }
        .systemCardMark(.card(section.kind), navigator: navigator)
        .onChange(of: opens, initial: true) {
            // Close what an earlier search opened and this one doesn't, and
            // open this one's, leaving devices opened by hand alone.
            let keys = Set(opens.map(key))
            opened.subtract(searchOpened.subtracting(keys))
            let added = keys.subtracting(opened)
            opened.formUnion(added)
            searchOpened = searchOpened.intersection(keys).union(added)
        }
    }

    /// The row of this card the search has gone to.
    private var current: Int? {
        if case let .row(kind, index) = navigator.match, kind == section.kind { index } else { nil }
    }

    private var rowGrid: some View {
        let indices = shown ?? Array(section.rows.indices)
        let firstHeading = section.rows.firstIndex(where: \.isHeading)
        let current = current
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(indices, id: \.self) { index in
                let row = section.rows[index]
                if row.isHeading {
                    heading(row, isFirst: index == indices.first)
                        .id(SystemTarget.row(section.kind, index))
                        .markedRow(current == index)
                } else {
                    InfoGridRow(row: row, showsIdentifiers: showsIdentifiers, indent: firstHeading.map { $0 < index } == true ? 10 : 0,
                                target: .row(section.kind, index), isCurrent: current == index)
                }
            }
        }
    }

    private func heading(_ row: InfoRow, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    MarkedText(row.label).fontWeight(.semibold).lineLimit(1)
                    if !row.value.isEmpty {
                        MarkedText(row.value).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                    if let state = row.state {
                        MarkedText(state)
                            .font(.explanation.weight(.medium))
                            .foregroundStyle(SystemStyle(section.kind).tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(SystemStyle(section.kind).tint.opacity(0.45), lineWidth: 0.75))
                    }
                }
                .textSelection(.enabled)
                if let links, let interface = row.interface, links.interfaces.contains(interface) {
                    Spacer(minLength: 8)
                    Button("Show traffic") { links.showTraffic(interface) }
                        .buttonStyle(.link)
                        .font(.explanation)
                        .help("Open \(interface)'s traffic graph on the Performance page")
                }
            }
            if let interface = row.interface, let result = links?.lastTests[interface] {
                Text(NetworkLinks.summary(result))
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, isFirst ? 0 : 6)
    }

    private var deviceList: some View {
        let blocks = section.blockIndices(showing: shown)
        let keys = blocks.compactMap { block in
            if case let .device(heading, details) = block, !details.isEmpty { key(heading) } else { nil }
        }
        let current = current
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .rows(run):
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(run, id: \.self) { index in
                            InfoGridRow(row: section.rows[index], showsIdentifiers: showsIdentifiers, target: .row(section.kind, index),
                                        isCurrent: current == index)
                        }
                    }
                case let .device(heading, details):
                    let key = key(heading)
                    DeviceRow(section: section, heading: heading, details: details, showsIdentifiers: showsIdentifiers,
                              isOpen: opened.contains(key), current: current) { all in
                        let opening = !opened.contains(key)
                        if all {
                            opened = opening ? Set(keys) : []
                        } else if opening {
                            opened.insert(key)
                        } else {
                            opened.remove(key)
                        }
                    }
                }
            }
        }
    }

    /// A device by its heading's place in the whole card and its name, so it
    /// keeps its state while a search shows part of the card.
    private func key(_ heading: Int) -> String {
        "\(heading) \(section.rows[heading].label)"
    }
}

/// A label and its value, as a row of the card's grid.
private struct InfoGridRow: View {
    var row: InfoRow
    var showsIdentifiers: Bool
    var indent: CGFloat = 0
    /// Where the page scrolls to reach it.
    var target: SystemTarget
    /// The match a search has gone to.
    var isCurrent = false

    var body: some View {
        GridRow {
            MarkedText(row.label)
                .foregroundStyle(.secondaryText)
                .fixedSize()
                .padding(.leading, indent)
                .id(target)
                .markedRow(isCurrent)
            InfoValue(row: row, showsIdentifiers: showsIdentifiers)
                .markedRow(isCurrent)
        }
    }
}

private struct InfoValue: View {
    private static let mask = String(repeating: "•", count: 12)

    var row: InfoRow
    var showsIdentifiers: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let status = row.status {
                StatusIcon(status: status)
            }
            if row.isSensitive && !showsIdentifiers {
                Text(Self.mask).foregroundStyle(.tertiaryText).accessibilityLabel("Hidden")
                    .help("Hidden. Use Show at the top of the page to reveal it.")
            } else if row.isCode {
                // An IPv6 address breaks between its groups, so its prefix never sits alone on a line,
                // and a driver or bundle ID after its dots, never hyphenated mid-word.
                CopyableText(value: row.value,
                             forms: row.isAddress ? AddressBreaks.forms(row.value) : AddressBreaks.dottedForms(row.value))
            } else {
                MarkedText(row.value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Lets the value column take the rest of the card, so values only wrap when they must.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An attached device as one line: its name, how it's connected, and the
/// status worth seeing at a glance. Clicking it opens the rest of its facts
/// (maker, bus, power, identifiers); Option-click opens or closes them all.
/// Devices plugged into a hub sit indented under it.
private struct DeviceRow: View {
    var section: InfoSection
    /// The device's heading and its facts, by index among the section's rows.
    var heading: Int
    var details: [Int]
    var showsIdentifiers: Bool
    var isOpen: Bool
    /// The card's row a search has gone to, if it's this device or one of its facts.
    var current: Int?
    /// Called with true when Option is held.
    var toggle: (_ all: Bool) -> Void
    @Environment(\.searchTerms) private var searchTerms

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if details.isEmpty {
                    summary
                } else {
                    Button {
                        toggle(NSEvent.modifierFlags.contains(.option))
                    } label: {
                        summary.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isOpen ? "Hide the details" : "Show the details. Option-click shows every device's.")
                    .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                }
            }
            .id(SystemTarget.row(section.kind, heading))
            .markedRow(current == heading)
            if isOpen, !details.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(details, id: \.self) { index in
                        InfoGridRow(row: section.rows[index], showsIdentifiers: showsIdentifiers, target: .row(section.kind, index),
                                    isCurrent: current == index)
                    }
                }
                .padding(.leading, 15)
                .padding(.bottom, 4)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
    }

    private var row: InfoRow {
        section.rows[heading]
    }

    /// On one line while it fits, otherwise the status under the name.
    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondaryText)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 10)
                .opacity(details.isEmpty ? 0 : 1)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name.lineLimit(1)
                    Spacer(minLength: 0)
                    state
                }
                VStack(alignment: .leading, spacing: 1) {
                    name
                    state
                }
            }
        }
    }

    private var name: Text {
        let isCurrent = current == heading
        let note = row.value.isEmpty ? Text("")
            : (Text("  ") + SearchMarks.text(row.value, terms: searchTerms, current: isCurrent)).foregroundStyle(.secondaryText)
        return SearchMarks.text(row.label, terms: searchTerms, current: isCurrent).fontWeight(.medium) + note
    }

    @ViewBuilder
    private var state: some View {
        if let state = row.state {
            MarkedText(state).foregroundStyle(.secondaryText).lineLimit(1)
        }
    }
}

/// Lets ⌘F put the cursor in the toolbar's search field, where macOS has the
/// API for it (15 and later).
private struct SearchFocus: ViewModifier {
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.searchFocused(isFocused)
        } else {
            content
        }
    }
}

/// In place of the cards when a search finds nothing.
private struct NoMatches: View {
    var query: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            Text("Nothing on this page matches \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Search looks for every word in the cards' labels and values, the headings over them and their titles. "
                + "Hidden identifiers match by their labels alone.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// A toolbar button's title and icon in a wide page, its icon alone in a
/// narrow one (the title stays as its accessibility label).
private struct ToolbarLabelStyle: LabelStyle {
    var showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            TitleAndIconLabelStyle().makeBody(configuration: configuration)
        } else {
            IconOnlyLabelStyle().makeBody(configuration: configuration)
        }
    }
}

private struct StatusIcon: View {
    private static let good = Theme.data(.systemGreen)
    private static let warning = Theme.data(.systemOrange)

    var status: InfoRow.Status

    var body: some View {
        switch status {
        case .good:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Self.good)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Self.warning)
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondaryText)
        }
    }
}

/// Each card's colour and symbol.
private struct SystemStyle {
    // Data colours like the rest, so headings deepen in light mode.
    private static let displays = Theme.data(0.36, 0.62, 0.98)
    private static let battery = Theme.data(0.30, 0.80, 0.40)
    private static let software = Theme.data(0.52, 0.50, 0.96)
    private static let security = Theme.data(0.24, 0.74, 0.56)
    private static let usb = Theme.data(0.40, 0.56, 0.92)
    private static let thunderbolt = Theme.data(0.96, 0.66, 0.20)
    private static let bluetooth = Theme.data(0.20, 0.58, 0.98)
    private static let audio = Theme.data(0.90, 0.40, 0.62)
    private static let controllers = Theme.data(0.30, 0.66, 0.78)

    let tint: Color
    let symbol: String

    init(_ kind: InfoSection.Kind) {
        let style: (tint: Color, symbol: String) = switch kind {
        case .processor: (Theme.cpu, "cpu")
        case .memory: (Theme.memory, "memorychip")
        case .graphics: (Theme.gpu, "cube.transparent")
        case .displays: (Self.displays, "display")
        case .storage: (Theme.disk, "internaldrive")
        case .controllers: (Self.controllers, "sdcard")
        case .network: (Theme.network, "network")
        case .networkConfiguration: (Theme.network, "point.3.connected.trianglepath.dotted")
        case .networkVolumes: (Theme.network, "externaldrive.connected.to.line.below")
        case .firewall: (Self.security, "network.badge.shield.half.filled")
        case .usb: (Self.usb, "cable.connector")
        case .thunderbolt: (Self.thunderbolt, "bolt.horizontal")
        case .bluetooth: (Self.bluetooth, "antenna.radiowaves.left.and.right")
        case .audio: (Self.audio, "hifispeaker")
        case .battery: (Self.battery, "battery.75percent")
        case .software: (Self.software, "gearshape")
        case .security: (Self.security, "lock.shield")
        }
        tint = style.tint
        symbol = style.symbol
    }

    /// A picture of this kind of Mac, falling back to a generic desktop on
    /// systems whose symbol set lacks it.
    @MainActor
    static func symbol(for kind: MacKind) -> String {
        let preferred = switch kind {
        case .laptop: "laptopcomputer"
        case .mini: "macmini"
        case .studio: "macstudio"
        case .iMac: "desktopcomputer"
        case .pro: "macpro.gen3"
        case .virtual: "macwindow.on.rectangle"
        case .desktop: "desktopcomputer"
        }
        return NSImage(systemSymbolName: preferred, accessibilityDescription: nil) == nil ? "desktopcomputer" : preferred
    }
}
