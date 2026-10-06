import OTMKit
import SwiftUI

enum Resource: Hashable {
    case cpu, memory, power
    case gpu(String)
    case disk(String)
    case network(String)
}

struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Resource = .cpu

    var body: some View {
        if let snapshot = model.snapshot {
            HSplitView {
                List(selection: $selected) {
                    ForEach(resources(snapshot), id: \.self) { resource in
                        ResourceRow(resource: resource, snapshot: snapshot).tag(resource)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)

                ScrollView {
                    detail(for: selected, snapshot: snapshot)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 480)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resources(_ snapshot: SystemSnapshot) -> [Resource] {
        var list: [Resource] = [.cpu, .memory]
        list += snapshot.gpus.map { .gpu($0.id) }
        list += snapshot.disks.map { .disk($0.id) }
        list += snapshot.network.filter(\.isPrimary).map { .network($0.id) }
        if snapshot.power.systemWatts != nil || snapshot.power.battery != nil { list.append(.power) }
        return list
    }

    @ViewBuilder
    private func detail(for resource: Resource, snapshot: SystemSnapshot) -> some View {
        switch resource {
        case .cpu: CPUDetail(snapshot: snapshot)
        case .memory: MemoryDetail(snapshot: snapshot)
        case .power: PowerDetail(snapshot: snapshot)
        case let .gpu(id):
            if let gpu = snapshot.gpus.first(where: { $0.id == id }) { GPUDetail(gpu: gpu, snapshot: snapshot) }
        case let .disk(id):
            if let disk = snapshot.disks.first(where: { $0.id == id }) { DiskDetail(disk: disk, snapshot: snapshot) }
        case let .network(id):
            if let link = snapshot.network.first(where: { $0.id == id }) { NetworkDetail(link: link, snapshot: snapshot) }
        }
    }
}

// MARK: - Sidebar rows

private struct ResourceRow: View {
    @Environment(AppModel.self) private var model
    var resource: Resource
    var snapshot: SystemSnapshot

    var body: some View {
        HStack(spacing: 10) {
            sparkline
                .frame(width: 64, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var sparkline: some View {
        switch resource {
        case .cpu: Sparkline(values: model.cpuHistory.values, color: Theme.cpu, maxValue: 1)
        case .memory: Sparkline(values: model.memoryHistory.values, color: Theme.memory, maxValue: 1)
        case .power: Sparkline(values: model.powerHistory.values, color: Theme.power)
        case let .gpu(id): Sparkline(values: model.gpuHistory[id]?.values ?? [], color: Theme.gpu, maxValue: 1)
        case let .disk(id):
            Sparkline(values: zipSum(model.diskReadHistory[id]?.values, model.diskWriteHistory[id]?.values), color: Theme.disk)
        case let .network(id):
            Sparkline(values: zipSum(model.networkInHistory[id]?.values, model.networkOutHistory[id]?.values), color: Theme.network)
        }
    }

    private var title: String {
        switch resource {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .power: "Power"
        case .gpu: "GPU"
        case let .disk(id):
            "Disk \(id.replacingOccurrences(of: "disk", with: ""))"
        case let .network(id):
            snapshot.network.first { $0.id == id }?.displayName ?? id
        }
    }

    private var subtitle: String {
        switch resource {
        case .cpu:
            return Format.percent(snapshot.cpu.usage)
        case .memory:
            let memory = snapshot.memory
            return "\(Format.bytes(memory.used)) / \(Format.bytes(memory.physical)) (\(Format.percent(memory.usedFraction)))"
        case .power:
            let watts = snapshot.power.systemWatts.map(Format.watts) ?? "—"
            let battery = snapshot.power.battery.map { " · \($0.percent)%" } ?? ""
            return watts + battery
        case let .gpu(id):
            guard let gpu = snapshot.gpus.first(where: { $0.id == id }) else { return "" }
            return "\(gpu.name)\n\(Format.percent(gpu.deviceUtilization))"
        case let .disk(id):
            guard let disk = snapshot.disks.first(where: { $0.id == id }) else { return "" }
            return "\(disk.model ?? (disk.isSolidState == true ? "SSD" : "Disk"))\n\(Format.percent(disk.activeFraction)) active"
        case let .network(id):
            guard let link = snapshot.network.first(where: { $0.id == id }) else { return "" }
            return "↓ \(Format.bitsPerSecond(link.receivedBytesPerSecond))  ↑ \(Format.bitsPerSecond(link.sentBytesPerSecond))"
        }
    }

    private func zipSum(_ a: [Double]?, _ b: [Double]?) -> [Double] {
        guard let a, let b else { return a ?? b ?? [] }
        return zip(a, b).map(+)
    }
}

// MARK: - Shared pieces

private struct DetailHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.largeTitle.weight(.semibold))
            Spacer()
            Text(subtitle).font(.title3).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// Lists who is driving a resource right now.
private struct TopContributors: View {
    @Environment(AppModel.self) private var model
    var title: String
    var processes: [ProcessSample]
    var metric: (ProcessSample) -> Double
    var format: (ProcessSample) -> String
    var count = 5

    var body: some View {
        let top = processes.filter { metric($0) > 0 }.sorted { metric($0) > metric($1) }.prefix(count)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if top.isEmpty {
                Text("Nothing notable right now.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(top), id: \.pid) { process in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.icon(for: process, app: model.regularApps[process.pid]))
                        .resizable().frame(width: 16, height: 16)
                    Text(model.displayName(for: process)).lineLimit(1)
                    Spacer()
                    Text(format(process)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - CPU

private struct CPUDetail: View {
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
                GraphPanel(title: "% Utilization over \(Int(AppModel.historyCapacity))s", trailing: "100%",
                           series: [GraphSeries(values: model.cpuHistory.values, color: Theme.cpu)], maxValue: 1, height: 240)
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 24) {
                        Stat(label: "Utilization", value: Format.percent(snapshot.cpu.usage), color: Theme.cpu)
                        Stat(label: "User", value: Format.percent(snapshot.cpu.user))
                        Stat(label: "System", value: Format.percent(snapshot.cpu.system))
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
                            Stat(label: "\(tier.name) cores (\(tier.logicalCPUs))", value: Format.percent(tierUsage(tier.level)))
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

            TopContributors(
                title: "Top CPU right now",
                processes: snapshot.processes,
                metric: \.cpuPercent,
                format: { model.cpuScale.format($0.cpuPercent) }
            )
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
                           maxValue: 1, height: 110)
            }
        }
    }

    private func coreGrid(_ topology: CPUTopology) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(topology.tiers, id: \.level) { tier in
                let cpus = topology.tierForCPU.indices.filter { topology.tierForCPU[$0] == tier.level }
                Text("\(tier.name) cores").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(max(cpus.count, 1), 6)), spacing: 6) {
                    ForEach(cpus, id: \.self) { cpu in
                        GraphView(series: [GraphSeries(values: model.coreHistory[cpu].values, color: Theme.tier(tier.level))],
                                  maxValue: 1, capacity: 120, lineWidth: 1)
                            .frame(height: 56)
                            .overlay(alignment: .topLeading) {
                                Text("\(cpu)").font(.system(size: 9)).foregroundStyle(.secondary).padding(3)
                            }
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                    }
                }
            }
        }
    }
}

// MARK: - Memory

private struct MemoryDetail: View {
    @Environment(AppModel.self) private var model
    var snapshot: SystemSnapshot

    var body: some View {
        let memory = snapshot.memory
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Memory", subtitle: Format.bytes(memory.physical))
            GraphPanel(title: "Memory used", trailing: Format.bytes(memory.physical),
                       series: [GraphSeries(values: model.memoryHistory.values, color: Theme.memory)], maxValue: 1, height: 200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Composition").font(.caption).foregroundStyle(.secondary)
                StackedBar(segments: segments(memory), total: Double(memory.physical))
                HStack(spacing: 14) {
                    ForEach(segments(memory)) { segment in
                        HStack(spacing: 4) {
                            Circle().fill(segment.color).frame(width: 8, height: 8)
                            Text("\(segment.label) \(Format.bytes(segment.value))").font(.caption).monospacedDigit()
                        }
                    }
                }
            }

            HStack(spacing: 24) {
                Stat(label: "In use", value: Format.bytes(memory.used), color: Theme.memory)
                Stat(label: "Available", value: Format.bytes(memory.free + memory.cached))
                Stat(label: "Compressed", value: Format.bytes(memory.compressed))
                Stat(label: "Swap used", value: Format.bytes(memory.swapUsed))
            }
            HStack(spacing: 24) {
                Stat(label: "Pressure", value: memory.pressure.rawValue.capitalized, color: pressureColor(memory.pressure))
                if let available = memory.availablePercent {
                    Stat(label: "Kernel says available", value: "\(available)%")
                }
                Stat(label: "Page-ins", value: String(memory.pageIns))
                Stat(label: "Swap-outs", value: String(memory.swapOuts))
            }

            TopContributors(
                title: "Top memory right now",
                processes: snapshot.processes,
                metric: { Double($0.memory) },
                format: { Format.bytes($0.memory) }
            )
        }
    }

    private func segments(_ memory: MemorySample) -> [StackedBar.Segment] {
        [
            .init(label: "App", value: Double(memory.app), color: Theme.memory),
            .init(label: "Wired", value: Double(memory.wired), color: .pink),
            .init(label: "Compressed", value: Double(memory.compressed), color: .orange),
            .init(label: "Cached", value: Double(memory.cached), color: .teal.opacity(0.7)),
        ]
    }

    private func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

// MARK: - GPU

private struct GPUDetail: View {
    @Environment(AppModel.self) private var model
    var gpu: GPUSample
    var snapshot: SystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "GPU", subtitle: gpu.name)
            GraphPanel(title: "Device utilization", trailing: "100%",
                       series: [GraphSeries(values: model.gpuHistory[gpu.id]?.values ?? [], color: Theme.gpu)], maxValue: 1, height: 220)
            HStack(spacing: 24) {
                Stat(label: "Utilization", value: Format.percent(gpu.deviceUtilization), color: Theme.gpu)
                if let renderer = gpu.rendererUtilization { Stat(label: "Renderer", value: Format.percent(renderer)) }
                if let tiler = gpu.tilerUtilization { Stat(label: "Tiler", value: Format.percent(tiler)) }
                if let cores = gpu.coreCount { Stat(label: "Cores", value: String(cores)) }
                if let memory = gpu.memoryInUse { Stat(label: "Memory in use", value: Format.bytes(memory)) }
            }
            TopContributors(
                title: "Top GPU right now",
                processes: snapshot.processes,
                metric: { $0.gpuFraction ?? 0 },
                format: { Format.percent($0.gpuFraction ?? 0, digits: 1) }
            )
        }
    }
}

