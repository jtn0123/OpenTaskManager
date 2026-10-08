import Observation
import OTMKit
import SwiftUI

/// The GPU benchmark on the GPU detail. Like the CPU benchmark: nothing runs
/// until the user starts it, it runs on a thread of its own, and it's kept
/// for the session, so a run survives switching resources or pages. The GPU
/// and its history (a small file) are read once, when the card first shows,
/// so the card has its full height from its first frame; each result is
/// saved off the main actor. Progress arrives a few times a second, never per tick.
@Observable
@MainActor
final class GPUBenchmarkStore {
    static let shared = GPUBenchmarkStore()

    struct Run: Equatable {
        let started: Date
    }

    /// The GPU Metal gives apps, which the benchmark runs on; nil without one.
    let device: GPUBenchmarkDevice?
    /// This Mac's saved results, newest first.
    private(set) var history: [GPUBenchmarkResult]
    private(set) var running: Run?
    private(set) var progress: GPUBenchmarkProgress?
    /// Why the last run failed.
    private(set) var failure: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start and cancel, so a stopped run's late result is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var handledLaunchArgument = false

    private init() {
        var device = GPUBenchmarkDevice.current()
        if Self.fixture == "nodevice" { device = nil }
        self.device = device
        history = device.map { SpeedTestHistory.gpuBenchmark.results(for: $0.key) } ?? []
    }

    func start() {
        guard running == nil, let device else { return }
        generation += 1
        let generation = generation
        running = Run(started: Date())
        progress = nil
        failure = nil
        let report: @Sendable (GPUBenchmarkProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.progress = progress
            }
        }
        let appVersion = BenchmarkContextFeed.appVersion
        let fixture = Self.fixtureError
        task = Task { [weak self] in
            do throws(GPUBenchmarkError) {
                if let fixture { throw fixture }
                let context = await BenchmarkContextFeed.capture()
                if Task.isCancelled { throw .cancelled }
                var measured = try await GPUBenchmark.measure(appVersion: appVersion, progress: report)
                measured.context = context.ended()
                let result = measured
                let saved = await Task.detached(priority: .utility) { try? SpeedTestHistory.gpuBenchmark.append(result) }.value
                BenchmarkWorkspace.shared.noteResult(at: result.date)
                guard let self, self.generation == generation else { return }
                history = (saved ?? [result] + history).filter { $0.historyKey == device.key }
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

    /// `--args -openResource gpu -openSpeedTest start` starts a run when the
    /// card first shows, for screenshots of a running and a finished benchmark.
    func handleLaunchArgument() {
        guard !handledLaunchArgument else { return }
        handledLaunchArgument = true
        if LaunchArgument.startsTest(on: "gpu") { start() }
    }

    /// In a debug build, `-gpuBenchmarkFixture nodevice|unsupported|notiming`
    /// shows the card as it is on a Mac without Metal, or after a run whose
    /// GPU can't run the workloads or time them, as a VM's might.
    private static var fixture: String? {
        #if DEBUG
        LaunchArgument.string("gpuBenchmarkFixture")
        #else
        nil
        #endif
    }

    private static var fixtureError: GPUBenchmarkError? {
        switch fixture {
        case "unsupported": .unsupported("its compiler rejected the shaders (a fixture)")
        case "notiming": .noTiming
        default: nil
        }
    }
}
