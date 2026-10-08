import Observation
import OTMKit
import SwiftUI

/// The sustained CPU run, on the CPU detail's Benchmark card and in the
/// Benchmarks workspace. Like the short benchmark: nothing runs until the
/// user starts it, it runs on a thread of its own, and it's kept for the
/// session, so a run survives switching resources or pages. Only one CPU
/// run goes at a time: this and the short benchmark each wait for the other.
/// The history (a small file) is read once; each result is saved off the
/// main actor. Progress arrives once per timed slice (2 s), never per tick.
@Observable
@MainActor
final class CPUSustainedStore {
    static let shared = CPUSustainedStore()

    struct Run: Equatable {
        let started: Date
        let configuration: CPUSustainedConfiguration
    }

    private static let minutesKey = "sustainedMinutes"

    /// This Mac's saved runs, newest first.
    private(set) var history: [CPUSustainedResult]
    private(set) var running: Run?
    private(set) var progress: CPUSustainedProgress?
    /// Why the last run failed.
    private(set) var failure: String?
    /// How long the next run lasts: 2 or 5 minutes, remembered.
    var minutes: Int {
        didSet { UserDefaults.standard.set(minutes, forKey: Self.minutesKey) }
    }

    @ObservationIgnored private let machineKey: String
    /// Runs made up for screenshots, which are never saved, nor is a run beside them.
    @ObservationIgnored private let usesFixture: Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start and cancel, so a stopped run's late result is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var handledLaunchArgument = false

    private init() {
        let machine = CPUBenchmarkMachine.current()
        machineKey = machine.key
        let saved = UserDefaults.standard.integer(forKey: Self.minutesKey)
        minutes = CPUSustainedConfiguration.offeredMinutes.contains(saved) ? saved : CPUSustainedConfiguration.offeredMinutes[0]
        if let fixture = Self.fixture(machine: machine) {
            history = fixture
            usesFixture = true
        } else {
            history = SpeedTestHistory.cpuSustained.results(for: machine.key)
            usesFixture = false
        }
    }

    /// Whether a run can start: neither CPU run is going, nor is Run all.
    var canStart: Bool {
        running == nil && CPUBenchmarkStore.shared.running == nil && !BenchmarkWorkspace.shared.suiteRunning
    }

