import OTMKit
import SwiftUI

struct CPUDetail: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cpuGraphMode") private var mode = "overall"
    @AppStorage(CPUGraphScale.key) private var scale = CPUGraphScale.auto
    /// The auto-scaled graphs' bounds, held between samples.
    @State private var bounds = AutoScaleBounds()
    var snapshot: SystemSnapshot
    /// Opens another resource's detail, for the chip layout's links.
    var select: (Resource) -> Void

    var body: some View {
        let topology = model.topology
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: "CPU", subtitle: topology.brand)
                stats(topology)
                graph(topology)
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
                            metric: \.cpuPercent, format: { model.cpuScale.format($0.cpuPercent) })
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
        mode = layout.coreTypes.count > 1 ? "tiers" : "cores"
        proxy.scrollTo(Self.graphID, anchor: .top)
    }

    private func stats(_ topology: CPUTopology) -> some View {
        MetricStrip(tint: Theme.cpu) {
            Stat(label: "Utilization", number: snapshot.cpu.usage, color: Theme.cpu) { Format.percent($0) }
            Stat(label: "User", number: snapshot.cpu.user) { Format.percent($0) }
            Stat(label: "System", number: snapshot.cpu.system) { Format.percent($0) }
            // With one kind of core, its load is the overall figure.
            if topology.tiers.count > 1 {
                ForEach(topology.tiers, id: \.level) { tier in
                    Stat(label: "\(tier.name) cores (\(tier.logicalCPUs))", number: tierUsage(tier.level),
                         color: Theme.tier(tier.level)) { Format.percent($0) }
                }
            }
            Stat(label: "Load average (1, 5, 15 min)",
                 value: snapshot.cpu.loadAverage.map { Format.fixed($0, 2) }.joined(separator: "  "))
            Stat(label: "Processes", value: String(snapshot.processes.count))
            Stat(label: "Threads", value: String(snapshot.threadCount))
            Stat(label: "Up time", value: Format.duration(snapshot.uptime))
        }
    }

    /// The utilization graph in the chosen form, with the choice of form and
    /// scale on its caption row.
    private func graph(_ topology: CPUTopology) -> some View {
        // Every core's graph shares one scale, so they compare at a glance.
        let cores = mode == "cores" ? model.coreHistory.map(\.values) : []
        let coreTop = cores.isEmpty ? 1 : top("cores", peak: cores.map { AutoScaleBounds.peak($0, capacity: Self.coreCapacity) }.max() ?? 0)
        let caption = mode == "cores" ? "% Utilization of each core" + coreScaleNote(coreTop)
            : mode == "tiers" ? "% Utilization by core type" : "% Utilization over \(AppModel.graphSpan)s"
        return VStack(alignment: .leading, spacing: 6) {
            CPUGraphHeader(caption: caption)
            switch mode {
            case "cores": coreGrid(topology, histories: cores, top: coreTop)
            case "tiers": tierGraphs(topology)
            default:
                let values = model.cpuHistory.values
                GraphPanel(title: "", trailing: "", series: [GraphSeries(values: values, color: Theme.cpu)],
                           maxValue: top("overall", peak: AutoScaleBounds.peak(values, capacity: AppModel.graphSpan)),
                           height: DetailGraph.primary, axis: CPUGraphScale.axisLabel, axisNote: axisNote)
            }
        }
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
        scale == .auto ? " · 0–\(CPUGraphScale.axisLabel(top)) scale, auto" : ""
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
        let apps = model.topApps(by: { $0.cpuPercent / 100 / cores }, count: 5)
        let total = Array(model.cpuHistory.values.suffix(AppModel.processHistoryCapacity))
        let other = AppModel.remainder(of: total, minus: apps.map(\.values))
        let series = apps.enumerated().map { GraphSeries(values: $1.values, color: Theme.series($0)) }
            + [GraphSeries(values: other, color: Theme.other)]
        let legend = apps.enumerated().map {
            LegendItem(name: $1.name, color: Theme.series($0), value: Format.percent($1.current, digits: 1), icon: $1.icon)
        } + [LegendItem(name: "Everything else", color: Theme.other, value: Format.percent(other.last ?? 0, digits: 1))]
        let capacity = AppModel.processHistoryCapacity - 2
        // The stack's top band is the whole, which the scale has to hold.
        let stackTop = GraphMath.stack(series.map { Array($0.values.suffix(capacity + 1)) }).last ?? []
        return ChartCard(title: "CPU by app", trailing: "share of the whole CPU", tint: Theme.cpu, legend: legend, span: capacity) {
            GraphView(series: series, maxValue: top("byApp", peak: AutoScaleBounds.peak(stackTop, capacity: capacity)),
                      capacity: capacity, glows: true, stacked: true,
                      axis: CPUGraphScale.axisLabel, axisNote: axisNote, cornerRadius: 8)
                .chartFrame(height: DetailGraph.secondary, tint: Theme.cpu)
        }
    }

    private func tierUsage(_ level: Int) -> Double {
        let usages = snapshot.cpu.coreUsage.enumerated()
            .filter { model.topology.tierForCPU.indices.contains($0.offset) && model.topology.tierForCPU[$0.offset] == level }
            .map(\.element)
        return usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
    }

    /// One graph per core type, on a shared scale.
    private func tierGraphs(_ topology: CPUTopology) -> some View {
        let histories = topology.tiers.map { model.tierHistory(level: $0.level) }
        let top = top("tiers", peak: histories.map { AutoScaleBounds.peak($0, capacity: AppModel.graphSpan) }.max() ?? 0)
        return VStack(spacing: 10) {
            ForEach(topology.tiers.indices, id: \.self) { index in
                let tier = topology.tiers[index]
                GraphPanel(title: "\(tier.name) cores (\(tier.logicalCPUs))", trailing: Format.percent(tierUsage(tier.level)),
                           series: [GraphSeries(values: histories[index], color: Theme.tier(tier.level))],
                           maxValue: top, height: DetailGraph.compact, axis: CPUGraphScale.axisLabel, axisNote: axisNote)
            }
        }
    }

    /// Samples across each core's graph.
    private static let coreCapacity = 120

    private func coreGrid(_ topology: CPUTopology, histories: [[Double]], top: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(topology.tiers, id: \.level) { tier in
                let cpus = topology.tierForCPU.indices.filter { topology.tierForCPU[$0] == tier.level && histories.indices.contains($0) }
                Text("\(tier.name) cores").font(.callout).foregroundStyle(.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(max(cpus.count, 1), 6)), spacing: 6) {
                    ForEach(cpus, id: \.self) { cpu in
                        coreGraph(cpu, values: histories[cpu], top: top, color: Theme.tier(tier.level))
                    }
                }
            }
        }
    }

    /// One logical CPU's recent load, with its number and current reading.
    private func coreGraph(_ cpu: Int, values: [Double], top: Double, color: Color) -> some View {
        let usage = snapshot.cpu.coreUsage.indices.contains(cpu) ? snapshot.cpu.coreUsage[cpu] : 0
        return GraphView(series: [GraphSeries(values: values, color: color)],
                         maxValue: top, capacity: Self.coreCapacity, lineWidth: 1.2, glows: true, cornerRadius: 5)
            .frame(height: 64)
            .background(LinearGradient(colors: [color.opacity(0.06 + 0.22 * usage), color.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .top) {
                HStack {
                    Text("\(cpu)").foregroundStyle(.secondaryText)
                    Spacer()
                    Text(Format.percent(usage)).foregroundStyle(usage > 0.5 ? AnyShapeStyle(color) : AnyShapeStyle(.secondaryText))
                }
                // The metadata size: in a small multiple, a bigger label would hide the graph's top.
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.top, 3)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.18 + 0.5 * usage)))
    }
}

/// The CPU graph's caption with the graph and scale pickers. A view of its
/// own, taking only the caption, so a sample's update passes it by.
private struct CPUGraphHeader: View {
    let caption: String
    @AppStorage("cpuGraphMode") private var mode = "overall"

    var body: some View {
        // Not a `ViewThatFits`: it measured both segmented controls again on
        // every layout pass, once a second, for about half a percent of a core.
        CaptionControlsRow {
            Text(caption).font(.subheadline).foregroundStyle(.secondaryText)
            graphPicker
            CPUScalePicker()
        }
    }

    private var graphPicker: some View {
        Picker("Graph", selection: $mode) {
            Text("Overall").tag("overall")
            Text("By core type").tag("tiers")
            Text("Every core").tag("cores")
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
