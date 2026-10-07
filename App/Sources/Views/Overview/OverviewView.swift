import OTMKit
import SwiftUI

/// At-a-glance dashboard: a gauge per resource, a live map of every core,
/// throughput, and which apps are using what.
///
/// In a narrow window (820 points, with or without the sidebar) the gauges
/// shrink, the top-app lists come straight after them, Disk and Network take
/// a short row each, and the core map folds to a line that opens on a click,
/// so the lists are on screen without scrolling.
struct OverviewView: View {
    /// Below this width of the page, the narrow layout.
    private static let narrowWidth: CGFloat = 900

    @Environment(AppModel.self) private var model
    @State private var isNarrow = false

    var body: some View {
        let narrowWidth = Self.narrowWidth
        Group {
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        gauges(snapshot)
                        // A GPU that doesn't say how busy it is (a virtual
                        // machine's) would only fill a gauge with an empty ring,
                        // so it takes a line and the cards below move up.
                        if let gpu = snapshot.gpus.first, gpu.deviceUtilization == nil { gpuStrip(gpu) }
                        if isNarrow {
                            topApps
                            throughput(snapshot)
                            CoreMap(snapshot: snapshot, folds: true)
                        } else {
                            CoreMap(snapshot: snapshot)
                            throughput(snapshot)
                            topApps
                        }
                        StorageCard(volumes: snapshot.volumes)
                    }
                    .padding(20)
                }
                .defaultScrollAnchor(Self.startsAtEnd ? .bottom : .top)
                .followsEnd(Self.startsAtEnd)
                // Keeps nettop running whether Top Network is a card or a strip,
                // so switching between them doesn't drop a reading.
                .task { await model.networkActivity.track(model: model) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Only crossing the breakpoint changes anything, not every resize.
        // Read while the first sample is taken, so the cards start in their
        // layout rather than swapping over (which lost -openScroll bottom).
        .onGeometryChange(for: Bool.self) { $0.size.width < narrowWidth } action: { isNarrow = $0 }
    }

    /// `-openScroll bottom` starts the page scrolled to the end, for screenshots.
    private static let startsAtEnd = LaunchArgument.string("openScroll") == "bottom"

    // MARK: Sections

    private func gauges(_ snapshot: SystemSnapshot) -> some View {
        FillGrid(minimum: isNarrow ? 200 : 210) {
            cpuGauge(snapshot)
            memoryGauge(snapshot)
            if let gpu = snapshot.gpus.first, let busy = gpu.deviceUtilization { gpuGauge(gpu, busy: busy) }
            if let watts = snapshot.power.systemWatts { powerGauge(watts, snapshot.power) }
        }
    }

    /// Disk and Network, and where the power goes when this Mac says. Narrow,
    /// Disk and Network are a short row each, rates beside a small graph.
    private func throughput(_ snapshot: SystemSnapshot) -> some View {
        FillGrid(minimum: isNarrow ? 260 : 280) {
            diskCard(snapshot)
            NetworkTrafficCard(compact: isNarrow)
            if let components = snapshot.power.components { powerCard(components) }
        }
    }

    /// Which apps use the most CPU, memory, energy and network.
    @ViewBuilder private var topApps: some View {
        let groups = model.appGroups
        // Unknown until the first samples say; until then the card stays.
        let measuresEnergy = model.measuresProcessEnergy != false
        let networkRanks = TopNetworkCard.hasRanking(model.networkActivity)
        FillGrid(minimum: isNarrow ? 260 : 280) {
            TopAppsCard(title: "CPU", symbol: "cpu", color: Theme.cpu, groups: groups,
                        metric: \.cpuPercent, format: { model.cpuScale.format($0.cpuPercent) })
            TopAppsCard(title: "Memory", symbol: "memorychip", color: Theme.memory, groups: groups,
                        metric: { Double($0.memory) }, format: { Format.bytes($0.memory) })
            if measuresEnergy {
                TopAppsCard(title: "Energy", symbol: "bolt.fill", color: Theme.power, groups: groups,
                            metric: \.powerWatts, format: { Format.watts($0.powerWatts) }, minimum: 0.01)
            }
            if networkRanks { TopNetworkCard() }
        }
        // A whole card would only say there's nothing to rank, so
        // each takes a line and the cards above share its width. Two share
        // a row only where neither explanation is cut short.
        if !measuresEnergy || !networkRanks {
            FillGrid(minimum: 420, spacing: 12) {
                if !measuresEnergy {
                    NoticeStrip(title: "Top Energy", symbol: "bolt.fill", color: Theme.power, text: Unavailable.energy)
                }
                if !networkRanks { TopNetworkStrip() }
            }
        }
    }

