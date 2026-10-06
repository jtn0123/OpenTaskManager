import Darwin
import Foundation

final class CPUSampler {
    private let host = mach_host_self()
    private var previousTicks: [[UInt32]] = []

    func sample() -> CPUSample {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else {
            return .zero
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) })
        }
        defer { previousTicks = ticks }

        var coreUsage: [Double] = []
        var totalUser: UInt64 = 0, totalSystem: UInt64 = 0, totalAll: UInt64 = 0
        let haveBaseline = previousTicks.count == ticks.count
        for (cpu, current) in ticks.enumerated() {
            let before = haveBaseline ? previousTicks[cpu] : [UInt32](repeating: 0, count: states)
            // Tick counters are 32-bit and wrap; wrapping subtraction keeps deltas right.
            let user = UInt64(current[Int(CPU_STATE_USER)] &- before[Int(CPU_STATE_USER)])
            let system = UInt64(current[Int(CPU_STATE_SYSTEM)] &- before[Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(current[Int(CPU_STATE_IDLE)] &- before[Int(CPU_STATE_IDLE)])
            let nice = UInt64(current[Int(CPU_STATE_NICE)] &- before[Int(CPU_STATE_NICE)])
            let all = user + system + idle + nice
            coreUsage.append(all == 0 ? 0 : Double(user + system + nice) / Double(all))
            totalUser += user + nice
            totalSystem += system
            totalAll += all
        }

        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)

        guard totalAll > 0 else {
            return CPUSample(usage: 0, user: 0, system: 0, coreUsage: coreUsage, loadAverage: load)
        }
        let user = Double(totalUser) / Double(totalAll)
        let system = Double(totalSystem) / Double(totalAll)
        return CPUSample(usage: user + system, user: user, system: system, coreUsage: coreUsage, loadAverage: load)
    }
}

enum CPUTopologyReader {
    /// - Parameter clusterTypes: the device tree's cluster type for each logical CPU.
    static func read(clusterTypes: [Int: String] = deviceTreeClusterTypes()) -> CPUTopology {
        let logical = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let physical = Sysctl.int("hw.physicalcpu") ?? logical
        #if arch(x86_64)
        let architecture = Sysctl.int("sysctl.proc_translated") == 1 ? "arm64 (Rosetta)" : "x86_64"
        #else
        let architecture = "arm64"
        #endif
        let isAppleSilicon = Sysctl.int("hw.optional.arm64") == 1

        var tiers: [CPUTopology.Tier] = []
        let levelCount = Sysctl.int("hw.nperflevels") ?? 1
        for level in 0..<max(levelCount, 1) {
            let prefix = "hw.perflevel\(level)"
            guard let tierLogical = Sysctl.int("\(prefix).logicalcpu") else { continue }
            tiers.append(.init(
                level: level,
                name: Sysctl.string("\(prefix).name") ?? (level == 0 ? "Performance" : "Efficiency"),
                logicalCPUs: tierLogical,
                physicalCPUs: Sysctl.int("\(prefix).physicalcpu") ?? tierLogical,
                l2CacheBytes: Sysctl.int("\(prefix).l2cachesize")
            ))
        }
        if tiers.isEmpty {
            tiers = [.init(level: 0, name: "Core", logicalCPUs: logical, physicalCPUs: physical, l2CacheBytes: nil)]
        }

        return CPUTopology(
            brand: Sysctl.string("machdep.cpu.brand_string") ?? "Unknown CPU",
            architecture: architecture,
            physicalCores: physical,
            logicalCores: logical,
            tiers: tiers,
            tierForCPU: tierMap(logical: logical, tiers: tiers, clusterTypes: clusterTypes),
            l1DataCacheBytes: Sysctl.int("hw.l1dcachesize"),
            l1InstructionCacheBytes: Sysctl.int("hw.l1icachesize"),
            l2CacheBytes: Sysctl.int("hw.l2cachesize"),
            l3CacheBytes: Sysctl.int("hw.l3cachesize"),
            isAppleSilicon: isAppleSilicon
        )
    }

    /// Maps each logical CPU to its tier. The device tree labels every CPU
    /// with a cluster type; when that is unavailable we fall back to the
    /// kernel's ordering, which lists the slowest tier's CPUs first.
    private static func tierMap(logical: Int, tiers: [CPUTopology.Tier], clusterTypes: [Int: String]) -> [Int] {
        let fallback: [Int] = tiers.sorted { $0.level > $1.level }.flatMap { tier in
            [Int](repeating: tier.level, count: tier.logicalCPUs)
        }
        guard clusterTypes.count == logical, tiers.count > 1 else {
            return fallback.count == logical ? fallback : [Int](repeating: 0, count: logical)
        }
        guard let levelForType = levels(forClusterTypes: clusterTypes, tierCount: tiers.count) else { return fallback }
        return (0..<logical).map { levelForType[clusterTypes[$0] ?? ""] ?? 0 }
    }

    /// The cluster type ("P", "M", "E") of each logical CPU, from the device tree.
    static func deviceTreeClusterTypes() -> [Int: String] {
        var clusterTypes: [Int: String] = [:]
        guard let cpus = IORegistry.entry(path: "IODeviceTree:/cpus") else { return clusterTypes }
        defer { IOObjectRelease(cpus) }
        IORegistry.forEachChild(of: cpus, plane: "IODeviceTree") { cpu in
            let properties = IORegistry.properties(of: cpu)
            guard let id = logicalID(properties["logical-cpu-id"]),
                  let type = properties.string("cluster-type") else { return }
            clusterTypes[id] = type
        }
        return clusterTypes
    }

    /// The tier level of each cluster type. The kernel numbers CPUs from the
    /// slowest tier up, so the type whose CPUs come last is tier 0. nil when
    /// the number of types doesn't match the number of tiers.
    static func levels(forClusterTypes clusterTypes: [Int: String], tierCount: Int) -> [String: Int]? {
        var firstIndex: [String: Int] = [:]
        for id in clusterTypes.keys.sorted() {
            if let type = clusterTypes[id], firstIndex[type] == nil { firstIndex[type] = id }
        }
        let orderedTypes = firstIndex.sorted { $0.value > $1.value }.map(\.key)
        guard !orderedTypes.isEmpty, orderedTypes.count == tierCount else { return nil }
        return Dictionary(uniqueKeysWithValues: orderedTypes.enumerated().map { ($1, $0) })
    }

    private static func logicalID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data, data.count >= 4 {
            return Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        return nil
    }
}
