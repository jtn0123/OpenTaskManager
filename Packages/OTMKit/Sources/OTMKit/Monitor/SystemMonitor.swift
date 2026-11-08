import Foundation

/// Owns every sampler and produces one `SystemSnapshot` per call to `sample()`.
/// Rates (CPU %, bytes/s, watts) are measured between consecutive calls, so
/// call it on a steady interval.
public actor SystemMonitor {
    public struct Options: Sendable {
        /// Sample processes at all. A menu-bar-only view can turn this off.
        public var includeProcesses = true
        /// Fill in root and other users' processes from `ps`.
        public var includeRestrictedProcesses = true
        /// Attribute GPU time to processes (walks the IORegistry each tick).
        public var includeProcessGPU = true
        /// Per-component power, CPU cluster clocks and GPU clocks from
        /// IOReport. Costs about 6 ms of CPU per sample on an M5 Pro, most of
        /// it the power manager driver's kernel work.
        public var includeComponentPower = true

        public init() {}
    }

    public nonisolated let topology: CPUTopology
    public var options: Options

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let disks = DiskSampler()
    private let network = NetworkSampler()
    private let gpu = GPUSampler()
    private let power: PowerSampler
    private let processes = ProcessSampler()
    private var lastSample: ContinuousClock.Instant?
    private var volumes: [VolumeInfo] = []
    private var volumesRead = Date.distantPast

    public init(options: Options = Options()) {
        let clusterTypes = CPUTopologyReader.deviceTreeClusterTypes()
        let topology = CPUTopologyReader.read(clusterTypes: clusterTypes)
        self.topology = topology
        power = PowerSampler(
            topology: topology,
            levelForClusterType: CPUTopologyReader.levels(forClusterTypes: clusterTypes, tierCount: topology.tiers.count) ?? [:]
        )
        self.options = options
    }

    public func setOptions(_ options: Options) {
        self.options = options
    }

    public func sample(restrictedProcessesLive: Bool = true) -> SystemSnapshot {
        let now = ContinuousClock.now
        let interval = lastSample.map { Self.seconds(now - $0) } ?? 0
        lastSample = now

        let gpuResult = gpu.sample(includeProcesses: options.includeProcesses && options.includeProcessGPU)
        let powerResult = power.sample(includeComponents: options.includeComponentPower)
        processes.includeRestricted = options.includeRestrictedProcesses
        let processList = options.includeProcesses
            ? processes.sample(interval: interval, gpuTime: gpuResult.processGPUTime, restrictedLive: restrictedProcessesLive)
            : []

        // Volume capacity changes slowly and querying it can touch the disk.
        if Date().timeIntervalSince(volumesRead) > 10 {
            volumes = VolumeReader.read()
            volumesRead = Date()
        }

        return SystemSnapshot(
            timestamp: Date(),
            interval: interval,
            uptime: Self.uptime(),
            cpu: cpu.sample(),
            memory: memory.sample(interval: interval),
            disks: disks.sample(interval: interval),
            volumes: volumes,
            network: network.sample(interval: interval),
            gpus: GPUActivity.merge(gpuResult.gpus, powerResult.gpus),
            power: powerResult.power,
            processes: processList
        )
    }

    /// Takes a baseline, waits, and returns the second sample: what one-shot
    /// callers like the CLI need to get meaningful rates.
    public func measuredSample(over duration: Duration = .seconds(1)) async throws -> SystemSnapshot {
        _ = sample()
        try await Task.sleep(for: duration)
        return sample()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func uptime() -> TimeInterval {
        guard let boot = Sysctl.value("kern.boottime", as: timeval.self) else {
            return ProcessInfo.processInfo.systemUptime
        }
        let bootDate = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - bootDate
    }
}