    // MARK: Gauges

    private func cpuGauge(_ snapshot: SystemSnapshot) -> some View {
        let topology = model.topology
        return GaugeCard(
            title: "CPU", value: snapshot.cpu.usage * 100, format: { Format.fixed($0, 0) }, unit: "%",
            fraction: snapshot.cpu.usage, color: Theme.cpu,
            details: ["\(topology.logicalCores) cores", "Load \(Format.fixed(snapshot.cpu.loadAverage.first ?? 0, 2))"],
            history: model.cpuHistory.values, historyMax: 1, compact: isNarrow
        )
    }

    private func memoryGauge(_ snapshot: SystemSnapshot) -> some View {
        let memory = snapshot.memory
        let color: Color = switch memory.pressure {
        case .normal: Theme.memory
        case .warning: .orange
        case .critical: .red
        }
        return GaugeCard(
            title: "Memory", value: memory.usedFraction * 100, format: { Format.fixed($0, 0) }, unit: "%",
            fraction: memory.usedFraction, color: color,
            details: ["\(Format.bytes(memory.used)) of \(Format.bytes(memory.physical))", "\(memory.pressure.rawValue.capitalized) pressure"],
            history: model.memoryHistory.values, historyMax: 1, compact: isNarrow
        )
    }

    private func gpuGauge(_ gpu: GPUSample, busy: Double) -> some View {
        GaugeCard(
            title: "GPU", value: busy * 100, format: { Format.fixed($0, 0) }, unit: "%",
            fraction: busy, color: Theme.gpu,
            details: [gpu.name] + (gpu.coreCount.map { ["\($0) cores"] } ?? []),
            history: model.gpuHistory[gpu.id]?.values ?? [], historyMax: 1, compact: isNarrow
        )
    }

    /// The GPU's name and memory in use on one line, for a GPU that doesn't
    /// report utilization. Performance › GPU keeps its memory graph and GPU
    /// time by app.
    private func gpuStrip(_ gpu: GPUSample) -> some View {
        // A paravirtual GPU's name is just "GPU", which the title already says.
        let name = gpu.name.caseInsensitiveCompare("GPU") == .orderedSame ? nil : gpu.name
        let memory = gpu.memoryInUse.map { (label: "Memory in use", value: Format.bytes($0)) }
        return NoticeStrip(title: "GPU", symbol: "cpu.fill", color: Theme.gpu,
                           text: [name, Unavailable.gpuUtilization].compactMap { $0 }.joined(separator: " · "),
                           help: Unavailable.gpuUtilizationDetail + " Performance › GPU shows its memory in use and GPU time by app.",
                           trailing: memory)
    }

    private func powerGauge(_ watts: Double, _ power: PowerSample) -> some View {
        let history = model.powerHistory.values
        // Scale to the most this Mac has ever drawn, so the ring reads as
        // "how hard is it working" whether it's an Air or a Studio.
        let ceiling = max(model.peakSystemWatts, 20)
        let source = power.battery.map { "Battery \($0.percent)%" + ($0.isPluggedIn ? ", plugged in" : "") } ?? "AC power"
        return GaugeCard(
            title: "Power", value: watts, format: { Format.fixed($0, $0 < 10 ? 1 : 0) }, unit: "W",
            fraction: watts / ceiling, color: Theme.power,
            details: [source, "Thermal \(power.thermalState.rawValue)" + (model.sensors?.hottest(.chip).map { " · \(Format.celsius($0))" } ?? "")],
            history: history, historyMax: nil, compact: isNarrow
        )
    }

    // MARK: Throughput

    private func diskCard(_ snapshot: SystemSnapshot) -> some View {
        let ids = snapshot.disks.map(\.id)
        return ThroughputCard(
            title: "Disk", symbol: "internaldrive", color: Theme.disk, secondaryColor: Theme.diskSecondary,
            labels: ("Read", "Write"),
            rates: (snapshot.disks.reduce(0) { $0 + $1.readBytesPerSecond }, snapshot.disks.reduce(0) { $0 + $1.writeBytesPerSecond }),
            histories: (AppModel.tailSum(ids.map { model.diskReadHistory[$0]?.values ?? [] }),
                        AppModel.tailSum(ids.map { model.diskWriteHistory[$0]?.values ?? [] })),
            format: Format.bytesPerSecond, minimumScale: 1_048_576, units: .binaryBytes, compact: isNarrow
        )
    }

