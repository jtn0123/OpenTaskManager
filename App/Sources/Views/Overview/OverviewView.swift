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
                    FillGrid(minimum: 210) {
                        cpuGauge(snapshot)
                        memoryGauge(snapshot)
                        if let gpu = snapshot.gpus.first { gpuGauge(gpu) }
                        if let watts = snapshot.power.systemWatts { powerGauge(watts, snapshot.power) }
                    }
                    CoreMap(snapshot: snapshot)
                    FillGrid(minimum: 280) {
                        diskCard(snapshot)
                        NetworkTrafficCard()
                        if let components = snapshot.power.components { powerCard(components) }
                    }
                    FillGrid(minimum: 280) {
                        TopAppsCard(title: "CPU", symbol: "cpu", color: Theme.cpu, groups: groups,
                                metric: \.cpuPercent, format: { model.cpuScale.format($0.cpuPercent) })
                        TopAppsCard(title: "Memory", symbol: "memorychip", color: Theme.memory, groups: groups,
                                metric: { Double($0.memory) }, format: { Format.bytes($0.memory) })
                        TopAppsCard(title: "Energy", symbol: "bolt.fill", color: Theme.power, groups: groups,
                                metric: \.powerWatts, format: { Format.watts($0.powerWatts) }, minimum: 0.01,
                                unavailable: snapshot.measuresProcessEnergy == false ? Unavailable.energy : nil)
                        TopNetworkCard()
                    }
                    StorageCard(volumes: snapshot.volumes)
                }
                .padding(20)
            }
            .defaultScrollAnchor(LaunchArgument.string("openScroll") == "bottom" ? .bottom : .top)
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
            details: ["\(topology.logicalCores) cores", "Load \(Format.fixed(snapshot.cpu.loadAverage.first ?? 0, 2))"],
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
            details: ["\(Format.bytes(memory.used)) of \(Format.bytes(memory.physical))", "\(memory.pressure.rawValue.capitalized) pressure"],
            history: model.memoryHistory.values, historyMax: 1
        )
    }

    private func gpuGauge(_ gpu: GPUSample) -> some View {
        let busy = gpu.deviceUtilization
        return GaugeCard(
            title: "GPU", value: busy.map { $0 * 100 }, format: { Format.fixed($0, 0) }, unit: "%",
            fraction: busy ?? 0, color: Theme.gpu,
            details: [gpu.name] + (gpu.coreCount.map { ["\($0) cores"] } ?? []) + (busy == nil ? [Unavailable.gpuUtilization] : []),
            history: model.gpuHistory[gpu.id]?.values ?? [], historyMax: 1
        )
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

    var title: String
    /// nil when this Mac doesn't report the reading: the ring shows "—", not 0.
    var value: Double?
    var format: (Double) -> String
    var unit: String
    var fraction: Double
    var color: Color
    /// One fact per line, each truncated rather than wrapped.
    var details: [String]
    var history: [Double]
    var historyMax: Double?

    var body: some View {
        Card(tint: color, glow: fraction) {
            HStack(spacing: 14) {
                ZStack {
                    RingGauge(fraction: fraction, color: color, lineWidth: 10)
                    VStack(spacing: -2) {
                        if let value {
                            AnimatedNumber(value: value, format: format, font: Self.valueFont, alignment: .center)
                            Text(unit).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        } else {
                            Text("—").font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.title3.weight(.semibold))
                        ForEach(details.indices, id: \.self) { index in
                            Text(details[index]).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    GraphView(series: [GraphSeries(values: history, color: color)], maxValue: historyMax,
                              capacity: 60, showsGrid: false, lineWidth: 1.4, glows: true)
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
                Text("\(topology.brand) · load by core type").font(.subheadline).foregroundStyle(.secondary)
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
            .plotFrame(tint: Theme.cpu, wash: (0.05, 0.05), border: 0.18)
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
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
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
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
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
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        StackedBar(segments: [.init(label: "Used", value: used, color: Theme.pressure(used))], total: 1, height: 8)
                        Text("\(Format.bytes(volume.usedBytes)) of \(Format.bytes(volume.totalBytes)) used")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}