// MARK: - Disk

private struct DiskDetail: View {
    @Environment(AppModel.self) private var model
    var disk: DiskSample
    var snapshot: SystemSnapshot

    var body: some View {
        let reads = model.diskReadHistory[disk.id]?.values ?? []
        let writes = model.diskWriteHistory[disk.id]?.values ?? []
        let scale = GraphView.niceCeiling(max(reads.max() ?? 0, writes.max() ?? 0))
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Disk \(disk.bsdName.replacingOccurrences(of: "disk", with: ""))", subtitle: disk.model ?? disk.bsdName)
            GraphPanel(title: "Transfer rate (read solid, write dashed)", trailing: Format.bytesPerSecond(scale),
                       series: [
                           GraphSeries(values: reads, color: Theme.disk),
                           GraphSeries(values: writes, color: Theme.diskSecondary, fill: false, dashed: true),
                       ],
                       maxValue: scale, height: 220)
            HStack(spacing: 24) {
                Stat(label: "Read", value: Format.bytesPerSecond(disk.readBytesPerSecond), color: Theme.disk)
                Stat(label: "Write", value: Format.bytesPerSecond(disk.writeBytesPerSecond), color: Theme.diskSecondary)
                Stat(label: "Active time", value: Format.percent(disk.activeFraction))
                Stat(label: "IOPS", value: Format.fixed(disk.readOperationsPerSecond + disk.writeOperationsPerSecond, 0))
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if let size = disk.size { FactRow(label: "Capacity", value: Format.bytes(size)) }
                FactRow(label: "Type", value: disk.isSolidState == true ? "SSD" : disk.isSolidState == false ? "Rotational" : "Unknown")
                if let isInternal = disk.isInternal { FactRow(label: "Location", value: isInternal ? "Internal" : "External") }
                FactRow(label: "Read since boot", value: Format.bytes(disk.totalRead))
                FactRow(label: "Written since boot", value: Format.bytes(disk.totalWritten))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Volumes").font(.headline)
                ForEach(snapshot.volumes) { volume in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(volume.name)
                            Spacer()
                            Text("\(Format.bytes(volume.availableBytes)) free of \(Format.bytes(volume.totalBytes))")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                        let used = Double(volume.usedBytes) / Double(max(volume.totalBytes, 1))
                        ProgressView(value: used).tint(Theme.pressure(used))
                    }
                }
            }

