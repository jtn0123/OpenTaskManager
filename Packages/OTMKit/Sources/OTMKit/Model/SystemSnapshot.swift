import Foundation

/// Everything the monitor learned in one sampling pass. Rates are computed
/// against the previous pass, so the first snapshot reports zero rates.
public struct SystemSnapshot: Sendable, Codable {
    public let timestamp: Date
    /// Seconds since the previous snapshot (0 for the first one).
    public let interval: TimeInterval
    public let uptime: TimeInterval
    public let cpu: CPUSample
    public let memory: MemorySample
    public let disks: [DiskSample]
    public let volumes: [VolumeInfo]
    public let network: [NetworkInterfaceSample]
    public let gpus: [GPUSample]
    public let power: PowerSample
    public let processes: [ProcessSample]

    public var threadCount: Int { processes.reduce(0) { $0 + $1.threadCount } }

    /// Whether this Mac measures each process's energy use. false in a virtual
    /// machine, whose kernel doesn't count it: rank nothing by energy then,
    /// rather than calling every app idle. nil while it can't tell yet.
    public var measuresProcessEnergy: Bool? {
        ProcessSample.measuresEnergy(processes, interval: interval)
    }

    /// The machine-level part of the snapshot, for callers that do not need the process list.
    public func withoutProcesses() -> SystemSnapshot {
        SystemSnapshot(
            timestamp: timestamp, interval: interval, uptime: uptime, cpu: cpu, memory: memory, disks: disks,
            volumes: volumes, network: network, gpus: gpus, power: power, processes: []
        )
    }
}

// MARK: - CPU

public struct CPUTopology: Sendable, Codable, Hashable {
    /// A performance tier ("Super", "Performance", "Efficiency"). Tier 0 is the
    /// fastest, matching the kernel's `hw.perflevelN` numbering.
    public struct Tier: Sendable, Codable, Hashable {
        public let level: Int
        public let name: String
        public let logicalCPUs: Int
        public let physicalCPUs: Int
        public let l2CacheBytes: Int?
    }

    public let brand: String
    public let architecture: String
    public let physicalCores: Int
    public let logicalCores: Int
    public let tiers: [Tier]
    /// Tier level for each logical CPU, indexed by CPU number.
    public let tierForCPU: [Int]
    public let l1DataCacheBytes: Int?
    public let l1InstructionCacheBytes: Int?
    public let l2CacheBytes: Int?
    public let l3CacheBytes: Int?
    public let isAppleSilicon: Bool

    public func tier(level: Int) -> Tier? {
        tiers.first { $0.level == level }
    }
}

public struct CPUSample: Sendable, Codable {
    /// Busy fraction across all logical CPUs, 0...1.
    public let usage: Double
    public let user: Double
    public let system: Double
    /// Busy fraction per logical CPU, indexed by CPU number.
    public let coreUsage: [Double]
    public let loadAverage: [Double]

    public static let zero = CPUSample(usage: 0, user: 0, system: 0, coreUsage: [], loadAverage: [0, 0, 0])
}

// MARK: - Memory

public enum MemoryPressure: String, Sendable, Codable {
    case normal, warning, critical
}

public struct MemorySample: Sendable, Codable {
    public let physical: UInt64
    /// App + wired + compressed, matching Activity Monitor's "Memory Used".
    public let used: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    /// File-backed and purgeable pages the system can reclaim instantly.
    public let cached: UInt64
    public let free: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let pressure: MemoryPressure
    /// The kernel's own "memory available" percentage (`kern.memorystatus_level`).
    public let availablePercent: Int?
    /// Cumulative page counts since boot.
    public let pageIns: UInt64
    public let pageOuts: UInt64
    public let swapIns: UInt64
    public let swapOuts: UInt64
    /// Bytes per second over the last interval (0 on the first sample).
    public let pageInRate: Double
    public let pageOutRate: Double
    public let swapInRate: Double
    public let swapOutRate: Double
    /// Bytes per second of pages moved into and out of the compressor.
    public let compressionRate: Double
    public let decompressionRate: Double

