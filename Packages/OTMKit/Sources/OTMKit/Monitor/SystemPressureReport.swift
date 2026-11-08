import Foundation

/// Observations from one sampling interval, never a diagnosis or a health score.
/// Throughput and allocated swap alone cannot establish a bottleneck.
public struct SystemPressureReport: Sendable, Equatable {
    public enum Resource: String, Sendable, CaseIterable, Identifiable {
        case thermal, memory, cpu, busyCore, gpu
        public var id: String { rawValue }
    }

    public struct Finding: Sendable, Equatable, Identifiable {
        public let resource: Resource
        /// A fraction for CPU/GPU, or the named macOS state for pressure.
        public let fraction: Double?
        public let state: String?
        public var id: Resource { resource }
    }

    /// Inputs are separate from the process list so evaluating pressure is
    /// constant work, including while only the menu bar is visible.
    public struct Reading: Sendable {
        public var interval: TimeInterval
        public var cpu: Double
        public var busiestCore: Double?
        public var memory: MemoryPressure
        public var thermal: ThermalState
        public var gpu: Double?

        public init(interval: TimeInterval, cpu: Double, busiestCore: Double? = nil,
                    memory: MemoryPressure = .normal, thermal: ThermalState = .nominal, gpu: Double? = nil) {
            self.interval = interval
            self.cpu = cpu
            self.busiestCore = busiestCore
            self.memory = memory
            self.thermal = thermal
            self.gpu = gpu
        }
    }

    public let isMeasuring: Bool
    public let findings: [Finding]

    public init(_ reading: Reading) {
        isMeasuring = !reading.interval.isFinite || reading.interval <= 0 || reading.interval > 15
        var found: [Finding] = []
        if reading.thermal == .serious || reading.thermal == .critical {
            found.append(Finding(resource: .thermal, fraction: nil, state: reading.thermal.rawValue))
        }
        if reading.memory != .normal {
            found.append(Finding(resource: .memory, fraction: nil, state: reading.memory.rawValue))
        }
        // First samples and gaps have no useful rate baseline. Named states
        // above still describe what macOS currently reports.
        if !isMeasuring {
            if Self.validFraction(reading.cpu), reading.cpu >= 0.85 {
                found.append(Finding(resource: .cpu, fraction: reading.cpu, state: nil))
            } else if let core = reading.busiestCore, Self.validFraction(core), core >= 0.95 {
                found.append(Finding(resource: .busyCore, fraction: core, state: nil))
            }
            if let gpu = reading.gpu, Self.validFraction(gpu), gpu >= 0.9 {
                found.append(Finding(resource: .gpu, fraction: gpu, state: nil))
            }
        }
        findings = found
    }

    public init(_ snapshot: SystemSnapshot) {
        self.init(Reading(interval: snapshot.interval, cpu: snapshot.cpu.usage,
                          busiestCore: snapshot.cpu.coreUsage.filter(Self.validFraction).max(),
                          memory: snapshot.memory.pressure, thermal: snapshot.power.thermalState,
                          gpu: snapshot.gpus.compactMap(\.deviceUtilization).filter(Self.validFraction).max()))
    }

    /// Current users of a resource, not proof that any of them caused a slowdown.
    /// GPU time is per-process accounting, not a share of total GPU utilization.
    public static func topProcesses(for resource: Resource, in processes: [ProcessSample], limit: Int = 3) -> [ProcessSample] {
        guard limit > 0 else { return [] }
        return processes.filter {
            let value = usage(of: $0, for: resource)
            return value.isFinite && value > 0
        }.sorted {
            let left = usage(of: $0, for: resource), right = usage(of: $1, for: resource)
            return left == right ? $0.pid < $1.pid : left > right
        }.prefix(limit).map { $0 }
    }

    private static func usage(of process: ProcessSample, for resource: Resource) -> Double {
        switch resource {
        case .memory: Double(process.memory)
        case .gpu: process.gpuFraction ?? 0
        case .thermal, .cpu, .busyCore: process.cpuPercent
        }
    }

    private static func validFraction(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}