            TopContributors(
                title: "Top disk I/O right now",
                processes: snapshot.processes,
                metric: { $0.diskReadRate + $0.diskWriteRate },
                format: { Format.bytesPerSecond($0.diskReadRate + $0.diskWriteRate) }
            )
        }
    }
}

// MARK: - Network

private struct NetworkDetail: View {
    @Environment(AppModel.self) private var model
    var link: NetworkInterfaceSample
    var snapshot: SystemSnapshot

    var body: some View {
        let received = model.networkInHistory[link.id]?.values ?? []
        let sent = model.networkOutHistory[link.id]?.values ?? []
        let scale = GraphView.niceCeiling(max(received.max() ?? 0, sent.max() ?? 0))
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: link.displayName, subtitle: link.name)
            GraphPanel(title: "Throughput (receive solid, send dashed)", trailing: Format.bitsPerSecond(scale),
                       series: [
                           GraphSeries(values: received, color: Theme.network),
                           GraphSeries(values: sent, color: Theme.networkSecondary, fill: false, dashed: true),
                       ],
                       maxValue: scale, height: 220)
            HStack(spacing: 24) {
                Stat(label: "Receive", value: Format.bitsPerSecond(link.receivedBytesPerSecond), color: Theme.network)
                Stat(label: "Send", value: Format.bitsPerSecond(link.sentBytesPerSecond), color: Theme.networkSecondary)
                Stat(label: "Received", value: Format.bytes(link.totalReceived))
                Stat(label: "Sent", value: Format.bytes(link.totalSent))
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                FactRow(label: "Connection", value: link.kind.rawValue.capitalized)
                if let speed = link.linkSpeed { FactRow(label: "Link speed", value: Format.bitsPerSecond(Double(speed) / 8)) }
                ForEach(link.addresses, id: \.self) { address in
                    FactRow(label: address.contains(":") ? "IPv6" : "IPv4", value: address)
                }
            }
        }
    }
}

