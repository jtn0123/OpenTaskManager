import OTMKit
import SwiftUI

struct CPUDetail: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cpuGraphMode") private var mode = "overall"
    @AppStorage(CPUGraphScale.key) private var scale = CPUGraphScale.auto
    /// The page's window, which every graph here covers (`GraphFit`).
    @Environment(\.graphWindow) private var window
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
    /// scale on its caption row. In a card like CPU by app's below it, so
    /// both plots run edge to edge over the same minutes.
    private func graph(_ topology: CPUTopology) -> some View {
        // Every core's graph shares one scale, so they compare at a glance.
        let cores = mode == "cores" ? model.coreHistory.map(\.values) : []
        let coreTop = cores.isEmpty ? 1 : top("cores", peak: cores.map { AutoScaleBounds.peak($0, capacity: window) }.max() ?? 0)
        let title = mode == "cores" ? "Utilization of each core" : mode == "tiers" ? "Utilization by core type" : "Utilization"
        return Card(tint: Theme.cpu) {
            CPUGraphHeader(title: title, note: mode == "cores" ? coreScaleNote(coreTop) : "")
            switch mode {
            case "cores": coreGrid(topology, histories: cores, top: coreTop)
            case "tiers": tierGraphs(topology)
            default:
                let values = model.cpuHistory.values
                GraphPanel(title: "", trailing: "", series: [GraphSeries(values: values, color: Theme.cpu)],
                           maxValue: top("overall", peak: AutoScaleBounds.peak(values, capacity: window)),
                           height: DetailGraph.primary, axis: CPUGraphScale.axisLabel, axisNote: axisNote, offersFit: true)
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

    /// One graph per core type, on a shared scale.
    private func tierGraphs(_ topology: CPUTopology) -> some View {
        let histories = topology.tiers.map { model.tierHistory(level: $0.level) }
        let top = top("tiers", peak: histories.map { AutoScaleBounds.peak($0, capacity: window) }.max() ?? 0)
        return VStack(spacing: 10) {
            ForEach(topology.tiers.indices, id: \.self) { index in
                let tier = topology.tiers[index]
                // The last graph's axis holds the fit toggle, at the foot of the card as in the other forms.
                GraphPanel(title: "\(tier.name) cores (\(tier.logicalCPUs))", trailing: Format.percent(tierUsage(tier.level)),
                           series: [GraphSeries(values: histories[index], color: Theme.tier(tier.level))],
                           maxValue: top, height: DetailGraph.compact, axis: CPUGraphScale.axisLabel, axisNote: axisNote,
                           offersFit: index == topology.tiers.count - 1)
            }
        }
    }

    /// Each core's graph covers the same window as the graphs around it, so a
    /// spike sits over the app that caused it in CPU by app.
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
            TimeAxis(offersFit: true)
                .padding(.top, -6)
        }
    }

    /// One logical CPU's recent load, with its number and current reading.
    private func coreGraph(_ cpu: Int, values: [Double], top: Double, color: Color) -> some View {
        let usage = snapshot.cpu.coreUsage.indices.contains(cpu) ? snapshot.cpu.coreUsage[cpu] : 0
        return GraphView(series: [GraphSeries(values: values, color: color)],
                         maxValue: top, lineWidth: 1.2, glows: true, cornerRadius: 5)
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
                // The metadata size, 12 pt: in a small multiple, a bigger label would hide the graph's top.
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.top, 3)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.18 + 0.5 * usage)))
    }
}

/// The CPU graph's title with the graph and scale pickers. A view of its
/// own, taking only the text, so a sample's update passes it by.
private struct CPUGraphHeader: View {
    let title: String
    /// Said after the title in secondary text, such as the core grid's scale.
    let note: String
    @AppStorage("cpuGraphMode") private var mode = "overall"

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