    public var usedFraction: Double {
        physical == 0 ? 0 : Double(used) / Double(physical)
    }
}

// MARK: - Storage

public struct DiskSample: Sendable, Codable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String
    public let model: String?
    public let isInternal: Bool?
    public let isSolidState: Bool?
    public let size: UInt64?
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    public let readOperationsPerSecond: Double
    public let writeOperationsPerSecond: Double
    public let totalRead: UInt64
    public let totalWritten: UInt64
    /// Share of the interval the device spent servicing I/O, clamped to 0...1.
    public let activeFraction: Double
}

public struct VolumeInfo: Sendable, Codable, Identifiable, Hashable {
    public var id: String { mountPoint }
    public let name: String
    public let mountPoint: String
    public let fileSystem: String?
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isRoot: Bool
    /// BSD name of the physical disk the volume lives on ("disk0"), matching
    /// `DiskSample.bsdName`. Nil for disk images and network shares.
    public let physicalDisk: String?

    public var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
}

// MARK: - Network

public enum NetworkInterfaceKind: String, Sendable, Codable {
    case wifi, ethernet, cellular, vpn, bridge, loopback, other
}

public struct NetworkInterfaceSample: Sendable, Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let kind: NetworkInterfaceKind
    public let isUp: Bool
    public let addresses: [String]
    /// Link speed in bits per second, when the driver reports one.
    public let linkSpeed: UInt64?
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double
    public let totalReceived: UInt64
    public let totalSent: UInt64

    /// Interfaces worth showing by default: real links that are up.
    public var isPrimary: Bool {
        isUp && (kind == .wifi || kind == .ethernet || kind == .cellular)
            && (!addresses.isEmpty || totalReceived > 0)
    }
}

// MARK: - GPU

public struct GPUSample: Sendable, Codable, Identifiable {
    public var id: String { name + String(registryID) }
    public let registryID: UInt64
    public let name: String
    public let coreCount: Int?
    /// Busy fraction of the whole GPU, 0...1. nil when the driver doesn't
    /// report it (a virtual machine's paravirtual GPU): show that as unknown,
    /// never as 0%.
    public let deviceUtilization: Double?
    public let rendererUtilization: Double?
    public let tilerUtilization: Double?
    public let memoryInUse: UInt64?
    public let memoryAllocated: UInt64?
    /// Residency-weighted average clock while the GPU was powered on, from
    /// IOReport. nil when the GPU stayed off, IOReport is unavailable, or the
    /// clock of a state it used can't be read from the device tree.
    public var frequencyMHz: Double?
    /// Share of the interval the GPU spent in a powered-on performance state.
    public var activeResidency: Double?
}

// MARK: - Power

public enum ThermalState: String, Sendable, Codable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

public struct BatterySample: Sendable, Codable {
    public let percent: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let isFullyCharged: Bool
    public let cycleCount: Int?
    /// Current full-charge capacity as a share of design capacity.
    public let health: Double?
    public let temperatureCelsius: Double?
    /// Minutes until empty (or full when charging), when the system has an estimate.
    public let minutesRemaining: Int?
    public let voltage: Double?
    public let amperage: Double?

    /// Power flowing into the battery: positive while charging, negative while discharging.
    public var watts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }
}

/// Where `PowerSample.systemWatts` came from.
public enum SystemPowerSource: String, Sendable, Codable {
    /// The SMC's whole-system power key (PSTR), refreshed about once a second
    /// and one refresh behind the SMC's other power keys.
    case smcSystemTotal
    /// The battery gauge's `PowerTelemetryData` system load, refreshed roughly once a minute.
    case batteryTelemetry
    /// The SMC's DC-input power key (PDTR). Includes charging power when the battery is charging.
    case smcInput
    /// Battery voltage times discharge current, the last resort on battery power.
    case batteryDischarge
}

