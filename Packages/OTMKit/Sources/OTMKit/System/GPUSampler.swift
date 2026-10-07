import Foundation
import IOKit

final class GPUSampler {
    struct Result {
        let gpus: [GPUSample]
        /// Cumulative GPU nanoseconds per process, summed across devices.
        let processGPUTime: [Int32: UInt64]
    }

    func sample(includeProcesses: Bool) -> Result {
        var gpus: [GPUSample] = []
        var processTime: [Int32: UInt64] = [:]

        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            let properties = IORegistry.properties(of: accelerator)
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(accelerator, &registryID)

            let stats = properties.dictionary("PerformanceStatistics") ?? [:]
            gpus.append(GPUSample(
                registryID: registryID,
                name: properties.string("model") ?? Self.parentModel(of: accelerator) ?? "GPU",
                coreCount: properties.int("gpu-core-count"),
                deviceUtilization: Self.deviceUtilization(stats),
                rendererUtilization: Self.fraction("Renderer Utilization %", in: stats),
                tilerUtilization: Self.fraction("Tiler Utilization %", in: stats),
                memoryInUse: stats.uint64("In use system memory") ?? stats.uint64("vramUsedBytes"),
                memoryAllocated: stats.uint64("Alloc system memory") ?? stats.uint64("vramFreeBytes")
            ))

            guard includeProcesses else { return }
            // Each Metal/GL client gets a user-client child that records the
            // GPU time it has consumed. Summing those gives per-process GPU use.
            IORegistry.forEachChild(of: accelerator) { client in
                guard let creator = IORegistry.property("IOUserClientCreator", of: client) as? String,
                      let pid = Self.pid(fromCreator: creator),
                      let usage = IORegistry.property("AppUsage", of: client) as? [[String: Any]] else { return }
                let total = usage.reduce(UInt64(0)) { $0 + ($1.uint64("accumulatedGPUTime") ?? 0) }
                if total > 0 { processTime[pid, default: 0] += total }
            }
        }

        return Result(gpus: gpus, processGPUTime: processTime)
    }

    /// How busy the whole GPU was, from its `PerformanceStatistics`. Apple
    /// silicon publishes "Device Utilization %", Intel and AMD drivers "GPU
    /// Activity(%)". nil when the driver publishes neither, as a virtual
    /// machine's paravirtual GPU doesn't: that's unknown, not idle.
    static func deviceUtilization(_ stats: [String: Any]) -> Double? {
        fraction("Device Utilization %", in: stats) ?? fraction("GPU Activity(%)", in: stats)
    }

    /// A percentage statistic as a fraction, clamped to 0...1.
    static func fraction(_ key: String, in stats: [String: Any]) -> Double? {
        stats.double(key).map { min(max($0 / 100, 0), 1) }
    }

    /// Parses "pid 619, WindowServer".
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return Int32(digits)
    }

    private static func parentModel(of entry: io_registry_entry_t) -> String? {
        guard let parent = IORegistry.parent(of: entry) else { return nil }
        defer { IOObjectRelease(parent) }
        return IORegistry.properties(of: parent).string("model")
    }
}
