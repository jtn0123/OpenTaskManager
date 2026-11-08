import Foundation

/// The CLI has no app sampler. Its bounded preflight uses the same CPU and memory readers.
public actor BenchmarkPreflightReader {
    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private var previous: Date?

    public init() {}

    public func reading() -> BenchmarkPreflightReading {
        let now = Date()
        let interval = previous.map { now.timeIntervalSince($0) } ?? 0
        let sample = cpu.sample()
        let pressure = memory.sample(interval: max(interval, 1))
        previous = now
        return BenchmarkPreflightReading(date: now, interval: interval,
            cpuBusy: interval > 0 && !sample.coreUsage.isEmpty ? sample.usage : nil,
            memoryPressure: pressure.physical > 0 ? pressure.pressure : nil,
            thermal: BenchmarkContextReader.thermalNow(), power: BenchmarkContextReader.powerSource(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
