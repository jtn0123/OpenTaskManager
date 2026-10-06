import OTMKit
import SwiftUI

/// At-a-glance dashboard: a gauge per resource, a live map of every core,
/// throughput, and which apps are using what.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.snapshot {
            let groups = appGroups(snapshot)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
                        cpuGauge(snapshot)
                        memoryGauge(snapshot)
                        if let gpu = snapshot.gpus.first { gpuGauge(gpu) }
                        if let watts = snapshot.power.systemWatts { powerGauge(watts, snapshot.power) }
                    }
                    CoreMap(snapshot: snapshot)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        diskCard(snapshot)
                        networkCard(snapshot)
                        StorageCard(volumes: snapshot.volumes)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        TopCard(title: "CPU", symbol: "cpu", color: Theme.cpu, groups: groups,
                                metric: \.cpuPercent, format: { model.cpuScale.format($0.cpuPercent) })
                        TopCard(title: "Memory", symbol: "memorychip", color: Theme.memory, groups: groups,
                                metric: { Double($0.memory) }, format: { Format.bytes($0.memory) })
                        TopCard(title: "Energy", symbol: "bolt.fill", color: Theme.power, groups: groups,
                                metric: \.powerWatts, format: { Format.watts($0.powerWatts) }, minimum: 0.01)
                    }
                }
                .padding(20)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Apps with their helpers folded in, so "Safari" includes its web content processes.
    private func appGroups(_ snapshot: SystemSnapshot) -> [ProcessNode] {
        ProcessTreeBuilder.build(snapshot.processes, mode: .grouped, appPIDs: Set(model.regularApps.keys))
            .flatMap(\.children)
    }

    // MARK: Gauges

    private func cpuGauge(_ snapshot: SystemSnapshot) -> some View {
        let topology = model.topology
        return GaugeCard(
            title: "CPU", value: Format.fixed(snapshot.cpu.usage * 100, 0), unit: "%",
            fraction: snapshot.cpu.usage, color: Theme.cpu,
            detail: "\(topology.logicalCores) cores · load \(Format.fixed(snapshot.cpu.loadAverage.first ?? 0, 2))",
            history: model.cpuHistory.values, historyMax: 1
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
            title: "Memory", value: Format.fixed(memory.usedFraction * 100, 0), unit: "%",
            fraction: memory.usedFraction, color: color,
            detail: "\(Format.bytes(memory.used)) of \(Format.bytes(memory.physical)) · \(memory.pressure.rawValue) pressure",
            history: model.memoryHistory.values, historyMax: 1
        )
    }

    private func gpuGauge(_ gpu: GPUSample) -> some View {
        GaugeCard(
            title: "GPU", value: Format.fixed(gpu.deviceUtilization * 100, 0), unit: "%",
            fraction: gpu.deviceUtilization, color: Theme.gpu,
            detail: gpu.coreCount.map { "\(gpu.name) · \($0) cores" } ?? gpu.name,
            history: model.gpuHistory[gpu.id]?.values ?? [], historyMax: 1
        )
    }

    private func powerGauge(_ watts: Double, _ power: PowerSample) -> some View {
        let history = model.powerHistory.values
        // Scale to the most this Mac has ever drawn, so the ring reads as
        // "how hard is it working" whether it's an Air or a Studio.
        let ceiling = max(model.peakSystemWatts, 20)
        let source = power.battery.map { "Battery \($0.percent)%" + ($0.isPluggedIn ? " · plugged in" : "") } ?? "AC power"
        return GaugeCard(
            title: "Power", value: Format.fixed(watts, watts < 10 ? 1 : 0), unit: "W",
            fraction: watts / ceiling, color: Theme.power,
            detail: "\(source) · thermal \(power.thermalState.rawValue)",
            history: history, historyMax: GraphView.niceCeiling(max(history.max() ?? 0, 1))
        )
    }

    // MARK: Throughput

    private func diskCard(_ snapshot: SystemSnapshot) -> some View {
        let ids = snapshot.disks.map(\.id)
        return ThroughputCard(
            title: "Disk", symbol: "internaldrive", color: Theme.disk, secondaryColor: Theme.diskSecondary,
            labels: ("Read", "Write"),
            rates: (snapshot.disks.reduce(0) { $0 + $1.readBytesPerSecond }, snapshot.disks.reduce(0) { $0 + $1.writeBytesPerSecond }),
            histories: (tailSum(ids.map { model.diskReadHistory[$0]?.values ?? [] }),
                        tailSum(ids.map { model.diskWriteHistory[$0]?.values ?? [] })),
            format: Format.bytesPerSecond
        )
    }

    private func networkCard(_ snapshot: SystemSnapshot) -> some View {
        let links = snapshot.network.filter(\.isPrimary)
        let ids = links.map(\.id)
        return ThroughputCard(
            title: "Network", symbol: "network", color: Theme.network, secondaryColor: Theme.networkSecondary,
            labels: ("Receive", "Send"),
            rates: (links.reduce(0) { $0 + $1.receivedBytesPerSecond }, links.reduce(0) { $0 + $1.sentBytesPerSecond }),
            histories: (tailSum(ids.map { model.networkInHistory[$0]?.values ?? [] }),
                        tailSum(ids.map { model.networkOutHistory[$0]?.values ?? [] })),
            format: Format.bitsPerSecond
        )
    }

    /// Adds histories element-wise, aligned on their newest values.
    private func tailSum(_ series: [[Double]]) -> [Double] {
        let length = series.map(\.count).max() ?? 0
        return (0..<length).map { index in
            series.reduce(0) { total, values in
                let offset = index - (length - values.count)
                return offset >= 0 ? total + values[offset] : total
            }
        }
    }
}

