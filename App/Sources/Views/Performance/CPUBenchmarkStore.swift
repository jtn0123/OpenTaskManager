import Observation
import OTMKit
import SwiftUI

/// The CPU benchmark on the CPU detail. Like the speed tests: nothing runs
/// until the user starts it, it runs on threads of its own, and it's kept
/// for the session, so a run survives switching resources or pages. The
/// history (a small file) is read once, when the card first shows, so the
/// card has its full height from its first frame; each result is saved off
/// the main actor. Progress arrives about twice a second, never per tick.
@Observable
@MainActor
final class CPUBenchmarkStore {
    static let shared = CPUBenchmarkStore()

    struct Run: Equatable {
        let started: Date
        let workers: Int
    }

    /// This Mac's saved results, newest first.
    private(set) var history: [CPUBenchmarkResult]
    private(set) var running: Run?
    private(set) var progress: CPUBenchmarkProgress?
    /// Why the last run failed.
    private(set) var failure: String?
    @ObservationIgnored private let machineKey: String
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start and cancel, so a stopped run's late result is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var handledLaunchArgument = false

    /// "OpenTaskManager 0.1".
    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return "OpenTaskManager \(version)".trimmingCharacters(in: .whitespaces)
    }

    private init() {
        let key = CPUBenchmarkMachine.current().key
        machineKey = key
        history = SpeedTestHistory.cpuBenchmark.results(for: key)
    }

    func start() {
        guard running == nil else { return }
        generation += 1
        let generation = generation
        let workers = CPUBenchmark.defaultWorkers
        running = Run(started: Date(), workers: workers)
        progress = nil
        failure = nil
        let report: @Sendable (CPUBenchmarkProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.progress = progress
            }
        }
        let appVersion = Self.appVersion
        task = Task { [weak self] in
            do throws(CPUBenchmarkError) {
                let result = try await CPUBenchmark.measure(workers: workers, appVersion: appVersion, progress: report)
                let saved = await Task.detached(priority: .utility) { try? SpeedTestHistory.cpuBenchmark.append(result) }.value
                BenchmarkWorkspace.shared.noteResult(at: result.date)
                guard let self, self.generation == generation else { return }
                history = (saved ?? [result] + history).filter { $0.historyKey == self.machineKey }
            } catch {
                guard let self, self.generation == generation else { return }
                if error != .cancelled { failure = error.message }
            }
            self?.finish(generation)
        }
    }

    func cancel() {
        task?.cancel()
        finish(generation)
    }

    /// Returns once the run in progress, if any, has ended, for Run all.
    func waitForRun() async {
        await task?.value
    }

    private func finish(_ generation: Int) {
        guard generation == self.generation, running != nil else { return }
        self.generation += 1
        running = nil
        progress = nil
        task = nil
    }

    /// `--args -openSpeedTest start` (with `-openResource cpu` or none)
    /// starts a run when the card first shows, for screenshots of a running
    /// and a finished benchmark.
    func handleLaunchArgument() {
        guard !handledLaunchArgument else { return }
        handledLaunchArgument = true
        if LaunchArgument.startsTest(on: "cpu") { start() }
    }
}
