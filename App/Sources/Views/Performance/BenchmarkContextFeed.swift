import Foundation
import OTMKit

/// Reads the Mac's state as a test starts, for the context saved with its
/// result. The whole CPU's load in the few seconds before comes from the
/// app's own sampler when it's running (its last few updates, already
/// taken, so nothing extra is sampled); when it's paused, the CPU's tick
/// counters are read a second apart instead. Called once per test start,
/// never per tick.
@MainActor
enum BenchmarkContextFeed {
    /// How far back the load is taken: the few seconds before the start.
    static let loadSeconds = 5.0

    private static weak var model: AppModel?

    /// The model whose sampler gives the recent load.
    static func attach(_ model: AppModel) {
        self.model = model
    }

    /// "OpenTaskManager 0.1".
    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return "OpenTaskManager \(version)".trimmingCharacters(in: .whitespaces)
    }

    /// The sampler's mean whole-CPU load over the last `loadSeconds`, when
    /// it's sampling and its latest update is recent; nil otherwise.
    static func recentLoad(now: Date = Date()) -> BenchmarkCPULoad? {
        guard let model, !model.isPaused, let snapshot = model.snapshot else { return nil }
        let step = model.samplingInterval
        guard now.timeIntervalSince(snapshot.timestamp) <= step * 2 + 1 else { return nil }
        return BenchmarkCPULoad.recent(model.cpuHistory.values, step: step, seconds: loadSeconds)
    }

    /// The context as a test starts. Waits about a second only when the
    /// sampler can't say how busy the CPU has been.
    static func capture() async -> BenchmarkContext {
        await BenchmarkContextReader.capture(appVersion: appVersion, cpuLoad: recentLoad())
    }
}

extension BenchmarkContextFeed {
    /// Uses only the latest published snapshot; a paused or stale sampler reports unavailable.
    static func preflightReading(after previous: Date? = nil, now: Date = Date()) -> BenchmarkPreflightReading? {
        guard let model, !model.isPaused, let sample = model.snapshot, sample.interval > 0,
              now.timeIntervalSince(sample.timestamp) <= min(model.samplingInterval * 2 + 1, 10) else { return nil }
        let elapsed = previous.map { sample.timestamp.timeIntervalSince($0) } ?? sample.interval
        let seconds = elapsed <= max(model.samplingInterval * 2 + 1, 2) ? elapsed : sample.interval
        let load = BenchmarkCPULoad.recent(model.cpuHistory.values, step: model.samplingInterval, seconds: max(seconds, 0))
        let power: BenchmarkPowerSource = sample.power.battery.map { $0.isPluggedIn ? .ac : .battery } ?? .ac
        return BenchmarkPreflightReading(date: sample.timestamp, interval: min(max(seconds, 0), load?.seconds ?? sample.interval),
                                         cpuBusy: !sample.cpu.coreUsage.isEmpty ? load?.busy : nil,
                                         memoryPressure: sample.memory.physical > 0 ? sample.memory.pressure : nil,
                                         thermal: sample.power.thermalState, power: power, lowPowerMode: sample.power.isLowPowerMode)
    }
}