    /// Where the power goes, stacked by part of the Mac.
    private func powerCard(_ components: PowerComponents) -> some View {
        let history = model.powerDetail
        let cpu = Stat(label: "CPU", number: components.cpu, color: Theme.cpu, format: Format.watts)
        let gpu = Stat(label: "GPU", number: components.gpu, color: Theme.gpu, format: Format.watts)
        // Parts this Mac doesn't measure would only add flat lines over the band below.
        let bands: [GraphSeries?] = [
            components.isMeasured(.cpu) ? GraphSeries(values: history.cpu.values, color: Theme.cpu) : nil,
            components.isMeasured(.gpu) ? GraphSeries(values: history.gpu.values, color: Theme.gpu) : nil,
            components.isMeasured(.ane) ? GraphSeries(values: history.ane.values, color: Theme.neuralEngine) : nil,
            components.isMeasured(.dram) ? GraphSeries(values: history.dram.values, color: Theme.dram) : nil,
        ]
        let series = bands.compactMap { $0 } + [GraphSeries(values: history.rest.values, color: Theme.restOfSystem)]
        return Card(tint: Theme.power) {
            Label("Power", systemImage: "bolt.fill").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    cpu
                    gpu
                    Stat(label: "Rest", number: history.rest.values.last ?? 0, color: Theme.restOfSystem, format: Format.watts)
                }
                HStack(spacing: 18) { cpu; gpu }
            }
            GraphView(series: series, capacity: 120, showsGrid: false, glows: true, stacked: true, minimumCeiling: 5, axis: Format.watts)
                .frame(height: 72)
        }
    }
}

// MARK: - Pieces

private struct GaugeCard: View {
    private static let valueFont = NSFont.numeric(size: 26, weight: .semibold, rounded: true)
    private static let compactValueFont = NSFont.numeric(size: 19, weight: .semibold, rounded: true)

    var title: String
    var value: Double
    var format: (Double) -> String
    var unit: String
    var fraction: Double
    var color: Color
    /// One fact per line, each truncated rather than wrapped.
    var details: [String]
    var history: [Double]
    var historyMax: Double?
    /// A smaller ring and no graph, for a narrow window: the reading and its
    /// facts in a card two thirds the height.
    var compact = false

    var body: some View {
        let size: CGFloat = compact ? 66 : 96
        Card(tint: color, glow: fraction) {
            HStack(spacing: compact ? 12 : 14) {
                ZStack {
                    RingGauge(fraction: fraction, color: color, lineWidth: compact ? 8 : 10)
                    VStack(spacing: -2) {
                        AnimatedNumber(value: value, format: format, font: compact ? Self.compactValueFont : Self.valueFont,
                                       alignment: .center)
                        Text(unit).font(.metadata.weight(.medium)).foregroundStyle(.secondaryText)
                    }
                }
                .frame(width: size, height: size)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.title3.weight(.semibold))
                        ForEach(details.indices, id: \.self) { index in
                            Text(details[index])
                                .font(.explanation)
                                .foregroundStyle(.secondaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if !compact {
                        Spacer(minLength: 4)
                        GraphView(series: [GraphSeries(values: history, color: color)], maxValue: historyMax,
                                  capacity: 60, showsGrid: false, lineWidth: 1.4, glows: true)
                            .frame(height: 30)
                    }
                }
            }
            .frame(height: size)
        }
    }
}

/// A one-line note where a card or graph would be, so saying there's
/// nothing to show doesn't take its room: a reading this Mac can't make,
/// or a ranking with nothing in it right now. A dashed edge marks something
/// missing rather than a reading; a quiet ranking keeps a plain one.
struct NoticeStrip: View {
    var title: String
    var symbol: String
    var color: Color
    var text: String
    /// The hover text; by default, that the reading isn't available.
    var help: String?
    var isMissing = true
    /// Metadata-sized, for a row among an inspector's graphs.
    var compact = false
    /// A reading that is measured, at the end of the line: "Memory in use 301 MB".
    var trailing: (label: String, value: String)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10)
        HStack(spacing: compact ? 6 : 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).fontWeight(.medium).fixedSize()
            Text(text).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing.label).foregroundStyle(.secondaryText).lineLimit(1).fixedSize()
                Text(trailing.value).fontWeight(.medium).monospacedDigit().lineLimit(1).fixedSize()
            }
        }
        .font(compact ? .metadata : .callout)
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 6 : 8)
        .background(color.fillShade.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: isMissing ? [4, 3] : [])))
        .help(help ?? "\(title) isn't available. \(text)")
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// For `-openScroll bottom`: the cards fill in and swap over the first
    /// samples, which left the page partway down, so it follows the end as
    /// the page grows until someone scrolls. Without the flag, nothing is attached.
    @ViewBuilder func followsEnd(_ follows: Bool) -> some View {
        if #available(macOS 15, *), follows {
            modifier(FollowsEnd())
        } else {
            self
        }
    }
}

