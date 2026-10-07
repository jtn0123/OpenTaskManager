import AppKit
import CoreGraphics
import OTMKit
import SwiftUI

/// What this Mac is: model, chip and memory up top, then a card each for the
/// processor, memory, graphics, displays, storage, network, battery, software
/// and security. Read once when the page opens (displays again when they
/// change), never per sample.
struct SystemInfoView: View {
    @Environment(AppModel.self) private var model
    @State private var info: SystemInfo?
    @State private var displays: [DisplayInfo] = []
    @State private var security: SecurityStatus?
    /// Serial number, hardware UUID and MAC addresses stay masked until asked for.
    @State private var showsIdentifiers = false
    @State private var copied = false

    var body: some View {
        Group {
            if let info {
                content(info)
            } else {
                ProgressView("Reading system information…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: copySummary) {
                    Label(copied ? "Copied" : "Copy Summary", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.titleAndIcon)
                .disabled(info == nil)
                .help(showsIdentifiers
                    ? "Copy this page as plain text, including the serial number, hardware UUID and MAC addresses"
                    : "Copy this page as plain text. The serial number, hardware UUID and MAC addresses stay out while hidden.")
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
                    FillGrid(minimum: 300) {
                        ForEach(SystemReport.sections(info, displays: displays, security: security, now: context.date)) { section in
                            InfoCard(section: section, showsIdentifiers: showsIdentifiers)
                        }
                    }
                }
            }
            .padding(20)
        }
        .defaultScrollAnchor(LaunchArgument.string("openScroll") == "bottom" ? .bottom : .top)
    }

    private func load() async {
        displays = DisplayReader.read()
        if info == nil {
            let topology = model.topology
            info = await Task.detached(priority: .userInitiated) { SystemInfoReader.read(topology: topology) }.value
        }
        if security == nil {
            security = await SecurityReader.read()
        }
    }

    private func copySummary() {
        guard let info else { return }
        let text = SystemReport.text(info, displays: displays, security: security, includeIdentifiers: showsIdentifiers)
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

/// One section as label/value rows. Headings (a display, a drive, a network
/// port) start a group and indent the rows under them.
private struct InfoCard: View {
    private static let mask = String(repeating: "•", count: 12)

    var section: InfoSection
    var showsIdentifiers: Bool

    var body: some View {
        let style = SystemStyle(section.kind)
        Card(tint: style.tint) {
            Label(section.title, systemImage: style.symbol)
                .font(.headline)
                .foregroundStyle(style.tint)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                    if row.isHeading {
                        heading(row, isFirst: index == 0)
                    } else {
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(.secondaryText)
                                .fixedSize()
                                .padding(.leading, section.rows[..<index].contains(where: \.isHeading) ? 10 : 0)
                            value(row)
                        }
                    }
                }
            }
            .font(.callout)
        }
    }

    private func heading(_ row: InfoRow, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.label).fontWeight(.semibold).lineLimit(1)
            if !row.value.isEmpty {
                Text(row.value).foregroundStyle(.secondaryText).lineLimit(1)
            }
        }
        .textSelection(.enabled)
        .padding(.top, isFirst ? 0 : 6)
    }

    @ViewBuilder
    private func value(_ row: InfoRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let status = row.status {
                StatusIcon(status: status)
            }
            if row.isSensitive && !showsIdentifiers {
                Text(Self.mask).foregroundStyle(.tertiaryText).accessibilityLabel("Hidden")
                    .help("Hidden. Use Show at the top of the page to reveal it.")
            } else if row.isCode {
                CopyableText(value: row.value)
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

    let tint: Color
    let symbol: String

    init(_ kind: InfoSection.Kind) {
        let style: (tint: Color, symbol: String) = switch kind {
        case .processor: (Theme.cpu, "cpu")
        case .memory: (Theme.memory, "memorychip")
        case .graphics: (Theme.gpu, "cube.transparent")
        case .displays: (Self.displays, "display")
        case .storage: (Theme.disk, "internaldrive")
        case .network: (Theme.network, "network")
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

// MARK: - Displays

/// Connected displays from AppKit and Core Graphics, the main one first.
@MainActor
enum DisplayReader {
    static func read() -> [DisplayInfo] {
        let displays = NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = screen.backingScaleFactor
            let points = screen.frame.size
            let modeRate = mode?.refreshRate ?? 0
            let rate = modeRate > 0 ? modeRate : screen.maximumFramesPerSecond > 0 ? Double(screen.maximumFramesPerSecond) : nil
            return DisplayInfo(
                id: id,
                name: screen.localizedName,
                pixelWidth: mode?.pixelWidth ?? Int(points.width * scale),
                pixelHeight: mode?.pixelHeight ?? Int(points.height * scale),
                pointWidth: mode?.width ?? Int(points.width),
                pointHeight: mode?.height ?? Int(points.height),
                scale: Double(scale),
                refreshRate: rate,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
        return displays.filter(\.isMain) + displays.filter { !$0.isMain }
    }
}
