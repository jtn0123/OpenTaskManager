import OTMKit
import SwiftUI

enum Resource: Hashable {
    case cpu, memory, power, sensors
    /// The workspace over the CPU, GPU, disk and Internet tests, last in the list.
    case benchmarks
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
    /// Whether the disk images under their heading in the list are shown.
    @AppStorage("performanceShowsDiskImages") private var showsDiskImages = false
    @AppStorage(GraphFit.key) private var fitsGraphs = GraphFit.standard
    /// The detail pane's visible height, which each device's main graph fills (`Hero`).
    @State private var paneHeight: CGFloat = 0

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
                    ResourceRail(resources: resources, snapshot: snapshot, selection: $selected, showsImages: $showsDiskImages,
                                 compactRows: listWidth < 220)
                        .frame(width: listWidth)
                    Divider()
                }
                VStack(spacing: 0) {
                    if compact {
                        ResourcePicker(resources: resources, snapshot: snapshot, selection: $selected, showsImages: $showsDiskImages)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        Divider()
                    }
                    ScrollView {
                        // Every graph on the page covers this one window. Both
                        // values change a handful of times as it fills, not per tick.
                        let collected = model.cpuHistory.count
                        let canFit = GraphCoverage.canFit(samples: collected, span: AppModel.graphSpan)
                        detail(for: selected, snapshot: snapshot)
                            .environment(\.graphWindow, GraphFit.window(samples: collected, fits: fitsGraphs && canFit))
                            .environment(\.offersGraphFit, canFit)
                            .environment(\.detailPaneHeight, paneHeight)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
                    .defaultScrollAnchor(LaunchArgument.string("openScroll") == "bottom" ? .bottom : .top)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onAppear { openRequestedResource(snapshot) }
            .task { await BenchmarkWorkspace.shared.loadSummary() }
            // A card's Compare in Benchmarks; the workspace scrolls to the comparison itself.
            .onChange(of: BenchmarkWorkspace.shared.openRequest) { selected = .benchmarks }
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

    /// Opens the interface another page asked for ("Show traffic" on the
    /// System page). Otherwise `--args -openResource memory` (cpu, memory,
    /// gpu, disk, network, power, sensors, benchmarks) picks the first matching resource
    /// once, for screenshots. With `-openScroll bottom` the detail starts
    /// scrolled to the end.
    private func openRequestedResource(_ snapshot: SystemSnapshot) {
        if let interface = model.requestedNetworkInterface {
            model.requestedNetworkInterface = nil
            if resources(snapshot).contains(.network(interface)) { selected = .network(interface) }
            return
        }
        guard !opened, let name = LaunchArgument.string("openResource") else { return }
        opened = true
        let match = resources(snapshot).first { resource in
            switch resource {
            case .cpu: name == "cpu"
            case .memory: name == "memory"
            case .power: name == "power"
            case .sensors: name == "sensors"
            case .benchmarks: name == "benchmarks"
            case .gpu: name == "gpu"
            case .disk: name == "disk"
            case .network: name == "network"
            }
        }
        if let match { selected = match }
    }

    /// The drives, then the disk images, which the list shows under a
    /// heading of their own.
    private func resources(_ snapshot: SystemSnapshot) -> [Resource] {
        var list: [Resource] = [.cpu, .memory]
        list += snapshot.gpus.map { .gpu($0.id) }
        list += snapshot.disks.filter { !$0.isDiskImage }.map { .disk($0.id) }
        list += snapshot.disks.filter(\.isDiskImage).map { .disk($0.id) }
        list += snapshot.network.filter(\.isPrimary).map { .network($0.id) }
        if snapshot.power.systemWatts != nil || snapshot.power.battery != nil { list.append(.power) }
        // Always listed: thermal pressure comes from macOS on every Mac, and
        // the page says so where there are no sensors.
        list.append(.sensors)
        list.append(.benchmarks)
        return list
    }

    @ViewBuilder
    private func detail(for resource: Resource, snapshot: SystemSnapshot) -> some View {
        switch resource {
        case .cpu: CPUDetail(snapshot: snapshot, select: { selected = $0 })
        case .memory: MemoryDetail(snapshot: snapshot)
        case .power: PowerDetail(snapshot: snapshot)
        case .sensors: SensorsDetail(sensors: model.sensors, snapshot: snapshot)
        case .benchmarks:
            let root = snapshot.volumes.first(where: \.isRoot)
            let link = snapshot.network.first(where: \.isPrimary)
            BenchmarksDetail(homeVolume: root?.name ?? "the startup volume", homeDisk: root?.physicalDisk, interface: link?.name,
                             interfaceName: link?.displayName)
                .equatable()
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
/// rail the keyboard, where the up and down arrows move through the rows it
/// shows. Disk images follow the drives under a heading that shows or hides
/// them, so a mounted installer doesn't line up with the startup disk.
private struct ResourceRail: View {
    var resources: [Resource]
    var snapshot: SystemSnapshot
    @Binding var selection: Resource
    @Binding var showsImages: Bool
    /// In a narrow list the sparkline gives the text more room.
    var compactRows: Bool
    @FocusState private var focused: Bool

    var body: some View {
        let images = resources.filter { $0.isDiskImage(in: snapshot) }
        ScrollView {
            VStack(spacing: 2) {
                ForEach(resources, id: \.self) { resource in
                    if resource == images.first {
                        DiskImagesHeading(count: images.count, shown: $showsImages,
                                          holdsSelection: !showsImages && images.contains(selection))
                    }
                    if showsImages || !images.contains(resource) {
                        ResourceRow(resource: resource, snapshot: snapshot, compact: compactRows, selected: resource == selection) {
                            selection = resource
                            focused = true
                        }
                        // Set a little apart: saved test results, not a live resource.
                        .padding(.top, resource == .benchmarks ? 10 : 0)
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

    /// Moves to the next row shown either way, past hidden disk images.
    private func move(_ direction: MoveCommandDirection) {
        guard let index = resources.firstIndex(of: selection) else { return }
        let shown = { (resource: Resource) in showsImages || !resource.isDiskImage(in: snapshot) }
        switch direction {
        case .up: if let previous = resources[..<index].last(where: shown) { selection = previous }
        case .down: if let next = resources[(index + 1)...].first(where: shown) { selection = next }
        default: break
        }
    }
}

/// The heading the disk images are listed under, with how many there are.
/// Clicking it shows or hides them; while they're hidden, it takes the
/// selection's marker when one of them is selected.
private struct DiskImagesHeading: View {
    var count: Int
    @Binding var shown: Bool
    var holdsSelection: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: shown ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .frame(width: 12)
            Text("Disk images").font(.callout.weight(holdsSelection ? .bold : .semibold))
            Spacer(minLength: 4)
            Text(count, format: .number).font(.callout).monospacedDigit()
        }
        .foregroundStyle(.secondaryText)
        .padding(.vertical, 6)
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .background { RailHighlight(selected: holdsSelection, hovering: hovering) }
        .padding(.top, 4)
        .contentShape(Rectangle())
        .onTapGesture { shown.toggle() }
        .onHover { hovering = $0 }
        .help(shown ? "Hide the disk images" : "Show the disk images")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk images, \(count)")
        .accessibilityValue(shown ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { shown.toggle() }
    }
}

/// The selection behind a rail row: an accent fill, stronger in dark mode
/// where a light tint washes out, with a marker down its leading edge.
private struct RailHighlight: View {
    @Environment(\.colorScheme) private var colorScheme
    var selected: Bool
    var hovering: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        if selected {
            shape
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.12))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(colorScheme == .dark ? 0.7 : 0.55), lineWidth: 1.25))
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
}

private struct ResourceRow: View {
    @Environment(AppModel.self) private var model
    var resource: Resource
    var snapshot: SystemSnapshot
    /// In a narrow list the sparkline gives the text more room.
    var compact = false
    var selected = false
    var select: () -> Void
    @State private var hovering = false

    var body: some View {
        let text = ResourceText(resource, snapshot: snapshot, sensors: model.sensors, topology: model.topology)
        HStack(spacing: 10) {
            sparkline
                .frame(width: compact ? 56 : 76, height: 48)
            VStack(alignment: .leading, spacing: 1) {
                // A volume's or an image's name can be long, often one unbroken
                // word ("UC_SIRI_…_Cryptex"): cut in the middle, whole in the tooltip.
                Text(text.title).font(.headline.weight(selected ? .bold : .semibold)).lineLimit(1).truncationMode(.middle)
                if !text.figure.isEmpty {
                    Text(text.figure).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
                }
                if !text.detail.isEmpty {
                    Text(text.detail).font(.metadata).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(2)
                }
                if let unreported = text.unreported {
                    Label(unreported, systemImage: Unavailable.symbol)
                        .font(.metadata)
                        .foregroundStyle(.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .background { RailHighlight(selected: selected, hovering: hovering) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(text.help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }

    @ViewBuilder private var sparkline: some View {
        switch resource {
        case .cpu: RailGraph(values: model.cpuHistory.values, color: Theme.cpu, maxValue: 1)
        case .memory: RailGraph(values: model.memoryHistory.values, color: Theme.memory, maxValue: 1)
        case .power: RailGraph(values: model.powerHistory.values, color: Theme.power)
        case .sensors:
            // With no temperatures (a VM), the thermal pressure the page graphs.
            if let chip = model.sensorHistory.hottest[.chip] {
                RailGraph(values: chip.values, color: Theme.thermal)
            } else {
                RailGraph(values: model.thermalPressureHistory.values, color: Theme.thermal, maxValue: 1)
            }
        case .benchmarks:
            // Nothing to graph: a still glyph in the sparkline's frame.
            Self.glyph("stopwatch", tint: Theme.other)
        case let .gpu(id):
            if let gpu = snapshot.gpus.first(where: { $0.id == id }), gpu.deviceUtilization == nil {
                // No load to draw, and never an empty plot that would pass for
                // one not recorded yet: the memory in use the subtitle gives.
                if gpu.memoryInUse != nil {
                    RailGraph(values: model.gpuDetail[id]?.memoryInUse.values ?? [], color: Theme.gpu)
                } else {
                    Self.glyph(Unavailable.symbol, tint: Theme.gpu)
                }
            } else {
                RailGraph(values: model.gpuHistory[id]?.values ?? [], color: Theme.gpu, maxValue: 1)
            }
        case let .disk(id):
            RailGraph(values: zipSum(model.diskReadHistory[id]?.values, model.diskWriteHistory[id]?.values), color: Theme.disk)
        case let .network(id):
            RailGraph(values: zipSum(model.networkInHistory[id]?.values, model.networkOutHistory[id]?.values), color: Theme.network)
        }
    }

    /// A still glyph in the sparkline's frame, for a row with nothing to graph.
    private static func glyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .plotFrame(tint: tint, wash: (0.16, 0.03), border: 0.6, lineWidth: 1, cornerRadius: 5)
    }

    private func zipSum(_ a: [Double]?, _ b: [Double]?) -> [Double] {
        guard let a, let b else { return a ?? b ?? [] }
        return zip(a, b).map(+)
    }
}

/// A rail row's live graph of its last minute: the device's colour over a
/// fine grid, framed in it, as the detail's main graph is.
private struct RailGraph: View {
    var values: [Double]
    var color: Color
    var maxValue: Double?

    var body: some View {
        GraphView(series: [GraphSeries(values: values, color: color)], maxValue: maxValue, capacity: 60, showsGrid: false,
                  lineWidth: 1.4, glows: true, cornerRadius: 5)
            .background(FineGrid(inset: 4, rows: 4).clipShape(RoundedRectangle(cornerRadius: 5)))
            .plotFrame(tint: color, wash: (0.18, 0.04), border: 0.6, lineWidth: 1, cornerRadius: 5)
    }
}

// MARK: - Picker for narrow windows

/// The resources as chips over the detail, in place of the list when the
/// page is too narrow for both: each with its colour, name and current
/// figure, in as few rows as fit, filled edge to edge like a segmented
/// control. The selected chip takes the accent and a bold name; one click
/// switches. Disk images follow the drives behind a chip that shows or
/// hides them, as under the list's heading.
private struct ResourcePicker: View {
    @Environment(AppModel.self) private var model
    var resources: [Resource]
    var snapshot: SystemSnapshot
    @Binding var selection: Resource
    @Binding var showsImages: Bool

    var body: some View {
        let images = resources.filter { $0.isDiskImage(in: snapshot) }
        ChipRows(spacing: 6, lineSpacing: 6) {
            ForEach(resources, id: \.self) { resource in
                if resource == images.first {
                    DiskImagesChip(count: images.count, shown: $showsImages,
                                   holdsSelection: !showsImages && images.contains(selection))
                }
                if showsImages || !images.contains(resource) {
                    ResourceChip(text: ResourceText(resource, snapshot: snapshot, sensors: model.sensors, topology: model.topology),
                                 color: resource.color, selected: resource == selection) {
                        selection = resource
                    }
                }
            }
        }
    }
}

private struct ResourceChip: View {
    var text: ResourceText
    var color: Color
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                // A long volume or image name is cut in the middle when the row is short of room, the whole of it in the tooltip.
                Text(text.title).fontWeight(selected ? .bold : .medium).truncationMode(.middle)
                Text(text.chip).foregroundStyle(.secondaryText).monospacedDigit()
            }
            .modifier(ChipLook(selected: selected, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(text.help ?? [text.figure, text.detail].filter { !$0.isEmpty }.joined(separator: " · "))
        .accessibilityLabel([text.title, text.figure, text.detail, text.unreported].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chip that shows or hides the disk images' chips, with how many
/// there are. While they're hidden, it looks selected when one of them is.
private struct DiskImagesChip: View {
    var count: Int
    @Binding var shown: Bool
    var holdsSelection: Bool
    @State private var hovering = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: shown ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                Text("Disk images").fontWeight(holdsSelection ? .bold : .medium)
                Text(count, format: .number).foregroundStyle(.secondaryText).monospacedDigit()
            }
            .modifier(ChipLook(selected: holdsSelection, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shown ? "Hide the disk images" : "Show the disk images")
        .accessibilityLabel("Disk images, \(count)")
        .accessibilityValue(shown ? "Shown" : "Hidden")
    }
}

/// A chip's text, size, fill and border: the accent when selected.
private struct ChipLook: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var selected: Bool
    var hovering: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        let dark = colorScheme == .dark
        content
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
    /// The list's first line under the title: the reading its graph draws.
    var figure: String
    /// The list's second line: what goes with it.
    var detail = ""
    /// The picker's one short figure.
    var chip: String
    /// A disk's names in full, as a tooltip: nothing in it changes per tick.
    var help: String?
    /// A reading this Mac doesn't give, which the list says under the
    /// figures beside `Unavailable.symbol`: "Utilization not reported".
    var unreported: String?

    @MainActor
    init(_ resource: Resource, snapshot: SystemSnapshot, sensors: SensorSample?, topology: CPUTopology) {
        switch resource {
        case .cpu:
            title = "CPU"
            chip = Format.percent(snapshot.cpu.usage)
            figure = "\(chip) busy"
            let load = snapshot.cpu.loadAverage.first.map { " · load \(Format.fixed($0, 2))" } ?? ""
            detail = "\(topology.logicalCores) CPUs" + load
        case .memory:
            let memory = snapshot.memory
            title = "Memory"
            chip = Format.percent(memory.usedFraction)
            figure = "\(Self.unbroken(Format.bytes(memory.used))) · \(chip)"
            detail = "Pressure \(memory.pressure.rawValue)"
        case .power:
            let watts = snapshot.power.systemWatts.map(Format.watts)
            let battery = snapshot.power.battery.map { "Battery \($0.percent)%" }
            title = "Power"
            figure = watts ?? battery ?? "—"
            detail = watts == nil ? "" : battery ?? (snapshot.power.adapter == nil ? "" : "AC power")
            chip = watts ?? battery ?? "—"
        case .sensors:
            let chipTemperature = sensors?.hottest(.chip).map(Format.celsius)
            let fans = sensors?.fans.map { $0.isStopped ? "off" : Format.rpm($0.rpm) } ?? []
            let pressure = snapshot.power.thermalState
            title = "Thermals"
            // With no sensors (a VM), macOS's thermal pressure is all there is.
            figure = chipTemperature.map { "\($0) chip" } ?? "Pressure \(pressure.rawValue)"
            detail = fans.isEmpty ? (chipTemperature == nil ? "No sensors" : "Pressure \(pressure.rawValue)")
                : "Fans " + fans.joined(separator: ", ")
            chip = chipTemperature ?? fans.first ?? pressure.title
        case .benchmarks:
            let age = BenchmarkWorkspace.shared.newest.map { Format.ago(Date().timeIntervalSince($0)) }
            title = "Benchmarks"
            figure = age.map { "Newest \($0)" } ?? "No runs yet"
            chip = age ?? "No runs yet"
            help = "The CPU, GPU, disk and Internet tests' saved runs, to compare and run together"
        case let .gpu(id):
            let gpu = snapshot.gpus.first { $0.id == id }
            title = "GPU"
            if let busy = gpu?.deviceUtilization {
                chip = Format.percent(busy)
                figure = "\(chip) busy"
                detail = gpu?.tellingName ?? gpu?.memoryInUse.map { "\(Self.unbroken(Format.bytes($0))) memory" } ?? ""
            } else {
                // Its memory in use, which the list's sparkline draws, in
                // place of the load it doesn't report.
                let memory = gpu?.memoryInUse.map { Self.unbroken(Format.bytes($0)) }
                chip = memory ?? "—"
                figure = memory.map { "\($0) memory" } ?? "—"
                detail = gpu?.tellingName ?? ""
                unreported = gpu == nil ? nil : Unavailable.gpuUtilization
                help = gpu.map { _ in
                    memory == nil ? Unavailable.gpuUtilizationDetail
                        : "This GPU's driver doesn't report how busy it is, so its memory in use is shown instead."
                }
            }
        case let .disk(id):
            let disk = snapshot.disks.first { $0.id == id }
            title = disk.map(DiskText.title) ?? id
            chip = disk.map { "\(Format.percent($0.activeFraction)) active" } ?? "—"
            figure = chip
            // Its transfer rate over which disk it is, each on a line of its own.
            detail = disk.map {
                Self.unbroken(Format.bytesPerSecond($0.readBytesPerSecond + $0.writeBytesPerSecond)) + "\n" + DiskText.identity($0)
            } ?? ""
            help = disk.map(DiskText.help)
        case let .network(id):
            let link = snapshot.network.first { $0.id == id }
            title = link?.displayName ?? id
            figure = link.map { Self.unbroken("↓ \(Format.bitsPerSecond($0.receivedBytesPerSecond))") } ?? ""
            detail = link.map { Self.unbroken("↑ \(Format.bitsPerSecond($0.sentBytesPerSecond))") } ?? ""
            chip = [figure, detail].joined(separator: "  ")
        }
    }

    /// Keeps a figure with its unit or arrow when a narrow row wraps.
    private static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

private extension Resource {
    /// A disk attached from an image file, which the list puts under its own heading.
    func isDiskImage(in snapshot: SystemSnapshot) -> Bool {
        guard case let .disk(id) = self else { return false }
        return snapshot.disks.first { $0.id == id }?.isDiskImage == true
    }

    /// The resource's data colour, as its graphs draw it.
    var color: Color {
        switch self {
        case .cpu: Theme.cpu
        case .memory: Theme.memory
        case .power: Theme.power
        case .sensors: Theme.thermal
        case .benchmarks: Theme.other
        case .gpu: Theme.gpu
        case .disk: Theme.disk
        case .network: Theme.network
        }
    }
}