@available(macOS 15, *)
private struct FollowsEnd: ViewModifier {
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { _, _ in
                if isFollowing { position.scrollTo(edge: .bottom) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { isFollowing = false }
            }
    }
}

/// Top Network as a strip while there's nothing to rank: still measuring,
/// nettop unavailable, or no app moving data lately. The card comes back
/// as soon as an app sends or receives anything, and keeps its rows through
/// a pause (`TopNetworkCard.holdReadings`), so it never shows empty.
private struct TopNetworkStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.networkActivity
        let cadence = "Read with nettop every \(Format.timeSpan(NetworkActivityStore.refreshSeconds)) while this page is open."
        if store.isUnavailable {
            NoticeStrip(title: "Top Network", symbol: "network", color: Theme.network, text: Unavailable.processNetwork)
        } else if !store.hasMeasured {
            NoticeStrip(title: "Top Network", symbol: "network", color: Theme.network, text: "Measuring which apps use the network…",
                        help: cadence, isMissing: false)
        } else {
            let hold = TopNetworkCard.holdReadings
            let span = Format.roughDuration(Double(min(store.apps.length, hold)) * NetworkActivityStore.refreshSeconds)
            NoticeStrip(title: "Top Network", symbol: "network", color: Theme.network, text: "Nothing sent or received in the last \(span)",
                        help: "\(cadence) The ranking comes back when an app sends or receives something.", isMissing: false)
        }
    }
}

/// Every logical CPU as a tile that fills with load, one row per core type.
private struct CoreMap: View {
    @Environment(AppModel.self) private var model
    var snapshot: SystemSnapshot
    /// Folded to its heading and each core type's load until opened, for a
    /// narrow window; opening it is remembered.
    var folds = false
    @AppStorage("overviewShowsCores") private var showsCores = false

    var body: some View {
        let topology = model.topology
        let isOpen = !folds || showsCores
        Card {
            if folds {
                Button {
                    showsCores.toggle()
                } label: {
                    heading(topology, isOpen: isOpen).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Hide the map of cores" : "Show each core's load and the graph by core type")
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            } else {
                heading(topology, isOpen: true)
            }
            if isOpen {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(topology.tiers, id: \.level) { tier in
                            tierRow(tier, topology: topology)
                        }
                    }
                    .layoutPriority(1)
                    tierGraph(topology)
                        .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Cores" and the chip; folded, each core type's load instead.
    private func heading(_ topology: CPUTopology, isOpen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if folds {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondaryText)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
            Text("Cores").font(.headline)
            Spacer(minLength: 8)
            if isOpen {
                Text("\(topology.brand) · load by core type").font(.explanation).foregroundStyle(.secondaryText).lineLimit(1)
            } else {
                HStack(spacing: 12) {
                    ForEach(topology.tiers, id: \.level) { tier in
                        HStack(spacing: 5) {
                            Circle().fill(Theme.tier(tier.level)).frame(width: 8, height: 8)
                            Text("\(tier.name) \(Format.percent(Self.average(load(tier, topology: topology).usages)))")
                        }
                    }
                }
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
            }
        }
    }

    /// A core type's logical CPUs and their loads.
    private func load(_ tier: CPUTopology.Tier, topology: CPUTopology) -> (cpus: [Int], usages: [Double]) {
        let cpus = topology.tierForCPU.indices.filter { topology.tierForCPU[$0] == tier.level }
        return (cpus, cpus.map { snapshot.cpu.coreUsage.indices.contains($0) ? snapshot.cpu.coreUsage[$0] : 0 })
    }

    private static func average(_ usages: [Double]) -> Double {
        usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
    }

    private func tierGraph(_ topology: CPUTopology) -> some View {
        let series = topology.tiers.map { tier in
            GraphSeries(values: model.tierHistory(level: tier.level), color: Theme.tier(tier.level), fill: tier.level == 0)
        }
        return GraphView(series: series, maxValue: 1, capacity: 120, glows: true, axis: { Format.percent($0) }, cornerRadius: 8)
            .plotFrame(tint: Theme.cpu, wash: (0.05, 0.05), border: 0.18)
    }

    private func tierRow(_ tier: CPUTopology.Tier, topology: CPUTopology) -> some View {
        let (cpus, usages) = load(tier, topology: topology)
        let average = Self.average(usages)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(Theme.tier(tier.level)).frame(width: 8, height: 8)
                    Text(tier.name).font(.callout.weight(.medium))
                }
                Text("\(cpus.count) cores · \(Format.percent(average))")
                    .font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
            }
            .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: CoreTileRow.spacing) {
                ForEach(Array(stride(from: 0, to: cpus.count, by: 12)), id: \.self) { start in
                    let end = min(start + 12, cpus.count)
                    CoreTileRow(cpus: Array(cpus[start..<end]), usages: Array(usages[start..<end]), color: Theme.tier(tier.level))
                        .frame(width: CoreTileRow.width(for: end - start), height: CoreTileRow.tileSize.height)
                }
            }
        }
    }
}

