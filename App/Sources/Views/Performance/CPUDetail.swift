import OTMKit
import SwiftUI

struct CPUDetail: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cpuGraphMode") private var mode = "overall"
    var snapshot: SystemSnapshot

    var body: some View {
        let topology = model.topology
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "CPU", subtitle: topology.brand)
            Picker("Graph", selection: $mode) {
                Text("Overall").tag("overall")
                Text("By core type").tag("tiers")
                Text("Every core").tag("cores")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            switch mode {
            case "cores": coreGrid(topology)
            case "tiers": tierGraphs(topology)
            default:
                GraphPanel(title: "% Utilization over \(AppModel.graphSpan)s", trailing: "100%",
                           series: [GraphSeries(values: model.cpuHistory.values, color: Theme.cpu)], maxValue: 1, height: 240,
                           axis: { Format.percent($0) })
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 24) {
                        Stat(label: "Utilization", number: snapshot.cpu.usage, color: Theme.cpu) { Format.percent($0) }
                        Stat(label: "User", number: snapshot.cpu.user) { Format.percent($0) }
                        Stat(label: "System", number: snapshot.cpu.system) { Format.percent($0) }
                    }
                    HStack(spacing: 24) {
                        Stat(label: "Processes", value: String(snapshot.processes.count))
                        Stat(label: "Threads", value: String(snapshot.threadCount))
                        Stat(label: "Up time", value: Format.duration(snapshot.uptime))
                    }
                    HStack(spacing: 24) {
                        Stat(label: "Load average (1, 5, 15 min)",
                             value: snapshot.cpu.loadAverage.map { Format.fixed($0, 2) }.joined(separator: "  "))
                    }
                    HStack(spacing: 24) {
                        ForEach(topology.tiers, id: \.level) { tier in
                            Stat(label: "\(tier.name) cores (\(tier.logicalCPUs))", number: tierUsage(tier.level)) { Format.percent($0) }
                        }
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    FactRow(label: "Architecture", value: topology.architecture)
                    FactRow(label: "Cores", value: "\(topology.physicalCores) physical, \(topology.logicalCores) logical")
                    ForEach(topology.tiers, id: \.level) { tier in
                        let cache = tier.l2CacheBytes.map { " · \(Format.bytes(UInt64($0))) L2" } ?? ""
                        FactRow(label: "\(tier.name) cores", value: "\(tier.physicalCPUs)\(cache)")
                    }
                    if let l1 = topology.l1DataCacheBytes {
                        FactRow(label: "L1 data cache", value: Format.bytes(UInt64(l1)) + " per core")
                    }
                    if let l3 = topology.l3CacheBytes {
                        FactRow(label: "L3 cache", value: Format.bytes(UInt64(l3)))
                    }
                }
            }

            if let clusters = snapshot.power.components?.clusters, clusters.contains(where: { $0.activeFraction != nil }) {
                clusterClocks(clusters)
            }
            byApp()
            TopAppsCard(title: "CPU", symbol: "cpu", color: Theme.cpu, groups: model.appGroups,
                        metric: \.cpuPercent, format: { model.cpuScale.format($0.cpuPercent) })
        }
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
            .chartFrame(height: 160, tint: Theme.cpu)
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
        return ChartCard(title: "CPU by app", trailing: "share of the whole CPU", tint: Theme.cpu, legend: legend,
                         span: AppModel.processHistoryCapacity - 2) {
            GraphView(series: series, capacity: AppModel.processHistoryCapacity - 2, glows: true, stacked: true,
                      minimumCeiling: 0.1, maximumCeiling: 1, axis: { Format.percent($0) }, cornerRadius: 8)
                .chartFrame(height: 180, tint: Theme.cpu)
        }
    }

    private func tierUsage(_ level: Int) -> Double {
        let usages = snapshot.cpu.coreUsage.enumerated()
            .filter { model.topology.tierForCPU.indices.contains($0.offset) && model.topology.tierForCPU[$0.offset] == level }
            .map(\.element)
        return usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
    }

    private func tierGraphs(_ topology: CPUTopology) -> some View {
        VStack(spacing: 10) {
            ForEach(topology.tiers, id: \.level) { tier in
                GraphPanel(title: "\(tier.name) cores (\(tier.logicalCPUs))", trailing: Format.percent(tierUsage(tier.level)),
                           series: [GraphSeries(values: model.tierHistory(level: tier.level), color: Theme.tier(tier.level))],
                           maxValue: 1, height: 110, axis: { Format.percent($0) })
            }
        }
    }

    private func coreGrid(_ topology: CPUTopology) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(topology.tiers, id: \.level) { tier in
                let cpus = topology.tierForCPU.indices.filter { topology.tierForCPU[$0] == tier.level }
                Text("\(tier.name) cores").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(max(cpus.count, 1), 6)), spacing: 6) {
                    ForEach(cpus, id: \.self) { cpu in
                        coreGraph(cpu, color: Theme.tier(tier.level))
                    }
                }
            }
        }
    }

    /// One logical CPU's recent load, with its number and current reading.
    private func coreGraph(_ cpu: Int, color: Color) -> some View {
        let usage = snapshot.cpu.coreUsage.indices.contains(cpu) ? snapshot.cpu.coreUsage[cpu] : 0
        return GraphView(series: [GraphSeries(values: model.coreHistory[cpu].values, color: color)],
                         maxValue: 1, capacity: 120, lineWidth: 1.2, glows: true, cornerRadius: 5)
            .frame(height: 64)
            .background(LinearGradient(colors: [color.opacity(0.06 + 0.22 * usage), color.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .top) {
                HStack {
                    Text("\(cpu)").foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.percent(usage)).foregroundStyle(usage > 0.5 ? color : .secondary)
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.top, 3)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.18 + 0.5 * usage)))
    }
}
