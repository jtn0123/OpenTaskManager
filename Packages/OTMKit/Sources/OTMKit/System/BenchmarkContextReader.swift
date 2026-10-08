import Foundation
import IOKit.ps

/// Reads a `BenchmarkContext` as a test starts, and its thermal state again as it ends.
public enum BenchmarkContextReader {
    /// How long `otm`, or an app whose sampler isn't running, watches the
    /// CPU's tick counters before a test.
    public static let probeSeconds = 1.0

    /// This Mac's state now. `cpuLoad` is the app's own sampler's recent
    /// figure; without one the CPU's tick counters are read twice,
    /// `probeSeconds` apart, which blocks the calling thread that long.
    public static func atStart(appVersion: String, optimized: Bool = CPUBenchmark.isOptimizedBuild, cpuLoad: BenchmarkCPULoad? = nil,
                               probeSeconds: Double = probeSeconds) -> BenchmarkContext {
        let process = ProcessInfo.processInfo
        let memory = MemorySampler().sample(interval: 1)
        return BenchmarkContext(
            osVersion: CPUBenchmark.osVersion, appVersion: appVersion, optimized: optimized, model: Sysctl.string("hw.model"),
            chip: CPUTopologyReader.read(clusterTypes: [:]).brand, power: powerSource(), hasBattery: hasBattery(),
            lowPowerMode: process.isLowPowerModeEnabled, thermalAtStart: ThermalState(process.thermalState),
            cpuLoad: cpuLoad ?? probe(seconds: probeSeconds),
            availableMemoryBytes: memory.physical > 0 ? memory.free + memory.cached : nil,
            physicalMemoryBytes: memory.physical > 0 ? memory.physical : nil
        )
    }

    /// `atStart` for the app: without its sampler's load the tick counters
    /// are read `probeSeconds` apart with the caller suspended, not blocked.
    public static func capture(appVersion: String, optimized: Bool = CPUBenchmark.isOptimizedBuild, cpuLoad: BenchmarkCPULoad? = nil,
                               probeSeconds: Double = probeSeconds) async -> BenchmarkContext {
        let load: BenchmarkCPULoad?
        if let cpuLoad {
            load = cpuLoad
        } else {
            load = await probeAsync(seconds: probeSeconds)
        }
        return atStart(appVersion: appVersion, optimized: optimized, cpuLoad: load, probeSeconds: 0)
    }

    /// `probe(seconds:)` with the caller suspended between the two reads.
    public static func probeAsync(seconds: Double = probeSeconds) async -> BenchmarkCPULoad? {
        guard seconds > 0 else { return nil }
        let sampler = CPUSampler()
        _ = sampler.sample()
        let started = BenchmarkClock.now
        try? await Task.sleep(for: .seconds(seconds))
        let busy = sampler.sample().usage
        guard busy.isFinite else { return nil }
        return BenchmarkCPULoad(busy: min(max(busy, 0), 1), seconds: BenchmarkClock.seconds(since: started), source: .probe)
    }

    /// The thermal state as the test ends.
    public static func thermalNow() -> ThermalState {
        ThermalState(ProcessInfo.processInfo.thermalState)
    }

    /// How busy the whole CPU was over the next `seconds`: the tick
    /// counters read, then read again.
    public static func probe(seconds: Double = probeSeconds) -> BenchmarkCPULoad? {
        guard seconds > 0 else { return nil }
        let sampler = CPUSampler()
        _ = sampler.sample()
        let started = BenchmarkClock.now
        Thread.sleep(forTimeInterval: seconds)
        let busy = sampler.sample().usage
        guard busy.isFinite else { return nil }
        return BenchmarkCPULoad(busy: min(max(busy, 0), 1), seconds: BenchmarkClock.seconds(since: started), source: .probe)
    }

    /// What's powering the Mac, as IOPowerSources reports it.
    public static func powerSource() -> BenchmarkPowerSource? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        return powerSource(type)
    }

    /// `kIOPMACPowerKey` ("AC Power"), `kIOPMBatteryPowerKey`, `kIOPMUPSPowerKey`.
    static func powerSource(_ type: String) -> BenchmarkPowerSource? {
        switch type {
        case kIOPMACPowerKey: .ac
        case kIOPMBatteryPowerKey: .battery
        case kIOPMUPSPowerKey: .ups
        default: nil
        }
    }

    /// Whether the Mac has an internal battery.
    public static func hasBattery() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}

public extension BenchmarkContext {
    /// This context with the thermal state as the test ended.
    func ended(thermal: ThermalState = BenchmarkContextReader.thermalNow()) -> Self {
        var context = self
        context.thermalAtEnd = thermal
        return context
    }
}
