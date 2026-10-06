import OTMKit
import SwiftUI

/// At-a-glance dashboard: a gauge per resource, a live map of every core,
/// throughput, and which apps are using what.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.snapshot {
            let groups = model.appGroups
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
                        if let components = snapshot.power.components { powerCard(components) }
                        StorageCard(volumes: snapshot.volumes)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        TopAppsCard(title: "CPU", symbol: "cpu", color: Theme.cpu, groups: groups,
                                metric: \.cpuPercent, format: { model.cpuScale.format($0.cpuPercent) })
                        TopAppsCard(title: "Memory", symbol: "memorychip", color: Theme.memory, groups: groups,
                                metric: { Double($0.memory) }, format: { Format.bytes($0.memory) })
                        TopAppsCard(title: "Energy", symbol: "bolt.fill", color: Theme.power, groups: groups,
                                metric: \.powerWatts, format: { Format.watts($0.powerWatts) }, minimum: 0.01)
                    }
                }
                .padding(20)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Gauges

    private func cpuGauge(_ snapshot: SystemSnapshot) -> some View {
        let topology = model.topology
        return GaugeCard(
            title: "CPU", value: snapshot.cpu.usage * 100, format: { Format.fixed($0, 0) }, unit: "%",
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
            title: "Memory", value: memory.usedFraction * 100, format: { Format.fixed($0, 0) }, unit: "%",
            fraction: memory.usedFraction, color: color,
            detail: "\(Format.bytes(memory.used)) of \(Format.bytes(memory.physical)) · \(memory.pressure.rawValue) pressure",
            history: model.memoryHistory.values, historyMax: 1
        )
    }

    private func gpuGauge(_ gpu: GPUSample) -> some View {
        GaugeCard(
            title: "GPU", value: gpu.deviceUtilization * 100, format: { Format.fixed($0, 0) }, unit: "%",
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
            title: "Power", value: watts, format: { Format.fixed($0, $0 < 10 ? 1 : 0) }, unit: "W",
            fraction: watts / ceiling, color: Theme.power,
            detail: "\(source) · thermal \(power.thermalState.rawValue)",
            history: history, historyMax: nil
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
            format: Format.bytesPerSecond, minimumScale: 1_048_576, units: .binaryBytes
        )
    }

    private func networkCard(_ snapshot: SystemSnapshot) -> some View {
        let links = snapshot.network.filter(\.isPrimary)
        let ids = links.map(\.id)
        return ThroughputCard(
            title: "Network", symbol: "network", color: Theme.network, secondaryColor: Theme.networkSecondary,
            labels: ("Receive", "Send"),
            rates: (links.reduce(0) { $0 + $1.receivedBytesPerSecond }, links.reduce(0) { $0 + $1.sentBytesPerSecond }),
            histories: (AppModel.tailSum(ids.map { model.networkInHistory[$0]?.values ?? [] }),
                        AppModel.tailSum(ids.map { model.networkOutHistory[$0]?.values ?? [] })),
            format: Format.bitsPerSecond, minimumScale: 125_000, units: .bits
        )
    }

    /// Where the power goes, stacked by part of the Mac.
    private func powerCard(_ components: PowerComponents) -> some View {
        let history = model.powerDetail
        let rest = history.rest.values.last ?? 0
        return Card(tint: Theme.power) {
            Label("Power", systemImage: "bolt.fill").font(.headline)
            HStack(spacing: 18) {
                Stat(label: "CPU", number: components.cpu, color: Theme.cpu, format: Format.watts)
                Stat(label: "GPU", number: components.gpu, color: Theme.gpu, format: Format.watts)
                Stat(label: "Rest", number: rest, color: Theme.restOfSystem, format: Format.watts)
            }
            GraphView(
                series: [
                    GraphSeries(values: history.cpu.values, color: Theme.cpu),
                    GraphSeries(values: history.gpu.values, color: Theme.gpu),
                    GraphSeries(values: history.ane.values, color: Theme.neuralEngine),
                    GraphSeries(values: history.dram.values, color: Theme.dram),
                    GraphSeries(values: history.rest.values, color: Theme.restOfSystem),
                ],
                capacity: 120, showsGrid: false, glows: true, stacked: true, minimumCeiling: 5, axis: Format.watts
            )
            .frame(height: 72)
        }
    }
}

// MARK: - Pieces

private struct GaugeCard: View {
    private static let valueFont = NSFont.numeric(size: 26, weight: .semibold, rounded: true)

    var title: String
    var value: Double
    var format: (Double) -> String
    var unit: String
    var fraction: Double
    var color: Color
    var detail: String
    var history: [Double]
    var historyMax: Double?

    var body: some View {
        Card(tint: color, glow: fraction) {
            HStack(spacing: 14) {
                ZStack {
                    RingGauge(fraction: fraction, color: color, lineWidth: 10)
                    VStack(spacing: -2) {
                        AnimatedNumber(value: value, format: format, font: Self.valueFont, alignment: .center)
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
                              capacity: 60, showsGrid: false, lineWidth: 1.4, glows: true)
                        .frame(height: 34)
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
                Text("\(topology.brand) · load by core type").font(.caption).foregroundStyle(.secondary)
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
        return GraphView(series: series, maxValue: 1, capacity: 120, glows: true, axis: { Format.percent($0) }, cornerRadius: 8)
            .background(Theme.cpu.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cpu.opacity(0.18)))
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
    /// Keeps a quiet link from magnifying noise to full height.
    var minimumScale: Double
    var units: GraphMath.AxisUnits

    var body: some View {
        Card(tint: color) {
            Label(title, systemImage: symbol).font(.headline)
            HStack(spacing: 24) {
                Stat(label: labels.0, number: rates.0, color: color, format: format)
                Stat(label: labels.1, number: rates.1, color: secondaryColor, format: format)
            }
            GraphView(
                series: [
                    GraphSeries(values: histories.0, color: color),
                    GraphSeries(values: histories.1, color: secondaryColor, fill: false, dashed: true),
                ],
                capacity: 120, showsGrid: false, glows: true, minimumCeiling: minimumScale, axis: format, axisUnits: units
            )
            .frame(height: 72)
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
