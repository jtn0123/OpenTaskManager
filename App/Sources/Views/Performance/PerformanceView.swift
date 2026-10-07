import OTMKit
import SwiftUI

enum Resource: Hashable {
    case cpu, memory, power, sensors
    case gpu(String)
    case disk(String)
    case network(String)
}

struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Resource = .cpu
    @State private var opened = false
    /// The page's width, which sets the resource list's.
    @State private var width: CGFloat = 0

    /// The narrowest the detail gets beside the resource list. Below it, as
    /// in the narrowest window, the list gives way to a picker over the
    /// detail, so the detail takes the page's full width.
    private static let minimumDetailWidth: CGFloat = 560

    var body: some View {
        if let snapshot = model.snapshot {
            let resources = resources(snapshot)
            // An HStack, not an `HSplitView`: the split view's minimum widths
            // pushed the page past both edges of the narrowest window. The
            // detail keeps its place in either layout, so switching between
            // them keeps its scroll position.
            HStack(spacing: 0) {
                if !compact {
                    ResourceRail(resources: resources, snapshot: snapshot, selection: $selected, compactRows: listWidth < 220)
                        .frame(width: listWidth)
                    Divider()
                }
                VStack(spacing: 0) {
                    if compact {
                        ResourcePicker(resources: resources, snapshot: snapshot, selection: $selected)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        Divider()
                    }
                    ScrollView {
                        detail(for: selected, snapshot: snapshot)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(LaunchArgument.string("openScroll") == "bottom" ? .bottom : .top)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onAppear { openRequestedResource(snapshot) }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A quarter of the page, within 184 to 250 points.
    private var listWidth: CGFloat {
        width > 0 ? min(max((width / 4).rounded(), 184), 250) : 230
    }

    /// Whether the detail would be too narrow beside the list. The page's
    /// width doesn't depend on the choice, so it can't flip back and forth.
    private var compact: Bool {
        width > 0 && width - listWidth - 1 < Self.minimumDetailWidth
    }

    /// `--args -openResource memory` (cpu, memory, gpu, disk, network, power, sensors)
    /// picks the first matching resource once, for screenshots. With
    /// `-openScroll bottom` the detail starts scrolled to the end.
    private func openRequestedResource(_ snapshot: SystemSnapshot) {
        guard !opened, let name = LaunchArgument.string("openResource") else { return }
        opened = true
        let match = resources(snapshot).first { resource in
            switch resource {
            case .cpu: name == "cpu"
            case .memory: name == "memory"
            case .power: name == "power"
            case .sensors: name == "sensors"
            case .gpu: name == "gpu"
            case .disk: name == "disk"
            case .network: name == "network"
            }
        }
        if let match { selected = match }
    }

    private func resources(_ snapshot: SystemSnapshot) -> [Resource] {
        var list: [Resource] = [.cpu, .memory]
        list += snapshot.gpus.map { .gpu($0.id) }
        list += snapshot.disks.map { .disk($0.id) }
        list += snapshot.network.filter(\.isPrimary).map { .network($0.id) }
        if snapshot.power.systemWatts != nil || snapshot.power.battery != nil { list.append(.power) }
        // Always listed: thermal pressure comes from macOS on every Mac, and
        // the page says so where there are no sensors.
        list.append(.sensors)
        return list
    }

    @ViewBuilder
    private func detail(for resource: Resource, snapshot: SystemSnapshot) -> some View {
        switch resource {
        case .cpu: CPUDetail(snapshot: snapshot)
        case .memory: MemoryDetail(snapshot: snapshot)
        case .power: PowerDetail(snapshot: snapshot)
        case .sensors: SensorsDetail(sensors: model.sensors, snapshot: snapshot)
        case let .gpu(id):
            if let gpu = snapshot.gpus.first(where: { $0.id == id }) { GPUDetail(gpu: gpu, snapshot: snapshot) }
        case let .disk(id):
            if let disk = snapshot.disks.first(where: { $0.id == id }) { DiskDetail(disk: disk, snapshot: snapshot) }
        case let .network(id):
            if let link = snapshot.network.first(where: { $0.id == id }) { NetworkDetail(link: link, snapshot: snapshot) }
        }
    }
}

// MARK: - Resource list

/// The resource list beside the detail. Its own selection, not a `List`'s:
/// the selected row takes a narrow accent marker, a light accent fill and a
/// bold name, so it reads clearly on the plain rail and stays a step under
/// the main sidebar's solid selection. Clicking a row picks it and gives the
/// rail the keyboard, where the up and down arrows move through it.
private struct ResourceRail: View {
    var resources: [Resource]
    var snapshot: SystemSnapshot
    @Binding var selection: Resource
    /// In a narrow list the sparkline gives the text more room.
    var compactRows: Bool
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(resources, id: \.self) { resource in
                    ResourceRow(resource: resource, snapshot: snapshot, compact: compactRows, selected: resource == selection) {
                        selection = resource
                        focused = true
                    }
                }
            }
            .padding(8)
        }
        .background(Color.primary.opacity(0.025))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand(perform: move)
    }

    private func move(_ direction: MoveCommandDirection) {
        guard let index = resources.firstIndex(of: selection) else { return }
        switch direction {
        case .up where index > 0: selection = resources[index - 1]
        case .down where index < resources.count - 1: selection = resources[index + 1]
        default: break
        }
    }
}

private struct ResourceRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    var resource: Resource
    var snapshot: SystemSnapshot
    /// In a narrow list the sparkline gives the text more room.
    var compact = false
    var selected = false
    var select: () -> Void
    @State private var hovering = false

    var body: some View {
        let text = ResourceText(resource, snapshot: snapshot, sensors: model.sensors)
        HStack(spacing: 10) {
            sparkline
                .frame(width: compact ? 48 : 64, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).font(.headline.weight(selected ? .bold : .medium))
                Text(text.subtitle).font(.subheadline).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .background { highlight }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }

    /// The selection: an accent fill, stronger in dark mode where a light
    /// tint washes out, with a marker down its leading edge.
    @ViewBuilder private var highlight: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        if selected {
            shape
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 9)
                        .padding(.leading, 3)
                }
        } else if hovering {
            shape.fill(Color.primary.opacity(0.05))
        }
    }

    @ViewBuilder private var sparkline: some View {
        switch resource {
        case .cpu: Sparkline(values: model.cpuHistory.values, color: Theme.cpu, maxValue: 1)
        case .memory: Sparkline(values: model.memoryHistory.values, color: Theme.memory, maxValue: 1)
        case .power: Sparkline(values: model.powerHistory.values, color: Theme.power)
        case .sensors: Sparkline(values: model.sensorHistory.hottest[.chip]?.values ?? [], color: Theme.thermal)
        case let .gpu(id): Sparkline(values: model.gpuHistory[id]?.values ?? [], color: Theme.gpu, maxValue: 1)
        case let .disk(id):
            Sparkline(values: zipSum(model.diskReadHistory[id]?.values, model.diskWriteHistory[id]?.values), color: Theme.disk)
        case let .network(id):
            Sparkline(values: zipSum(model.networkInHistory[id]?.values, model.networkOutHistory[id]?.values), color: Theme.network)
        }
    }

    private func zipSum(_ a: [Double]?, _ b: [Double]?) -> [Double] {
        guard let a, let b else { return a ?? b ?? [] }
        return zip(a, b).map(+)
    }
}