    func start() {
        guard canStart else { return }
        let configuration = CPUSustainedConfiguration.standard(minutes: minutes)
        generation += 1
        let generation = generation
        let workers = CPUBenchmark.defaultWorkers
        running = Run(started: Date(), configuration: configuration)
        progress = nil
        failure = nil
        let report: @Sendable (CPUSustainedProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.progress = progress
            }
        }
        let appVersion = BenchmarkContextFeed.appVersion
        let saves = !usesFixture
        task = Task { [weak self] in
            do throws(CPUBenchmarkError) {
                let context = await BenchmarkContextFeed.capture()
                if Task.isCancelled { throw .cancelled }
                var measured = try await CPUSustained.measure(configuration: configuration, workers: workers, appVersion: appVersion,
                                                              progress: report)
                measured.context = context.ended()
                let result = measured
                var saved: [CPUSustainedResult]?
                if saves {
                    saved = await Task.detached(priority: .utility) { try? SpeedTestHistory.cpuSustained.append(result) }.value
                    BenchmarkWorkspace.shared.noteResult(at: result.date)
                }
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

    private func finish(_ generation: Int) {
        guard generation == self.generation, running != nil else { return }
        self.generation += 1
        running = nil
        progress = nil
        task = nil
    }

    /// `--args -openResource cpu -openSpeedTest sustained` starts a run
    /// when the card first shows, for screenshots of one running and its result.
    func handleLaunchArgument() {
        guard !handledLaunchArgument else { return }
        handledLaunchArgument = true
        if LaunchArgument.string("openSpeedTest") == "sustained" { start() }
    }
}

// MARK: - Screenshot fixture

extension CPUSustainedStore {
    /// In a debug build, `-sustainedFixture YES` shows three made-up runs on
    /// this Mac in place of the saved ones, never written anywhere: the newest
    /// on battery with the CPU busy before it, slowing to about 93% as the
    /// thermal state turns fair; one the day before on the power adapter,
    /// holding about 99%; and a 5-minute one from before contexts were recorded.
    private static func fixture(machine: CPUBenchmarkMachine) -> [CPUSustainedResult]? {
        #if DEBUG
        guard LaunchArgument.string("sustainedFixture") == "YES" else { return nil }
        let now = Date()
        let base = CPUBenchmark.isOptimizedBuild ? 1.6e11 : 4.2e9
        let declining = [1.0, 0.996, 0.99, 0.978, 0.962, 0.95, 0.942, 0.936, 0.931, 0.928, 0.925, 0.93]
        let holding = [1.0, 0.998, 0.995, 0.997, 0.993, 0.994, 0.99, 0.992, 0.989, 0.991, 0.988, 0.99]
        let longer = (0..<30).map { 1.0 - 0.042 * (1 - exp(-Double($0) / 6)) }
        let busy = fixtureContext(machine: machine, power: .battery, thermal: .nominal, busy: 0.38, available: 2_400_000_000)
        let calm = fixtureContext(machine: machine, power: .ac, thermal: .nominal, busy: 0.04, available: 11_800_000_000)
        return [
            fixtureRun(machine: machine, date: now.addingTimeInterval(-3600), minutes: 2,
                       windows: fixtureWindows(declining.map { $0 * base }, fairFrom: 4), context: busy.ended(thermal: .fair)),
            fixtureRun(machine: machine, date: now.addingTimeInterval(-26 * 3600), minutes: 2,
                       windows: fixtureWindows(holding.map { $0 * base * 1.012 }), context: calm.ended(thermal: .nominal)),
            fixtureRun(machine: machine, date: now.addingTimeInterval(-74 * 3600), minutes: 5,
                       windows: fixtureWindows(longer.map { $0 * base * 1.005 }), context: nil),
        ]
        #else
        nil
        #endif
    }

    #if DEBUG
    private static func fixtureContext(machine: CPUBenchmarkMachine, power: BenchmarkPowerSource, thermal: ThermalState, busy: Double,
                                       available: UInt64) -> BenchmarkContext {
        BenchmarkContext(osVersion: CPUBenchmark.osVersion, appVersion: BenchmarkContextFeed.appVersion,
                         optimized: CPUBenchmark.isOptimizedBuild, model: machine.model, chip: machine.chip, power: power,
                         hasBattery: true, lowPowerMode: false, thermalAtStart: thermal,
                         cpuLoad: BenchmarkCPULoad(busy: busy, seconds: 5, source: .sampler), availableMemoryBytes: available,
                         physicalMemoryBytes: machine.memoryBytes > 0 ? machine.memoryBytes : 17_179_869_184)
    }

    /// Windows of `shape`, each with five slices around it, fair from window `fairFrom` on.
    private static func fixtureWindows(_ shape: [Double], fairFrom: Int? = nil) -> [CPUSustainedWindow] {
        let seconds = CPUSustainedConfiguration.standard().windowSeconds
        let offsets = [-0.006, 0.004, -0.002, 0.005, -0.001]
        return shape.enumerated().map { index, throughput in
            CPUSustainedWindow(start: Double(index) * seconds, seconds: seconds, throughput: throughput,
                               slices: offsets.map { throughput * (1 + $0) },
                               thermalState: fairFrom.map { index >= $0 } == true ? .fair : .nominal)
        }
    }

    private static func fixtureRun(machine: CPUBenchmarkMachine, date: Date, minutes: Int, windows: [CPUSustainedWindow],
                                   context: BenchmarkContext?) -> CPUSustainedResult {
        let configuration = CPUSustainedConfiguration.standard(minutes: minutes)
        return CPUSustainedResult(
            date: date, configuration: configuration, workers: CPUBenchmark.defaultWorkers, machine: machine,
            osVersion: CPUBenchmark.osVersion, appVersion: BenchmarkContextFeed.appVersion, optimized: CPUBenchmark.isOptimizedBuild,
            thermalStateAtStart: .nominal, thermalStateAtEnd: windows.last?.thermalState ?? .nominal, lowPowerMode: false,
            seconds: configuration.plannedSeconds, windows: windows, context: context
        )
    }
    #endif
}
