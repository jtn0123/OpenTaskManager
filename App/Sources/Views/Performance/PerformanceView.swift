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
    @State private var opened = false

    var body: some View {
        if let snapshot = model.snapshot {
            HSplitView {
                List(selection: $selected) {
                    ForEach(resources(snapshot), id: \.self) { resource in
                        ResourceRow(resource: resource, snapshot: snapshot).tag(resource)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 270)

                ScrollView {
                    detail(for: selected, snapshot: snapshot)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(LaunchArgument.string("openScroll") == "bottom" ? .bottom : .top)
                .frame(minWidth: 480)
            }
            .onAppear { openRequestedResource(snapshot) }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// `--args -openResource memory` (cpu, memory, gpu, disk, network, power)
    /// picks the first matching resource once, for screenshots. With
    /// `-openScroll bottom` the detail starts scrolled to the end.
    private func openRequestedResource(_ snapshot: SystemSnapshot) {
        guard !opened, let name = LaunchArgument.string("openResource") else { return }
        opened = true
        let match = resources(snapshot).first { resource in
            switch resource {
            case .cpu: name == "cpu"
            case .memory: name == "memory"
            case .power: name == "power"
            case .gpu: name == "gpu"
            case .disk: name == "disk"
            case .network: name == "network"
            }
        }
        if let match { selected = match }
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
