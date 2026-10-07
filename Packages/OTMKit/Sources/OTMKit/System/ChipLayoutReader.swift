import Foundation
import IOKit

/// Reads the `ChipLayout`: core types and caches from the kernel's
/// `hw.perflevelN` keys, clusters from the device tree, the GPU's and Neural
/// Engine's core counts from the I/O Registry, and the memory type from
/// system_profiler. Without the memory type it takes a millisecond or two;
/// system_profiler can take a second, so ask it off the main actor. Either
/// way, read it once, never per tick.
public enum ChipLayoutReader {
    /// What each reading comes from, for a footnote.
    public static let sources = "Core types and caches from sysctl (hw.perflevelN), clusters from the device tree, "
        + "GPU and Neural Engine from the I/O Registry, memory type from system_profiler. "
        + "macOS doesn't report memory bandwidth."

    /// The layout of this Mac's chip, its core types numbered as in
    /// `topology`; the memory type only when `memoryType` is set.
    public static func read(topology: CPUTopology, memoryType includesMemoryType: Bool = true) -> ChipLayout {
        let types = coreTypes(topology: topology)
        let cpus = deviceTreeCPUs()
        var clusterTypes: [Int: String] = [:]
        for cpu in cpus { if let type = cpu.type { clusterTypes[cpu.cpu] = type } }
        let levels = CPUTopologyReader.levels(forClusterTypes: clusterTypes, tierCount: types.count) ?? [:]
        return ChipLayout(
            chip: topology.brand,
            model: Sysctl.string("hw.model"),
            architecture: topology.architecture,
            coreTypes: types,
            clusters: ChipLayout.clusters(from: cpus, coreTypes: types, levelForType: levels),
            l3Bytes: topology.l3CacheBytes,
            cacheLineBytes: Sysctl.int("hw.cachelinesize"),
            gpus: gpus(),
            neuralEngine: neuralEngine(),
            memoryBytes: UInt64(Sysctl.int("hw.memsize") ?? 0),
            memoryType: includesMemoryType ? memoryType() : nil
        )
    }

    /// `read(topology:)` with the topology read here, for the command line.
    public static func read() -> ChipLayout {
        read(topology: CPUTopologyReader.read())
    }

    /// Each `hw.perflevelN`. A Mac without them (Intel) has one kind of core,
    /// described by the machine-wide cache keys.
    static func coreTypes(topology: CPUTopology) -> [ChipLayout.CoreType] {
        let count = Sysctl.int("hw.nperflevels") ?? 0
        let types: [ChipLayout.CoreType] = (0..<max(count, 0)).compactMap { level in
            let prefix = "hw.perflevel\(level)"
            guard let logical = Sysctl.int("\(prefix).logicalcpu") else { return nil }
            return ChipLayout.CoreType(
                level: level,
                name: Sysctl.string("\(prefix).name") ?? topology.tier(level: level)?.name ?? "Level \(level)",
                physicalCores: Sysctl.int("\(prefix).physicalcpu") ?? logical,
                logicalCores: logical,
                l1InstructionBytes: Sysctl.int("\(prefix).l1icachesize"),
                l1DataBytes: Sysctl.int("\(prefix).l1dcachesize"),
                l2Bytes: Sysctl.int("\(prefix).l2cachesize"),
                coresPerL2: Sysctl.int("\(prefix).cpusperl2")
            )
        }
        guard types.isEmpty else { return types }
        return [ChipLayout.CoreType(
            level: 0, name: topology.tiers.first?.name ?? "Core", physicalCores: topology.physicalCores,
            logicalCores: topology.logicalCores, l1InstructionBytes: topology.l1InstructionCacheBytes,
            l1DataBytes: topology.l1DataCacheBytes, l2Bytes: topology.l2CacheBytes, coresPerL2: nil
        )]
    }

    /// Each CPU's logical number, cluster and cluster type, from the device tree.
    static func deviceTreeCPUs() -> [ChipLayout.DeviceTreeCPU] {
        guard let node = IORegistry.entry(path: "IODeviceTree:/cpus") else { return [] }
        defer { IOObjectRelease(node) }
        var cpus: [ChipLayout.DeviceTreeCPU] = []
        IORegistry.forEachChild(of: node, plane: "IODeviceTree") { cpu in
            let properties = IORegistry.properties(of: cpu)
            guard let id = CPUTopologyReader.logicalID(properties["logical-cpu-id"]) else { return }
            let type = properties.string("cluster-type").flatMap { $0.isEmpty ? nil : $0 }
            cpus.append(.init(cpu: id, cluster: CPUTopologyReader.logicalID(properties["logical-cluster-id"]), type: type))
        }
        return cpus.sorted { $0.cpu < $1.cpu }
    }

    /// Each GPU's name and, where its driver gives it, core count.
    static func gpus() -> [ChipLayout.Engine] {
        var gpus: [ChipLayout.Engine] = []
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            let properties = IORegistry.properties(of: accelerator)
            gpus.append(.init(name: properties.string("model") ?? GPUSampler.parentModel(of: accelerator) ?? "GPU",
                              cores: properties.int("gpu-core-count")))
        }
        return gpus
    }

    /// The Neural Engine's driver and its core count, or nil where the
    /// registry has no Neural Engine (Intel Macs, virtual machines).
    static func neuralEngine() -> ChipLayout.Engine? {
        var engine: ChipLayout.Engine?
        IORegistry.forEachService(matching: "H11ANEIn") { service in
            guard engine == nil else { return }
            let device = IORegistry.properties(of: service).dictionary("DeviceProperties")
            engine = ChipLayout.Engine(name: "Neural Engine", cores: device?.int("ANEDevicePropertyNumANECores"))
        }
        return engine
    }

    /// "LPDDR5", from system_profiler, which this waits for.
    public static func memoryType() -> String? {
        guard let result = CommandRunner.execute("/usr/sbin/system_profiler", ["SPMemoryDataType", "-json"], capture: .output, timeout: 5),
              result.status == 0 else { return nil }
        return ChipLayout.memoryType(fromSystemProfiler: Data(result.text.utf8))
    }
}