// MARK: - Picker for narrow windows

/// The resources as chips over the detail, in place of the list when the
/// page is too narrow for both: each with its colour, name and current
/// figure, in as few rows as fit, filled edge to edge like a segmented
/// control. The selected chip takes the accent and a bold name; one click
/// switches.
private struct ResourcePicker: View {
    @Environment(AppModel.self) private var model
    var resources: [Resource]
    var snapshot: SystemSnapshot
    @Binding var selection: Resource

    var body: some View {
        ChipRows(spacing: 6, lineSpacing: 6) {
            ForEach(resources, id: \.self) { resource in
                ResourceChip(text: ResourceText(resource, snapshot: snapshot, sensors: model.sensors),
                             color: resource.color, selected: resource == selection) {
                    selection = resource
                }
            }
        }
    }
}

private struct ResourceChip: View {
    @Environment(\.colorScheme) private var colorScheme
    var text: ResourceText
    var color: Color
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        let dark = colorScheme == .dark
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text.title).fontWeight(selected ? .bold : .medium)
                Text(text.figure).foregroundStyle(.secondaryText).monospacedDigit()
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(selected ? Color.accentColor.opacity(dark ? 0.26 : 0.13) : Color.primary.opacity(hovering ? 0.08 : 0.04),
                        in: shape)
            .overlay(shape.strokeBorder(selected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.10),
                                        lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(text.subtitle.replacingOccurrences(of: "\n", with: " · "))
        .accessibilityLabel("\(text.title), \(text.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Chips in as few rows as fit, spread evenly over them (`GridMath.flowRows`),
/// each row filled edge to edge with the room left shared between its chips.
private struct ChipRows: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
        let heights = rows(sizes, width: width).map { row in sizes[row].map(\.height).max() ?? 0 }
        return CGSize(width: width, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in rows(sizes, width: bounds.width) {
            let widths = GridMath.spread(sizes[row].map { Double($0.width) }, across: Double(bounds.width), spacing: Double(spacing))
            let height = sizes[row].map(\.height).max() ?? 0
            var x = bounds.minX
            for (index, width) in zip(row, widths) {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: CGFloat(width), height: height))
                x += CGFloat(width) + spacing
            }
            y += height + lineSpacing
        }
    }

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [Range<Int>] {
        GridMath.flowRows(widths: sizes.map { Double($0.width) }, width: Double(width), spacing: Double(spacing))
    }
}

