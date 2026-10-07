import Foundation

// The pure half of the IOReport power layer: everything here works on plain
// values so the tests can feed it channel readings captured on real Macs.

// MARK: - Channel names

/// An IOReport CPU cluster channel such as "PCPU", "MCPU1" or "ECPU0". The
/// leading letter is the cluster type the device tree gives each CPU of the
/// cluster; the digits number clusters of the same type.
struct CPUClusterChannel: Equatable {
    let type: String
    let index: Int

    init?(_ name: String) {
        let characters = Array(name)
        guard characters.count >= 4, characters[0].isASCII, characters[0].isUppercase,
              String(characters[1...3]) == "CPU" else { return nil }
        let digits = characters[4...]
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        type = String(characters[0])
        index = digits.isEmpty ? 0 : Int(String(digits)) ?? 0
    }
}

/// How an "Energy Model" channel counts toward the component totals. On an
/// M5 Pro the group also has per-core, SRAM and fabric channels; those are
/// already inside the totals below and are ignored.
enum EnergyChannelRole: Equatable {
    /// "CPU Energy": all CPU clusters together.
    case cpuTotal
    /// "PCPU", "MCPU0": one CPU cluster.
    case cluster(String)
    /// "GPU Energy", published by the GPU driver itself.
    case gpuDriver
    /// "GPU0", the power manager's figure for the GPU.
    case gpuPowerManager
    /// "ANE0"
    case ane
    /// "DRAM0"
    case dram

    init?(channel name: String) {
        switch name {
        case "CPU Energy": self = .cpuTotal
        case "GPU Energy": self = .gpuDriver
        case _ where CPUClusterChannel(name) != nil: self = .cluster(name)
        case _ where Self.isNumbered(name, prefix: "GPU"): self = .gpuPowerManager
        case _ where Self.isNumbered(name, prefix: "ANE"): self = .ane
        case _ where Self.isNumbered(name, prefix: "DRAM"): self = .dram
        default: return nil
        }
    }

    /// "ANE", "ANE0", "ANE12", but not "ANE_SRAM".
    private static func isNumbered(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber }
    }
}

enum EnergyUnit {
    /// Joules per counter unit for an IOReport unit label.
    static func joulesPerUnit(_ label: String) -> Double? {
        switch label.trimmingCharacters(in: .whitespaces) {
        case "J": 1
        case "mJ": 1e-3
        case "uJ", "\u{00B5}J", "\u{03BC}J": 1e-6
        case "nJ": 1e-9
        case "pJ": 1e-12
        default: nil
        }
    }
}

// MARK: - Clusters

/// A CPU cluster's place in the topology and its display name.
struct ClusterSlot: Equatable {
    let channel: String
    let tierLevel: Int?
    let name: String

    /// Names clusters after their tier ("Super 0", "Performance 1") and orders
    /// them by tier level, then by the channel's index. A cluster type the
    /// topology doesn't know keeps its channel name and sorts last.
    static func layout(channels: [String], tiers: [CPUTopology.Tier], levelForClusterType: [String: Int]) -> [ClusterSlot] {
        let parsed = Set(channels).compactMap { name in CPUClusterChannel(name).map { (name, $0) } }
        let sorted = parsed.sorted { lhs, rhs in
            let left = levelForClusterType[lhs.1.type] ?? Int.max
            let right = levelForClusterType[rhs.1.type] ?? Int.max
            if left != right { return left < right }
            if lhs.1.type != rhs.1.type { return lhs.1.type < rhs.1.type }
            return lhs.1.index < rhs.1.index
        }
        var ordinals: [Int: Int] = [:]
        return sorted.map { channel, cluster in
            guard let level = levelForClusterType[cluster.type],
                  let tier = tiers.first(where: { $0.level == level }) else {
                return ClusterSlot(channel: channel, tierLevel: nil, name: channel)
            }
            let ordinal = ordinals[level, default: 0]
            ordinals[level] = ordinal + 1
            return ClusterSlot(channel: channel, tierLevel: level, name: "\(tier.name) \(ordinal)")
        }
    }
}

// MARK: - Residency

enum Residency {
    /// States in which a cluster or GPU is not running.
    static let inactiveStates: Set<String> = ["OFF", "IDLE", "DOWN"]
    /// Share of active time that may fall in states without a known clock
    /// before the average frequency is withheld.
    static let unmappedTolerance = 0.01

    struct Summary: Equatable {
        var activeFraction: Double?
        var frequencyMHz: Double?
    }

