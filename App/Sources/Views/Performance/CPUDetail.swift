import OTMKit
import SwiftUI

struct CPUDetail: View {
    @Environment(AppModel.self) private var model
    @AppStorage(CPUGraphMode.key) private var mode = CPUGraphMode.standard
    @AppStorage(CPUGraphScale.key) private var scale = CPUGraphScale.auto
    /// The page's window, which every graph here covers (`GraphFit`).
    @Environment(\.graphWindow) private var window
    @Environment(\.detailPaneHeight) private var pane
    /// The auto-scaled graphs' bounds, held between samples.
    @State private var bounds = AutoScaleBounds()
    var snapshot: SystemSnapshot
    /// Opens another resource's detail, for the chip layout's links.
    var select: (Resource) -> Void

    var body: some View {
        let topology = model.topology
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                DeviceHeader(title: "CPU", subtitle: topology.brand, level: LevelRow(
                    fraction: snapshot.cpu.usage, color: Theme.cpu, value: snapshot.cpu.usage,
                    caption: "busy · \(topology.logicalCores) CPUs", label: "CPU busy"
                ))
                hero(topology)
                    .id(Self.graphID)
                byApp()
                if let clusters = snapshot.power.components?.clusters, clusters.contains(where: { $0.activeFraction != nil }) {
                    clusterClocks(clusters)
                }
                let layout = ChipLayoutStore.shared.layout(topology: topology)
                ChipLayoutCard(layout: layout, activity: activity(layout), showGraphs: { showGraphs(layout, proxy: proxy) },
                               select: select)
                    .equatable()
                TopAppsCard(title: "CPU", symbol: "cpu", color: Theme.cpu, groups: model.appGroups,
                            metric: \.cpuPercent, format: { model.cpuScale.format($0.cpuPercent) }, column: .cpu)
                CPUBenchmarkCard()
                    .equatable()
            }
        }
        .task { await ChipLayoutStore.shared.loadMemoryType() }
    }

    private static let graphID = "cpuGraph"

    /// The chip layout's live readings, all from this sample.
    private func activity(_ layout: ChipLayout) -> ChipActivity {
        let single = layout.coreTypes.count == 1
        var load: [Int: Double] = [:]
        for type in layout.coreTypes {
            load[type.level] = single ? snapshot.cpu.usage : tierUsage(type.level)
        }
        let components = snapshot.power.components
        return ChipActivity(
            load: load, clusters: components?.clusters ?? [],
            gpuUtilization: snapshot.gpus.map(\.deviceUtilization), gpuIDs: snapshot.gpus.map(\.id),
            neuralEngineWatts: components?.watts(.ane), memoryUsed: snapshot.memory.used, memoryTotal: snapshot.memory.physical,
            hasPowerDetail: snapshot.power.systemWatts != nil || snapshot.power.battery != nil
        )
    }

    /// The CPU graph by core type, or each core's with one kind, scrolled into view.
    private func showGraphs(_ layout: ChipLayout, proxy: ScrollViewProxy) {
        mode = layout.coreTypes.count > 1 ? CPUGraphMode.tiers : CPUGraphMode.cores
        proxy.scrollTo(Self.graphID, anchor: .top)
    }

    /// The figures under the main graph. Each core type's load is in the
    /// legend over them where the graph draws the types apart.
    @ViewBuilder
    private func figures(_ topology: CPUTopology) -> some View {
        Stat(label: "Utilization", number: snapshot.cpu.usage, color: Theme.cpu) { Format.percent($0) }
        Stat(label: "User", number: snapshot.cpu.user) { Format.percent($0) }
        Stat(label: "System (kernel)", number: snapshot.cpu.system) { Format.percent($0) }
        // With one kind of core, its load is the overall figure.
        if topology.tiers.count > 1, mode == CPUGraphMode.overall {
            ForEach(topology.tiers, id: \.level) { tier in
                Stat(label: "\(tier.name) cores (\(tier.logicalCPUs))", number: tierUsage(tier.level),
                     color: Theme.tier(tier.level)) { Format.percent($0) }
            }
        }
        Stat(label: "Load (1, 5, 15 min)", value: snapshot.cpu.loadAverage.map { Format.fixed($0, 2) }.joined(separator: " "))
        Stat(label: "Processes", value: String(snapshot.processes.count))
        Stat(label: "Threads", value: String(snapshot.threadCount))
        Stat(label: "Up time", value: Format.duration(snapshot.uptime))
    }

    /// The utilization graph in the chosen form, filling the pane, with the
    /// choice of form and scale on its caption row and the figures under it.
    /// A card like CPU by app's below it, so both plots run edge to edge over
    /// the same minutes.
    private func hero(_ topology: CPUTopology) -> some View {
        // Every core's graph shares one scale, so they compare at a glance.
        let cores = mode == CPUGraphMode.cores ? model.coreHistory.map(\.values) : []
        let coreTop = cores.isEmpty ? 1 : top("cores", peak: cores.map { AutoScaleBounds.peak($0, capacity: window) }.max() ?? 0)
        let title = mode == CPUGraphMode.cores ? "Utilization of each core"
            : mode == CPUGraphMode.tiers ? "Utilization by core type" : "Utilization"
        let height = Hero.height(pane: pane, extra: Hero.legendLine + 4)
        return DeviceCard(tint: Theme.cpu, legend: legend(topology)) {
            CPUGraphHeader(title: title, note: mode == CPUGraphMode.cores ? coreScaleNote(coreTop) : "")
        } plot: {
            switch mode {
            case CPUGraphMode.cores: coreGrid(topology, histories: cores, top: coreTop, height: height)
            case CPUGraphMode.tiers: tierGraphs(topology, height: height)
            default:
                let values = model.cpuHistory.values
                GraphView(series: [GraphSeries(values: values, color: Theme.cpu),
                                   GraphSeries(values: model.cpuSystemHistory.values, color: Theme.wired, fill: false)],
                          maxValue: top("overall", peak: AutoScaleBounds.peak(values, capacity: window)), showsGrid: false,
                          glows: true, axis: CPUGraphScale.axisLabel, axisNote: axisNote, cornerRadius: 8)
                    .heroPlot(height: height, tint: Theme.cpu)
            }
        } figures: {
            figures(topology)
        }
    }

    /// What the main graph's colours stand for: each core type's, where the
    /// graph draws them apart, and the kernel's line.
    private func legend(_ topology: CPUTopology) -> [LegendItem] {
        let kernel = LegendItem(name: "Kernel (system) time", color: Theme.wired, value: Format.percent(snapshot.cpu.system))
        guard mode != CPUGraphMode.overall, topology.tiers.count > 1 else {
            return [LegendItem(name: "Busy", color: Theme.cpu, value: Format.percent(snapshot.cpu.usage)), kernel]
        }
        return topology.tiers.map { tier in
            LegendItem(name: "\(tier.name) cores (\(tier.logicalCPUs))", color: Theme.tier(tier.level),
                       value: Format.percent(tierUsage(tier.level)))
        } + [kernel]
    }

    /// The top of a CPU graph: its auto bound, held in `bounds` under
    /// `graph`, for data on screen peaking at `peak`; or the whole CPU.
    private func top(_ graph: String, peak: @autoclosure () -> Double) -> Double {
        scale == .auto ? bounds.bound(graph, peak: peak()) : 1
    }

    /// Said after an auto-scaled graph's top label.
    private var axisNote: String? {
        scale == .auto ? CPUGraphScale.autoNote : nil
    }

    /// The core graphs have no axis, so their caption gives the shared scale.
    private func coreScaleNote(_ top: Double) -> String {
        scale == .auto ? "0–\(CPUGraphScale.axisLabel(top)) scale, auto" : ""
    }

    /// Each cluster's average clock while it ran. Clusters of one tier share a
    /// colour; the second and later are dashed.
    private func clusterClocks(_ clusters: [ClusterPower]) -> some View {
        let history = model.powerDetail.clusterFrequency
        let styled = clusters.enumerated().map { index, cluster in
            let color = cluster.tierLevel.map(Theme.tier) ?? Theme.series(index)
            let repeated = clusters[..<index].contains { $0.tierLevel != nil && $0.tierLevel == cluster.tierLevel }
            return (cluster: cluster, color: color, dashed: repeated)
        }
        let legend = styled.map { item in
            let busy = item.cluster.activeFraction.map { " · \(Format.percent($0)) running" } ?? ""
            return LegendItem(name: item.cluster.name, color: item.color,
                              value: (item.cluster.frequencyMHz.map { Format.frequency(megahertz: $0) } ?? "Idle") + busy)
        }
        return ChartCard(title: "Clock speed by cluster", trailing: "average while running", tint: Theme.cpu, legend: legend) {
            GraphView(
                series: styled.map {
                    GraphSeries(values: history[$0.cluster.name]?.values ?? [], color: $0.color, fill: !$0.dashed, dashed: $0.dashed)
                },
                glows: true, minimumCeiling: 1_000, axis: { Format.frequency(megahertz: $0) }, cornerRadius: 8
            )
            .chartFrame(height: DetailGraph.secondary, tint: Theme.cpu)
        }
    }

    /// Apps' share of the whole CPU, stacked, with the rest of the system on top.
    private func byApp() -> some View {
        let cores = Double(max(model.topology.logicalCores, 1))
        let apps = model.topApps(by: .cpu, scale: 1 / 100 / cores, count: 5)
        let other = GraphMath.remainder(of: model.cpuHistory.values, minus: apps.map(\.values))
        let colors = Theme.appColors(for: apps.map(\.id), in: "cpu")
        let series = apps.enumerated().map { GraphSeries(values: $1.values, color: colors[$0]) }
            + [GraphSeries(values: other, color: Theme.other)]
        let legend = apps.enumerated().map {
            LegendItem(name: $1.name, color: colors[$0], value: Format.percent($1.current, digits: 1), icon: $1.icon)
        } + [LegendItem(name: "Everything else", color: Theme.other, value: Format.percent(other.last ?? 0, digits: 1))]
        // The same window as the utilization graph above, so the two line up.
        let capacity = window
        // The stack's top band is the whole, which the scale has to hold.
        let stackTop = GraphMath.stack(series.map { Array($0.values.suffix(capacity + 1)) }).last ?? []
        return ChartCard(title: "CPU by app", trailing: "share of the whole CPU", tint: Theme.cpu, legend: legend) {
            GraphView(series: series, maxValue: top("byApp", peak: AutoScaleBounds.peak(stackTop, capacity: capacity)),
                      glows: true, stacked: true, axis: CPUGraphScale.axisLabel, axisNote: axisNote, cornerRadius: 8)
                .chartFrame(height: DetailGraph.secondary, tint: Theme.cpu)
        }
    }

    private func tierUsage(_ level: Int) -> Double {
        let usages = snapshot.cpu.coreUsage.enumerated()
            .filter { model.topology.tierForCPU.indices.contains($0.offset) && model.topology.tierForCPU[$0.offset] == level }
            .map(\.element)
        return usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
    }

    /// One graph per core type, on a shared scale, sharing the main graph's
    /// height, each with its kernel time as a line.
    private func tierGraphs(_ topology: CPUTopology, height: CGFloat) -> some View {
        let histories = topology.tiers.map { model.tierHistory(level: $0.level) }
        let top = top("tiers", peak: histories.map { AutoScaleBounds.peak($0, capacity: window) }.max() ?? 0)
        let count = CGFloat(max(topology.tiers.count, 1))
        // Each graph's caption line and the gaps between them come out of the height.
        let each = max((height - (count - 1) * 10 - count * 19) / count, DetailGraph.compact)
        return VStack(spacing: 10) {
            ForEach(topology.tiers.indices, id: \.self) { index in
                let tier = topology.tiers[index]
                VStack(alignment: .leading, spacing: 3) {
                    HeroGraphTitle(title: "\(tier.name) cores (\(tier.logicalCPUs))", trailing: Format.percent(tierUsage(tier.level)))
                    GraphView(series: [GraphSeries(values: histories[index], color: Theme.tier(tier.level)),
                                       GraphSeries(values: model.tierHistory(level: tier.level, kernel: true), color: Theme.wired,
                                                   fill: false)],
                              maxValue: top, showsGrid: false, glows: true, axis: CPUGraphScale.axisLabel, axisNote: axisNote,
                              cornerRadius: 8)
                        .heroPlot(height: each, tint: Theme.tier(tier.level), rows: 4)
                }
            }
        }
    }

    /// A graph for every logical CPU, filling the main graph's area, over the
    /// same window as the graphs around it, so a spike sits over the app that
    /// caused it in CPU by app. Performance cores come first.
    private func coreGrid(_ topology: CPUTopology, histories: [[Double]], top: Double, height: CGFloat) -> some View {
        let kernels = model.coreSystemHistory.map(\.values)
        let several = topology.tiers.count > 1
        let tiers = topology.tiers.sorted { $0.level < $1.level }
        let runs = tiers.map { tier in
            (tier: tier, cpus: topology.tierForCPU.indices.filter { topology.tierForCPU[$0] == tier.level && histories.indices.contains($0) })
        }
        let tiles = runs.flatMap { run in
            run.cpus.map { cpu in
                CoreGraphGrid.Tile(cpu: cpu, kind: several ? String(run.tier.name.prefix(1)) : "",
                                   kindName: several ? "\(run.tier.name) core" : "", color: Theme.tier(run.tier.level),
                                   busy: histories[cpu], kernel: kernels.indices.contains(cpu) ? kernels[cpu] : [])
            }
        }
        return CoreGraphGrid(tiles: tiles, groups: runs.map(\.cpus.count).filter { $0 > 0 }, top: top, height: height,
                             kernelColor: Theme.wired)
    }
}