// MARK: - Power

private struct PowerDetail: View {
    @Environment(AppModel.self) private var model
    var snapshot: SystemSnapshot

    var body: some View {
        let power = snapshot.power
        let history = model.powerHistory.values
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Power", subtitle: power.battery == nil ? "AC power" : "Battery")
            if power.systemWatts != nil {
                GraphPanel(title: "Whole-system power draw", trailing: Format.watts(GraphView.niceCeiling(history.max() ?? 0)),
                           series: [GraphSeries(values: history, color: Theme.power)], maxValue: nil, height: 200)
            }
            HStack(spacing: 24) {
                if let watts = power.systemWatts { Stat(label: "System power", value: Format.watts(watts), color: Theme.power) }
                Stat(label: "Thermal state", value: power.thermalState.rawValue.capitalized)
                Stat(label: "Low Power Mode", value: power.isLowPowerMode ? "On" : "Off")
            }
            if let battery = power.battery {
                HStack(spacing: 24) {
                    Stat(label: "Battery", value: "\(battery.percent)%")
                    Stat(label: "State", value: battery.isCharging ? "Charging" : battery.isPluggedIn ? "Plugged in" : "On battery")
                    if let minutes = battery.minutesRemaining {
                        Stat(label: battery.isCharging ? "Until full" : "Remaining", value: Format.duration(Double(minutes) * 60))
                    }
                }
                HStack(spacing: 24) {
                    if let health = battery.health { Stat(label: "Health", value: Format.percent(health)) }
                    if let cycles = battery.cycleCount { Stat(label: "Cycles", value: String(cycles)) }
                    if let temperature = battery.temperatureCelsius { Stat(label: "Temperature", value: Format.fixed(temperature, 1) + " °C") }
                }
            }
            TopContributors(
                title: "Top energy right now",
                processes: snapshot.processes,
                metric: { $0.powerWatts ?? 0 },
                format: { Format.watts($0.powerWatts ?? 0) }
            )
        }
    }
}