    /// Active share of the interval, and the residency-weighted clock over
    /// the active states. The clock is nil when nothing ran or when more than
    /// `unmappedTolerance` of the active time has no known frequency.
    static func summarize(_ states: [IOReportChannel.State], frequencyMHz: (String) -> Double?) -> Summary {
        var total = 0.0, active = 0.0, mapped = 0.0, weighted = 0.0
        for state in states where state.residency > 0 {
            let residency = Double(state.residency)
            total += residency
            guard !inactiveStates.contains(state.name) else { continue }
            active += residency
            if let megahertz = frequencyMHz(state.name), megahertz > 0 {
                mapped += residency
                weighted += residency * megahertz
            }
        }
        guard total > 0 else { return Summary() }
        var summary = Summary(activeFraction: active / total)
        if active > 0, mapped > 0, active - mapped <= active * unmappedTolerance {
            summary.frequencyMHz = weighted / mapped
        }
        return summary
    }

    /// "V12P7" names voltage step 12; CPU clusters have one table entry per step.
    static func cpuStateIndex(_ name: String) -> Int? {
        guard name.first == "V", let separator = name.firstIndex(of: "P") else { return nil }
        let digits = name[name.index(after: name.startIndex)..<separator]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// "P13" is GPU performance state 13, which uses entry 13 of the GPU's table
    /// (entry 0 is the powered-off state).
    static func gpuStateIndex(_ name: String) -> Int? {
        guard name.first == "P" else { return nil }
        let digits = name.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}

// MARK: - Frequency tables

/// Clock tables from the device tree.
enum FrequencyTable {
    /// Decodes a table of little-endian (frequency, voltage) UInt32 pairs into
    /// MHz, reading at most `limit` pairs. Some tables give hertz and others
    /// kilohertz; a table that is neither, or that isn't ascending, is
    /// rejected so no invented clock is shown. 0 (a powered-off entry) stays 0.
    static func megahertz(from data: Data, limit: Int? = nil) -> [Double]? {
        let pairCount = min(data.count / 8, limit ?? .max)
        guard pairCount > 0 else { return nil }
        let raw: [Double] = (0..<pairCount).map { pair in
            Double(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: pair * 8, as: UInt32.self)) })
        }
        let nonZero = raw.filter { $0 > 0 }
        guard !nonZero.isEmpty, zip(nonZero, nonZero.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        let divisor: Double
        if nonZero.allSatisfy({ (1e8..<1e10).contains($0) }) {
            divisor = 1e6
        } else if nonZero.allSatisfy({ (1e5..<1e7).contains($0) }) {
            divisor = 1e3
        } else {
            return nil
        }
        return raw.map { $0 / divisor }
    }

    /// The pmgr node's `perf-domains`: 28-byte records of a voltage-states
    /// table number (byte 0), 11 bytes this code doesn't use, and a 16-byte
    /// NUL-padded name ("PCPU", "MCPU0", "ANE"). Returns name to table number.
    static func perfDomainTables(_ data: Data) -> [String: Int] {
        let recordSize = 28
        guard data.count >= recordSize, data.count.isMultiple(of: recordSize) else { return [:] }
        var tables: [String: Int] = [:]
        for start in stride(from: 0, to: data.count, by: recordSize) {
            let record = data[data.startIndex + start..<data.startIndex + start + recordSize]
            let name = String(decoding: record.dropFirst(12).prefix { $0 != 0 }, as: UTF8.self)
            if !name.isEmpty, tables[name] == nil { tables[name] = Int(record[record.startIndex]) }
        }
        return tables
    }

    /// The first candidate table that decodes and has one entry per voltage
    /// step. On an M5 Pro the plain `voltage-statesN` tables of the CPU
    /// clusters hold something other than clocks and the `-sram` variants
    /// hold kilohertz.
    static func clusterTable(candidates: [Data], stepCount: Int) -> [Double]? {
        for data in candidates {
            if let table = megahertz(from: data), table.count == stepCount, !table.contains(0) {
                return table
            }
        }
        return nil
    }
}

// MARK: - Energy model health

/// Tracks whether the power manager's energy counters update live. On an M5
/// Pro under macOS 27 they stand still for anything from 30 seconds to 25
/// minutes and then jump by the energy of the whole gap, so most intervals
/// read zero and the rest read a burst. The CPU can't have used no energy
/// while this process was running on it, so a zero CPU reading over a long
/// enough interval means the counters are batched; after a few of those they
/// are ignored for the rest of the session.
struct EnergyModelMonitor {
    static let minimumInterval = 0.25
    static let zeroReadingsBeforeGivingUp = 2

    private(set) var isBatched = false
    /// Whether the last interval's figures were set aside because the
    /// counters aren't live: they read zero over a long enough interval, or
    /// a burst, or were found batched already. A single interval (`otm
    /// power`) can tell this before `isBatched` can.
    private(set) var isStalled = false
    private var zeroReadings = 0

