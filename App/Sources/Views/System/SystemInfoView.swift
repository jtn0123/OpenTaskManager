import AppKit
import OTMKit
import SwiftUI

/// What this Mac is: model, chip and memory up top, then a card each for the
/// processor, memory, graphics, displays, storage, controllers and readers,
/// network, its configuration and shares, the firewall, attached devices,
/// battery, software and security. Read once when the page opens and again
/// on Refresh (displays also when they change), never per sample; the
/// slower hardware report once a session (`HardwareInventoryStore`).
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

    var body: some View {
        Group {
            if let info {
                content(info)
            } else {
                ProgressView("Reading system information…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.titledButtonsWidth } action: { showsButtonTitles = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeroCard(info: info, showsIdentifiers: $showsIdentifiers)
                // Only the uptime moves, so a minute is often enough.
                TimelineView(.everyMinute) { context in
                    let sections = SystemReport.sections(info, displays: displays, devices: devices, security: security, firewall: firewall,
                                                         hardware: HardwareInventoryStore.shared.inventory, now: context.date)
                    let links = networkLinks(info)
                    let exposedSockets: () -> Void = { openExposedSockets() }
                    // Columns that each run their own length, so a short card
                    // (Displays, an empty Bluetooth) beside a long one (Storage,
                    // a full USB list) leaves no hole, inside it or below it.
                    // One column in a narrow window.
                    ColumnGrid(minimum: 340) {
                        ForEach(sections) { section in
                            InfoCard(section: section, showsIdentifiers: showsIdentifiers, links: section.kind.isNetwork ? links : nil,
                                     showExposedSockets: section.kind == .firewall ? exposedSockets : nil)
                        }
                    }
                }
            }
            .padding(20)
        }
        .defaultScrollAnchor(LaunchArgument.string("openScroll") == "bottom" ? .bottom : .top)
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
                        Text(hardware.displayName).font(.largeTitle.weight(.semibold))
                        Text(([info.software.computerName, hardware.modelIdentifier].compactMap { $0 }).joined(separator: " · "))
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
                Text(row.label).foregroundStyle(.secondaryText)
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
private struct InfoCard: View {
    var section: InfoSection
    var showsIdentifiers: Bool
    /// On the Network card: each port's link to its traffic.
    var links: NetworkLinks?
    /// On the Firewall card: opens the Connections page's exposed sockets.
    var showExposedSockets: (() -> Void)?
    /// Devices opened to show their details, by position and name.
    @State private var opened: Set<String> = []

    var body: some View {
        let style = SystemStyle(section.kind)
        Card(tint: style.tint) {
            Label(section.title, systemImage: style.symbol)
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
            if let note = section.note {
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
    }

    private var rowGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                if row.isHeading {
                    heading(row, isFirst: index == 0)
                } else {
                    InfoGridRow(row: row, showsIdentifiers: showsIdentifiers,
                                indent: section.rows[..<index].contains(where: \.isHeading) ? 10 : 0)
                }
            }
        }
    }

    private func heading(_ row: InfoRow, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    Text(row.label).fontWeight(.semibold).lineLimit(1)
                    if !row.value.isEmpty {
                        Text(row.value).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                    if let state = row.state {
                        Text(state)
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
        let blocks = Array(section.blocks.enumerated())
        let keys = blocks.compactMap { index, block in
            if case let .device(heading, details) = block, !details.isEmpty { Self.key(index, heading) } else { nil }
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks, id: \.offset) { index, block in
                switch block {
                case let .rows(rows):
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            InfoGridRow(row: row, showsIdentifiers: showsIdentifiers)
                        }
                    }
                case let .device(heading, details):
                    let key = Self.key(index, heading)
                    DeviceRow(heading: heading, details: details, showsIdentifiers: showsIdentifiers, isOpen: opened.contains(key)) { all in
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

    private static func key(_ index: Int, _ heading: InfoRow) -> String {
        "\(index) \(heading.label)"
    }
}

/// A label and its value, as a row of the card's grid.
private struct InfoGridRow: View {
    var row: InfoRow
    var showsIdentifiers: Bool
    var indent: CGFloat = 0

    var body: some View {
        GridRow {
            Text(row.label)
                .foregroundStyle(.secondaryText)
                .fixedSize()
                .padding(.leading, indent)
            InfoValue(row: row, showsIdentifiers: showsIdentifiers)
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
                Text(row.value)
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
    var heading: InfoRow
    var details: [InfoRow]
    var showsIdentifiers: Bool
    var isOpen: Bool
    /// Called with true when Option is held.
    var toggle: (_ all: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                if isOpen {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, row in
                            InfoGridRow(row: row, showsIdentifiers: showsIdentifiers)
                        }
                    }
                    .padding(.leading, 15)
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.leading, CGFloat(heading.depth) * 14)
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
        let note = heading.value.isEmpty ? Text("") : Text("  " + heading.value).foregroundStyle(.secondaryText)
        return Text(heading.label).fontWeight(.medium) + note
    }

    @ViewBuilder
    private var state: some View {
        if let state = heading.state {
            Text(state).foregroundStyle(.secondaryText).lineLimit(1)
        }
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