/// Receive and send rates across the primary network interfaces, with their
/// history. Reads the model itself, so on pages that otherwise refresh
/// slowly (Connections) only this card redraws every tick.
struct NetworkTrafficCard: View {
    @Environment(AppModel.self) private var model
    var title = "Network"
    var compact = false

    var body: some View {
        let links = model.snapshot?.network.filter(\.isPrimary) ?? []
        let ids = links.map(\.id)
        ThroughputCard(
            title: title, symbol: "network", color: Theme.network, secondaryColor: Theme.networkSecondary,
            labels: ("Receive", "Send"),
            rates: (links.reduce(0) { $0 + $1.receivedBytesPerSecond }, links.reduce(0) { $0 + $1.sentBytesPerSecond }),
            histories: (AppModel.tailSum(ids.map { model.networkInHistory[$0]?.values ?? [] }),
                        AppModel.tailSum(ids.map { model.networkOutHistory[$0]?.values ?? [] })),
            format: Format.bitsPerSecond, minimumScale: 125_000, units: .bits, compact: compact
        )
    }
}

struct ThroughputCard: View {
    private static let compactFont = NSFont.numeric(size: 13, weight: .medium)

    var title: String
    var symbol: String
    var color: Color
    var secondaryColor: Color
    var labels: (String, String)
    var rates: (Double, Double)
    var histories: ([Double], [Double])
    var format: (Double) -> String
    /// Keeps a quiet link from magnifying noise to full height.
    var minimumScale: Double
    var units: GraphMath.AxisUnits
    /// One short row with the rates beside the graph, to sit among summary
    /// cards. The graph grows to whatever height the row gives the card.
    var compact = false

    var body: some View {
        if compact {
            Card(tint: color) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(title, systemImage: symbol)
                            .font(.explanation.weight(.medium))
                            .foregroundStyle(.secondaryText)
                        rate(rates.0, symbol: "arrow.down", color: color).help(labels.0)
                        rate(rates.1, symbol: "arrow.up", color: secondaryColor).help(labels.1)
                    }
                    // Fixed, so the graph doesn't shift as the numbers change width.
                    .frame(width: 112, alignment: .leading)
                    graph(axis: nil)
                        .frame(minHeight: 34, maxHeight: .infinity)
                }
            }
        } else {
            Card(tint: color) {
                Label(title, systemImage: symbol).font(.headline)
                HStack(spacing: 24) {
                    Stat(label: labels.0, number: rates.0, color: color, format: format)
                    Stat(label: labels.1, number: rates.1, color: secondaryColor, format: format)
                }
                graph(axis: format)
                    .frame(height: 72)
            }
        }
    }

    private func graph(axis: ((Double) -> String)?) -> GraphView {
        GraphView(
            series: [
                GraphSeries(values: histories.0, color: color),
                GraphSeries(values: histories.1, color: secondaryColor, fill: false, dashed: true),
            ],
            capacity: 120, showsGrid: false, glows: true, minimumCeiling: minimumScale, axis: axis, axisUnits: units
        )
    }

    private func rate(_ value: Double, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
            AnimatedNumber(value: value, format: format, font: Self.compactFont)
        }
    }
}

/// Space on each mounted volume.
private struct StorageCard: View {
    var volumes: [VolumeInfo]

    var body: some View {
        Card(tint: .indigo) {
            Label("Storage", systemImage: "externaldrive").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(volumes.prefix(4)) { volume in
                    let used = Double(volume.usedBytes) / Double(max(volume.totalBytes, 1))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(volume.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text("\(Format.bytes(volume.availableBytes)) free")
                                .font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
                        }
                        StackedBar(segments: [.init(label: "Used", value: used, color: Theme.pressure(used))], total: 1, height: 8)
                        Text("\(Format.bytes(volume.usedBytes)) of \(Format.bytes(volume.totalBytes)) used")
                            .font(.explanation).foregroundStyle(.secondaryText).monospacedDigit()
                    }
                }
            }
        }
    }
}