// MARK: - Text

/// What the list and the picker say about a resource.
private struct ResourceText {
    var title: String
    /// The list's lines under the title.
    var subtitle: String
    /// The picker's one short figure.
    var figure: String

    init(_ resource: Resource, snapshot: SystemSnapshot, sensors: SensorSample?) {
        switch resource {
        case .cpu:
            title = "CPU"
            subtitle = Format.percent(snapshot.cpu.usage)
            figure = subtitle
        case .memory:
            let memory = snapshot.memory
            title = "Memory"
            subtitle = "\(Self.unbroken(Format.bytes(memory.used))) / \(Self.unbroken(Format.bytes(memory.physical))) "
                + "(\(Format.percent(memory.usedFraction)))"
            figure = Format.percent(memory.usedFraction)
        case .power:
            let watts = snapshot.power.systemWatts.map(Format.watts)
            let battery = snapshot.power.battery.map { "\($0.percent)%" }
            title = "Power"
            subtitle = (watts ?? "—") + (battery.map { " · \($0)" } ?? "")
            figure = watts ?? battery ?? "—"
        case .sensors:
            let chip = sensors?.hottest(.chip).map(Format.celsius)
            let fans = sensors?.fans.map { $0.isStopped ? "off" : Format.rpm($0.rpm) } ?? []
            let pressure = snapshot.power.thermalState
            title = "Thermals"
            subtitle = [chip, fans.isEmpty ? nil : "Fans " + fans.joined(separator: ", ")].compactMap { $0 }.joined(separator: "\n")
            // With no sensors (a VM), macOS's thermal pressure is all there is.
            if subtitle.isEmpty { subtitle = "Pressure \(pressure.rawValue)" }
            figure = chip ?? fans.first ?? pressure.title
        case let .gpu(id):
            let gpu = snapshot.gpus.first { $0.id == id }
            let usage = gpu?.deviceUtilization.map { Format.percent($0) }
            title = "GPU"
            subtitle = gpu.map { "\($0.name)\n\(usage ?? Unavailable.gpuUtilization)" } ?? ""
            figure = usage ?? "—"
        case let .disk(id):
            let disk = snapshot.disks.first { $0.id == id }
            title = "Disk \(id.replacingOccurrences(of: "disk", with: ""))"
            subtitle = disk.map { "\($0.model ?? ($0.isSolidState == true ? "SSD" : "Disk"))\n\(Format.percent($0.activeFraction)) active" } ?? ""
            figure = disk.map { "\(Format.percent($0.activeFraction)) active" } ?? "—"
        case let .network(id):
            let link = snapshot.network.first { $0.id == id }
            title = link?.displayName ?? id
            subtitle = link.map {
                Self.unbroken("↓ \(Format.bitsPerSecond($0.receivedBytesPerSecond))") + "  "
                    + Self.unbroken("↑ \(Format.bitsPerSecond($0.sentBytesPerSecond))")
            } ?? ""
            figure = subtitle
        }
    }

    /// Keeps a figure with its unit or arrow when a narrow row wraps.
    private static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

private extension Resource {
    /// The resource's data colour, as its graphs draw it.
    var color: Color {
        switch self {
        case .cpu: Theme.cpu
        case .memory: Theme.memory
        case .power: Theme.power
        case .sensors: Theme.thermal
        case .gpu: Theme.gpu
        case .disk: Theme.disk
        case .network: Theme.network
        }
    }
}