    /// Whether this interval's power-manager figures can be used.
    mutating func accept(cpuJoules: Double?, interval: Double, limitWatts: Double) -> Bool {
        guard let cpuJoules, interval > 0 else {
            isStalled = isBatched
            return false
        }
        guard !isBatched else {
            isStalled = true
            return false
        }
        guard cpuJoules > 0 else {
            isStalled = interval >= Self.minimumInterval
            if isStalled {
                zeroReadings += 1
                isBatched = zeroReadings >= Self.zeroReadingsBeforeGivingUp
            }
            return false
        }
        zeroReadings = 0
        isStalled = cpuJoules / interval > limitWatts
        return !isStalled
    }
}

// MARK: - Analysis

/// What one IOReport interval says about a GPU.
struct GPUActivity: Equatable {
    var activeResidency: Double?
    var frequencyMHz: Double?

    /// Attaches activity to GPUs by registry ID. A Mac with one GPU and one
    /// GPU channel pairs them even if the IDs differ.
    static func merge(_ gpus: [GPUSample], _ activity: [UInt64: Self]) -> [GPUSample] {
        gpus.map { gpu in
            var gpu = gpu
            let match = activity[gpu.registryID] ?? (gpus.count == 1 && activity.count == 1 ? activity.values.first : nil)
            gpu.frequencyMHz = match?.frequencyMHz
            gpu.activeResidency = match?.activeResidency
            return gpu
        }
    }
}

struct SoCPowerResult {
    var components: PowerComponents?
    /// Keyed by the GPU driver's registry ID.
    var gpus: [UInt64: GPUActivity] = [:]
}

/// Turns IOReport channel readings into component power, cluster clocks and
/// GPU residency.
struct SoCPowerAnalyzer {
    static let energyGroup = "Energy Model"
    static let cpuStatesGroup = "CPU Stats"
    static let cpuStatesSubgroup = "CPU Complex Performance States"
    static let gpuStatesGroup = "GPU Stats"
    static let gpuStatesSubgroup = "GPU Performance States"

    let tiers: [CPUTopology.Tier]
    let levelForClusterType: [String: Int]
    /// Raw clock tables for each CPU cluster channel, in order of preference.
    let cpuTableCandidates: [String: [Data]]
    /// MHz per GPU performance state, keyed by the GPU's registry ID.
    let gpuTables: [UInt64: [Double]]
    private(set) var energyModel = EnergyModelMonitor()
    private var cpuTables: [String: [Double]] = [:]

    init(tiers: [CPUTopology.Tier], levelForClusterType: [String: Int], cpuTableCandidates: [String: [Data]], gpuTables: [UInt64: [Double]]) {
        self.tiers = tiers
        self.levelForClusterType = levelForClusterType
        self.cpuTableCandidates = cpuTableCandidates
        self.gpuTables = gpuTables
    }

    /// Whether a channel is worth subscribing to.
    static func wants(group: String, channel: String) -> Bool {
        switch group {
        case energyGroup: EnergyChannelRole(channel: channel) != nil
        case cpuStatesGroup: CPUClusterChannel(channel) != nil
        case gpuStatesGroup: true
        default: false
        }
    }

    /// Readings far above whole-system power are counter bursts, not power.
    static func limitWatts(systemWatts: Double?) -> Double {
        min(PowerSourceSelection.maximumPlausibleWatts, systemWatts.map { $0 * 3 + 30 } ?? .infinity)
    }

