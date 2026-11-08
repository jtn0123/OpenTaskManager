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
        let step = model.updateSpeed.rawValue
        guard now.timeIntervalSince(snapshot.timestamp) <= step * 2 + 1 else { return nil }
        return BenchmarkCPULoad.recent(model.cpuHistory.values, step: step, seconds: loadSeconds)
    }

    /// The context as a test starts. Waits about a second only when the
    /// sampler can't say how busy the CPU has been.
    static func capture() async -> BenchmarkContext {
        await BenchmarkContextReader.capture(appVersion: appVersion, cpuLoad: recentLoad())
    }
}