/// The connected power adapter and the power flowing through it.
public struct AdapterSample: Sendable, Codable {
    /// The adapter's own name, such as "140W USB-C Power Adapter".
    public let name: String?
    public let ratedWatts: Double?
    /// Live power drawn from the adapter.
    public let inputWatts: Double?
    /// Power flowing into the battery: positive while charging, negative while discharging.
    public let batteryWatts: Double?
}

/// A part of the chip whose power IOReport can break out.
public enum PowerComponent: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case cpu, gpu, ane, dram
}

/// Where a component's power figure came from.
public enum ComponentPowerSource: String, Sendable, Codable {
    /// IOReport's "Energy Model" counters: energy used over the interval.
    case energyModel
    /// An SMC power key. Used for the CPU when the energy model's counters
    /// don't update live (an M5 Pro on macOS 27 batches them for minutes).
    case smc
}

/// One CPU cluster: a group of cores of the same tier that share a clock.
public struct ClusterPower: Sendable, Codable, Identifiable, Hashable {
    public var id: String { name }
    /// "Super 0", "Performance 1": the tier name and the cluster's position
    /// within its tier. The IOReport channel name when the tier is unknown.
    public let name: String
    /// The `CPUTopology` tier level the cluster belongs to.
    public let tierLevel: Int?
    /// nil when the energy model can't attribute power to clusters.
    public let watts: Double?
    /// Residency-weighted average clock while the cluster was running. nil
    /// when it stayed idle or its clock table can't be read.
    public let frequencyMHz: Double?
    /// Share of the interval the cluster was running rather than idle or powered down.
    public let activeFraction: Double?
    /// The IOReport channel the figures came from, such as "PCPU" or "MCPU1".
    public let channel: String
}

/// Power broken out by part of the chip, from IOReport.
public struct PowerComponents: Sendable, Codable {
    public let cpu: Double
    public let gpu: Double
    /// Apple Neural Engine.
    public let ane: Double
    public let dram: Double?
    /// Ordered by tier level (fastest first), then by position within the tier.
    public let clusters: [ClusterPower]
    /// Where each component's figure came from. A component missing here
    /// wasn't measured this interval: its figure above is 0 (or nil for
    /// `dram`), and a UI should show it as unknown rather than as 0 W.
    public let sources: [PowerComponent: ComponentPowerSource]
    /// Whether the power manager's energy counters gave no live figure this
    /// interval: they stood still, or jumped by a burst. An M5 Pro on macOS 27
    /// holds them for minutes, then adds the whole gap at once. The Neural
    /// Engine and DRAM, which only they measure, then go unmeasured, and the
    /// CPU's figure comes from the SMC.
    public var energyCountersStalled = false

    public var total: Double { cpu + gpu + ane + (dram ?? 0) }

    public func isMeasured(_ component: PowerComponent) -> Bool {
        sources[component] != nil
    }

    /// The component's watts, or nil when it wasn't measured.
    public func watts(_ component: PowerComponent) -> Double? {
        guard isMeasured(component) else { return nil }
        switch component {
        case .cpu: return cpu
        case .gpu: return gpu
        case .ane: return ane
        case .dram: return dram
        }
    }
}

public struct PowerSample: Sendable, Codable {
    /// Whole-system power draw in watts, when the hardware reports it.
    public let systemWatts: Double?
    public let battery: BatterySample?
    public let isLowPowerMode: Bool
    public let thermalState: ThermalState
    /// nil when no adapter is connected or the Mac has no battery (desktops).
    public let adapter: AdapterSample?
    /// Which reading `systemWatts` came from.
    public let systemWattsSource: SystemPowerSource?
    /// Per-component power. nil when IOReport is unavailable and on the first
    /// sample, which has no interval to measure over.
    public var components: PowerComponents?
}