// MARK: - Pieces

/// Stretches a short history across the graph until it has enough points to
/// scroll, so a fresh launch shows a line rather than a squiggle at the edge.
private func fillingCapacity(_ count: Int, upTo limit: Int) -> Int {
    min(max(count, 2), limit)
}

private struct GaugeCard: View {
    var title: String
    var value: String
    var unit: String
    var fraction: Double
    var color: Color
    var detail: String
    var history: [Double]
    var historyMax: Double?

    var body: some View {
        Card(tint: color) {
            HStack(spacing: 14) {
                ZStack {
                    RingGauge(fraction: fraction, color: color, lineWidth: 10)
                    VStack(spacing: -2) {
                        Text(value)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(unit).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    GraphView(series: [GraphSeries(values: history, color: color)], maxValue: historyMax,
                              capacity: fillingCapacity(history.count, upTo: 90), showsGrid: false, lineWidth: 1.2)
                        .frame(height: 30)
                }
            }
            .frame(height: 96)
        }
    }
}

/// Every logical CPU as a tile that fills with load, one row per core type.
private struct CoreMap: View {
    @Environment(AppModel.self) private var model
    var snapshot: SystemSnapshot

    var body: some View {
        let topology = model.topology
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Cores").font(.headline)
                Spacer()
                Text(topology.brand).font(.caption).foregroundStyle(.secondary)
            }
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

    private func tierGraph(_ topology: CPUTopology) -> some View {
        let series = topology.tiers.map { tier in
            GraphSeries(values: model.tierHistory(level: tier.level), color: Theme.tier(tier.level), fill: tier.level == 0)
        }
        let count = series.map(\.values.count).max() ?? 0
        return GraphView(series: series, maxValue: 1, capacity: fillingCapacity(count, upTo: 120), glows: true)
            .background(Theme.cpu.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cpu.opacity(0.18)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                Text("Load by core type").font(.caption2).foregroundStyle(.secondary).padding(6)
            }
    }

    private func tierRow(_ tier: CPUTopology.Tier, topology: CPUTopology) -> some View {
        let cpus = topology.tierForCPU.indices.filter { topology.tierForCPU[$0] == tier.level }
        let usages = cpus.map { snapshot.cpu.coreUsage.indices.contains($0) ? snapshot.cpu.coreUsage[$0] : 0 }
        let average = usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(Theme.tier(tier.level)).frame(width: 8, height: 8)
                    Text(tier.name).font(.callout.weight(.medium))
                }
                Text("\(cpus.count) cores · \(Format.percent(average))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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

private struct ThroughputCard: View {
    var title: String
    var symbol: String
    var color: Color
    var secondaryColor: Color
    var labels: (String, String)
    var rates: (Double, Double)
    var histories: ([Double], [Double])
    var format: (Double) -> String

    var body: some View {
        let scale = GraphView.niceCeiling(max(histories.0.suffix(120).max() ?? 0, histories.1.suffix(120).max() ?? 0))
        Card(tint: color) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                Text("scale \(format(scale))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 24) {
                Stat(label: labels.0, value: format(rates.0), color: color)
                Stat(label: labels.1, value: format(rates.1), color: secondaryColor)
            }
            GraphView(
                series: [
                    GraphSeries(values: histories.0, color: color),
                    GraphSeries(values: histories.1, color: secondaryColor, fill: false, dashed: true),
                ],
                maxValue: scale, capacity: fillingCapacity(max(histories.0.count, histories.1.count), upTo: 120),
                showsGrid: false, glows: true
            )
            .frame(height: 64)
        }
    }
}

/// Space on each mounted volume.
private struct StorageCard: View {
    var volumes: [VolumeInfo]

    var body: some View {
        Card(tint: .indigo) {
            Label("Storage", systemImage: "externaldrive").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(volumes.prefix(4)) { volume in
                    let used = Double(volume.usedBytes) / Double(max(volume.totalBytes, 1))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(volume.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text("\(Format.bytes(volume.availableBytes)) free")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        StackedBar(segments: [.init(label: "Used", value: used, color: Theme.pressure(used))], total: 1, height: 8)
                        Text("\(Format.bytes(volume.usedBytes)) of \(Format.bytes(volume.totalBytes)) used")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// The apps using the most of one resource, with bars relative to the leader.
private struct TopCard: View {
    @Environment(AppModel.self) private var model
    var title: String
    var symbol: String
    var color: Color
    var groups: [ProcessNode]
    var metric: (ProcessTotals) -> Double
    var format: (ProcessTotals) -> String
    /// Values below this round to zero and aren't worth a row.
    var minimum: Double = 0

    var body: some View {
        let top = groups.filter { metric($0.totals) > minimum }.sorted { metric($0.totals) > metric($1.totals) }.prefix(6)
        let peak = top.first.map { metric($0.totals) } ?? 1
        Card {
            Label("Top \(title)", systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
            if top.isEmpty {
                Text("Quiet right now.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(Array(top), id: \.id) { group in
                    if let process = group.process {
                        ProcessBarRow(
                            icon: IconCache.icon(for: process, app: model.regularApps[process.pid]),
                            name: model.displayName(for: process),
                            value: format(group.totals),
                            fraction: metric(group.totals) / max(peak, .leastNonzeroMagnitude),
                            color: color
                        )
                    }
                }
            }
        }
    }
}