    /// - Parameter smcCPUWatts: read only when the energy model can't give the CPU figure.
    mutating func analyze(
        _ channels: [IOReportChannel], interval: Double, systemWatts: Double?, smcCPUWatts: () -> Double?
    ) -> SoCPowerResult {
        guard interval > 0 else { return SoCPowerResult() }
        var energy = EnergySums()
        var clusterStates: [String: [IOReportChannel.State]] = [:]
        var gpuStates: [UInt64: [IOReportChannel.State]] = [:]
        for channel in channels {
            switch (channel.group, channel.value) {
            case (Self.energyGroup, .integer(let count)):
                guard let role = EnergyChannelRole(channel: channel.name),
                      let perUnit = EnergyUnit.joulesPerUnit(channel.unit) else { continue }
                energy.add(role, joules: Double(max(count, 0)) * perUnit)
            case (Self.cpuStatesGroup, .states(let states)) where channel.subgroup == Self.cpuStatesSubgroup:
                if CPUClusterChannel(channel.name) != nil { clusterStates[channel.name] = states }
            case (Self.gpuStatesGroup, .states(let states)) where channel.subgroup == Self.gpuStatesSubgroup:
                gpuStates[channel.driverID, default: []] += states
            default:
                continue
            }
        }

        let limit = Self.limitWatts(systemWatts: systemWatts)
        // Without a "CPU Energy" total, the clusters add up to the CPU.
        let cpuJoules = energy.cpu ?? (energy.clusters.isEmpty ? nil : energy.clusters.values.reduce(0, +))
        let usable = energyModel.accept(cpuJoules: cpuJoules, interval: interval, limitWatts: limit)
        func watts(_ joules: Double?) -> Double? {
            guard let joules else { return nil }
            let value = joules / interval
            return value.isFinite && value >= 0 && value <= limit ? value : nil
        }

        var sources: [PowerComponent: ComponentPowerSource] = [:]
        var cpu = 0.0, gpu = 0.0, ane = 0.0
        var dram: Double?
        if usable, let value = watts(cpuJoules) {
            (cpu, sources[.cpu]) = (value, .energyModel)
        } else if let value = smcCPUWatts(), value.isFinite, value >= 0, value <= limit {
            (cpu, sources[.cpu]) = (value, .smc)
        }
        // The GPU driver's own counter updates live even when the power manager's don't.
        if let value = watts(energy.gpuDriver) ?? (usable ? watts(energy.gpuPowerManager) : nil) {
            (gpu, sources[.gpu]) = (value, .energyModel)
        }
        if usable, let value = watts(energy.ane) {
            (ane, sources[.ane]) = (value, .energyModel)
        }
        if usable, let value = watts(energy.dram) {
            (dram, sources[.dram]) = (value, .energyModel)
        }

        let slots = ClusterSlot.layout(
            channels: Array(clusterStates.keys) + Array(energy.clusters.keys), tiers: tiers, levelForClusterType: levelForClusterType
        )
        let clusters = slots.map { slot in
            let summary = clusterStates[slot.channel].map { states in
                let table = cpuTable(for: slot.channel, states: states)
                return Residency.summarize(states) { name in
                    Residency.cpuStateIndex(name).flatMap { table?.indices.contains($0) == true ? table?[$0] : nil }
                }
            } ?? Residency.Summary()
            return ClusterPower(
                name: slot.name, tierLevel: slot.tierLevel,
                watts: usable ? watts(energy.clusters[slot.channel]) : nil,
                frequencyMHz: summary.frequencyMHz, activeFraction: summary.activeFraction, channel: slot.channel
            )
        }

        var gpus: [UInt64: GPUActivity] = [:]
        for (driverID, states) in gpuStates {
            let table = gpuTables[driverID] ?? (gpuTables.count == 1 && gpuStates.count == 1 ? gpuTables.values.first : nil)
            let summary = Residency.summarize(states) { name in
                Residency.gpuStateIndex(name).flatMap { table?.indices.contains($0) == true ? table?[$0] : nil }
            }
            gpus[driverID] = GPUActivity(activeResidency: summary.activeFraction, frequencyMHz: summary.frequencyMHz)
        }

        let components = sources.isEmpty && clusters.isEmpty
            ? nil
            : PowerComponents(cpu: cpu, gpu: gpu, ane: ane, dram: dram, clusters: clusters, sources: sources,
                              energyCountersStalled: energyModel.isStalled)
        return SoCPowerResult(components: components, gpus: gpus)
    }

    /// The cluster's clock table, decoded once its number of voltage steps is known.
    private mutating func cpuTable(for channel: String, states: [IOReportChannel.State]) -> [Double]? {
        if let table = cpuTables[channel] { return table }
        let steps = states.filter { Residency.cpuStateIndex($0.name) != nil }.count
        guard let table = FrequencyTable.clusterTable(candidates: cpuTableCandidates[channel] ?? [], stepCount: steps) else {
            return nil
        }
        cpuTables[channel] = table
        return table
    }
}

/// Joules per role over one interval; nil where the Mac has no such channel.
private struct EnergySums {
    var cpu: Double?
    var clusters: [String: Double] = [:]
    var gpuDriver: Double?
    var gpuPowerManager: Double?
    var ane: Double?
    var dram: Double?

    mutating func add(_ role: EnergyChannelRole, joules: Double) {
        switch role {
        case .cpuTotal: cpu = (cpu ?? 0) + joules
        case .cluster(let name): clusters[name, default: 0] += joules
        case .gpuDriver: gpuDriver = (gpuDriver ?? 0) + joules
        case .gpuPowerManager: gpuPowerManager = (gpuPowerManager ?? 0) + joules
        case .ane: ane = (ane ?? 0) + joules
        case .dram: dram = (dram ?? 0) + joules
        }
    }
}