/// The CPU graph's forms, as kept under `key`.
enum CPUGraphMode {
    static let key = "cpuGraphMode"
    static let overall = "overall"
    static let tiers = "tiers"
    static let cores = "cores"
    /// A graph for every core, so each one's load shows at first look.
    static let standard = cores
}

/// The CPU graph's title with the graph and scale pickers. A view of its
/// own, taking only the text, so a sample's update passes it by.
private struct CPUGraphHeader: View {
    let title: String
    /// Said after the title in secondary text, such as the core grid's scale.
    let note: String
    @AppStorage(CPUGraphMode.key) private var mode = CPUGraphMode.standard

    var body: some View {
        // Not a `ViewThatFits`: it measured both segmented controls again on
        // every layout pass, once a second, for about half a percent of a core.
        CaptionControlsRow {
            caption
            graphPicker
            CPUScalePicker()
        }
    }

    private var caption: Text {
        let heading = Text(title).font(.headline)
        guard !note.isEmpty else { return heading }
        return heading + Text("  " + note).font(.callout).foregroundStyle(.secondaryText)
    }

    private var graphPicker: some View {
        Picker("Graph", selection: $mode) {
            Text("Every core").tag(CPUGraphMode.cores)
            Text("By core type").tag(CPUGraphMode.tiers)
            Text("Overall").tag(CPUGraphMode.overall)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A caption and two controls: on one line, the controls at the trailing
/// end, while they fit; then the caption over the controls, one at each end;
/// then all three stacked. The caption wraps rather than truncates.
private struct CaptionControlsRow: Layout {
    private let spacing: CGFloat = 10
    private let rowGap: CGFloat = 6

    private enum Arrangement { case oneLine, twoLines, stacked }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? oneLineWidth(sizes)
        let caption = captionHeight(subviews, sizes, width: width)
        switch arrangement(sizes, width: width) {
        case .oneLine: return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
        case .twoLines: return CGSize(width: width, height: caption + rowGap + max(sizes[1].height, sizes[2].height))
        case .stacked: return CGSize(width: width, height: caption + 2 * rowGap + sizes[1].height + sizes[2].height)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let caption = captionHeight(subviews, sizes, width: bounds.width)
        switch arrangement(sizes, width: bounds.width) {
        case .oneLine:
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(sizes[0]))
            subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(sizes[2]))
            subviews[1].place(at: CGPoint(x: bounds.maxX - sizes[2].width - spacing, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(sizes[1]))
        case .twoLines:
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: caption))
            let middle = bounds.minY + caption + rowGap + max(sizes[1].height, sizes[2].height) / 2
            subviews[1].place(at: CGPoint(x: bounds.minX, y: middle), anchor: .leading, proposal: ProposedViewSize(sizes[1]))
            subviews[2].place(at: CGPoint(x: bounds.maxX, y: middle), anchor: .trailing, proposal: ProposedViewSize(sizes[2]))
        case .stacked:
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: caption))
            var y = bounds.minY + caption + rowGap
            for index in 1...2 {
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y),
                                      proposal: ProposedViewSize(width: min(sizes[index].width, bounds.width), height: sizes[index].height))
                y += sizes[index].height + rowGap
            }
        }
    }

    private func oneLineWidth(_ sizes: [CGSize]) -> CGFloat {
        sizes.map(\.width).reduce(0, +) + 2 * spacing
    }

    private func arrangement(_ sizes: [CGSize], width: CGFloat) -> Arrangement {
        if oneLineWidth(sizes) <= width { return .oneLine }
        return sizes[1].width + spacing + sizes[2].width <= width ? .twoLines : .stacked
    }

    /// The caption's height on a line of its own, wrapped to `width`.
    private func captionHeight(_ subviews: Subviews, _ sizes: [CGSize], width: CGFloat) -> CGFloat {
        sizes[0].width <= width ? sizes[0].height : subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
}
