import Foundation

/// How a sustained CPU run is shaped: one of the benchmark's workloads on
/// every worker, for minutes, timed in fixed windows. The standard ones
/// belong to `CPUSustained.suiteVersion`; tests use shorter ones.
public struct CPUSustainedConfiguration: Sendable, Codable, Equatable {
    /// The floating-point workload: compute-bound, so it keeps every core
    /// busy without waiting on memory, the load that heats a chip most.
    public var workload: CPUWorkload
    /// The whole timed run, after the warm-up.
    public var durationSeconds: Double
    /// Each point on the chart: throughput over this long.
    public var windowSeconds: Double
    /// Each window is timed in this many back-to-back slices, whose slowest
    /// and fastest give the window its spread.
    public var slicesPerWindow: Int
    /// Untimed first, so caches fill and clocks rise.
    public var warmUpSeconds: Double
    /// The workloads' sizes and seed: the short benchmark's.
    public var kernels: CPUBenchmarkConfiguration

    public init(workload: CPUWorkload = .floatingPoint, durationSeconds: Double, windowSeconds: Double = 10, slicesPerWindow: Int = 5,
                warmUpSeconds: Double = 0.5, kernels: CPUBenchmarkConfiguration = .standard) {
        self.workload = workload
        self.durationSeconds = durationSeconds
        self.windowSeconds = windowSeconds
        self.slicesPerWindow = slicesPerWindow
        self.warmUpSeconds = warmUpSeconds
        self.kernels = kernels
    }

    /// The lengths offered, in minutes; the first is the default.
    public static let offeredMinutes = [2, 5]

    /// The standard run of `minutes` (2 unless 5 is asked for).
    public static func standard(minutes: Int = offeredMinutes[0]) -> Self {
        Self(durationSeconds: Double(offeredMinutes.contains(minutes) ? minutes : offeredMinutes[0]) * 60)
    }

    /// Whole windows in the run.
    public var windowCount: Int {
        guard windowSeconds > 0, durationSeconds.isFinite else { return 1 }
        return max(1, Int((durationSeconds / windowSeconds).rounded()))
    }

    /// How long each timed slice runs.
    public var sliceSeconds: Double {
        windowSeconds / Double(max(slicesPerWindow, 1))
    }

    /// Seconds a run takes when nothing holds it up.
    public var plannedSeconds: Double {
        warmUpSeconds + Double(windowCount) * windowSeconds
    }

    /// "2 min", "5 min".
    public var durationText: String {
        Format.timeSpan(durationSeconds)
    }
}

/// One window of a sustained run: its throughput and the thermal state as it ended.
public struct CPUSustainedWindow: Sendable, Codable, Equatable {
    /// When the window started, in seconds from the end of the warm-up.
    public var start: Double
    /// How long it was timed for.
    public var seconds: Double
    /// Work per second over the whole window, in the workload's measure.
    public var throughput: Double
    /// Work per second in each of its slices.
    public var slices: [Double]
    /// `ProcessInfo.thermalState` as the window ended.
    public var thermalState: ThermalState

    public init(start: Double, seconds: Double, throughput: Double, slices: [Double], thermalState: ThermalState) {
        self.start = start
        self.seconds = seconds
        self.throughput = throughput
        self.slices = slices
        self.thermalState = thermalState
    }

    /// The window's end, in seconds from the end of the warm-up.
    public var end: Double { start + seconds }
}

/// A finished sustained run: its windows, with what it takes to compare it
/// with another sustained run (never with a short one).
public struct CPUSustainedResult: SpeedTestRecord, Equatable, Identifiable {
    public static let currentVersion = 1

    public var id: Date { date }
    public var version = Self.currentVersion
    public var date: Date
    /// `CPUSustained.suiteVersion` when it ran.
    public var suiteVersion: Int
    public var configuration: CPUSustainedConfiguration
    public var workers: Int
    public var machine: CPUBenchmarkMachine
    /// "macOS 27.2 (27C61)".
    public var osVersion: String
    /// "OpenTaskManager 0.1", "otm 0.1.0".
    public var appVersion: String
    /// An optimised (release) build. A debug build's figures are far lower.
    public var optimized: Bool
    public var thermalStateAtStart: ThermalState
    public var thermalStateAtEnd: ThermalState
    public var lowPowerMode: Bool
    /// The whole run, warm-up included.
    public var seconds: Double
    public var windows: [CPUSustainedWindow]
    /// The Mac's state as the run started and ended.
    public var context: BenchmarkContext?

    public init(date: Date, suiteVersion: Int = CPUSustained.suiteVersion, configuration: CPUSustainedConfiguration, workers: Int,
                machine: CPUBenchmarkMachine, osVersion: String, appVersion: String, optimized: Bool, thermalStateAtStart: ThermalState,
                thermalStateAtEnd: ThermalState, lowPowerMode: Bool, seconds: Double, windows: [CPUSustainedWindow],
                context: BenchmarkContext? = nil) {
        self.date = date
        self.suiteVersion = suiteVersion
        self.configuration = configuration
        self.workers = workers
        self.machine = machine
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.optimized = optimized
        self.thermalStateAtStart = thermalStateAtStart
        self.thermalStateAtEnd = thermalStateAtEnd
        self.lowPowerMode = lowPowerMode
        self.seconds = seconds
        self.windows = windows
        self.context = context
    }

    public var historyKey: String { machine.key }

    /// The first window, the level it held over the last third, and what
    /// macOS said about heat; nil with no windows.
    public var summary: CPUSustainedSummary? {
        CPUSustainedSummary(windows: windows, thermalAtStart: thermalStateAtStart)
    }

    /// The worst thermal state seen: at the start, in any window, at the end.
    public var worstThermalState: ThermalState {
        ([thermalStateAtStart, thermalStateAtEnd] + windows.map(\.thermalState)).max { $0.severity < $1.severity } ?? .nominal
    }
}

/// How far a sustained run is.
public struct CPUSustainedProgress: Sendable, Equatable {
    /// 0...1 through the whole run.
    public var fraction: Double
    /// Seconds since the run started, warm-up included.
    public var elapsed: Double
    public var plannedSeconds: Double
    public var warmingUp: Bool
    /// The windows finished so far.
    public var windows: [CPUSustainedWindow]
}

/// A sustained CPU run the user starts: the floating-point workload on
/// every worker, as the short benchmark's all-worker phase runs it, for 2 or
/// 5 minutes, with its throughput timed in 10-second windows. It reports how
/// much of its first window's speed the run held; it doesn't say why
/// throughput moved, only what macOS reported about heat as it went.
public enum CPUSustained {
    /// The run's version: its workload, sizes and windows. Bump it whenever
    /// any of them change, or `CPUBenchmark.suiteVersion` does.
    public static let suiteVersion = 1

    /// Runs it, blocking the calling thread for about
    /// `configuration.plannedSeconds`. Progress comes after each slice.
    public static func run(configuration: CPUSustainedConfiguration, workers: Int = CPUBenchmark.defaultWorkers, appVersion: String,
                           cancellation: CPUBenchmarkCancellation? = nil,
                           progress: (CPUSustainedProgress) -> Void = { _ in }) throws(CPUBenchmarkError) -> CPUSustainedResult {
        let started = BenchmarkClock.now
        let date = Date()
        let thermalAtStart = ThermalState(ProcessInfo.processInfo.thermalState)
        let phase = CPUBenchmarkPhase(workload: configuration.workload, workers: max(workers, 1), isMulti: true)
        let kernel = CPUBenchmark.makeKernel(configuration.workload, configuration: configuration.kernels)
        let planned = configuration.plannedSeconds
        var report = CPUSustainedProgress(fraction: 0, elapsed: 0, plannedSeconds: planned, warmingUp: true, windows: [])
        progress(report)
        _ = try CPUBenchmark.pass(phase, kernel: kernel, seconds: configuration.warmUpSeconds, cancellation: cancellation)
        report.warmingUp = false
        let timed = BenchmarkClock.now
        for _ in 0..<configuration.windowCount {
            let start = Double(BenchmarkClock.now - timed) / 1e9
            var work = 0.0, seconds = 0.0
            var slices: [Double] = []
            for _ in 0..<max(configuration.slicesPerWindow, 1) {
                let slice = try CPUBenchmark.pass(phase, kernel: kernel, seconds: configuration.sliceSeconds, cancellation: cancellation)
                work += slice.work
                seconds += slice.seconds
                if slice.seconds > 0 { slices.append(slice.work / slice.seconds) }
                report.elapsed = BenchmarkClock.seconds(since: started)
                report.fraction = min(report.elapsed / max(planned, 0.001), 0.99)
                progress(report)
            }
            report.windows.append(CPUSustainedWindow(start: start, seconds: seconds, throughput: seconds > 0 ? work / seconds : 0,
                                                     slices: slices, thermalState: ThermalState(ProcessInfo.processInfo.thermalState)))
            progress(report)
        }
        report.fraction = 1
        progress(report)
        return CPUSustainedResult(
            date: date, configuration: configuration, workers: phase.workers, machine: .current(), osVersion: CPUBenchmark.osVersion,
            appVersion: appVersion, optimized: CPUBenchmark.isOptimizedBuild, thermalStateAtStart: thermalAtStart,
            thermalStateAtEnd: ThermalState(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, seconds: BenchmarkClock.seconds(since: started),
            windows: report.windows
        )
    }

    /// `run` on its own thread, so it doesn't hold a Swift concurrency
    /// thread. Cancelling the calling task stops it within a few milliseconds.
    public static func measure(configuration: CPUSustainedConfiguration, workers: Int = CPUBenchmark.defaultWorkers, appVersion: String,
                               progress: @escaping @Sendable (CPUSustainedProgress) -> Void) async throws(CPUBenchmarkError)
        -> CPUSustainedResult {
        let cancellation = CPUBenchmarkCancellation()
        let outcome: Result<CPUSustainedResult, CPUBenchmarkError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    Thread.current.qualityOfService = .userInitiated
                    continuation.resume(returning: Result { () throws(CPUBenchmarkError) -> CPUSustainedResult in
                        try run(configuration: configuration, workers: workers, appVersion: appVersion,
                                cancellation: cancellation, progress: progress)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try outcome.get()
    }
}

public extension SpeedTestHistory where Record == CPUSustainedResult {
    /// Sustained CPU runs: the last 10 on each Mac, in a file of their own,
    /// so an app from before them never reads or rewrites them.
    static var cpuSustained: Self {
        Self(file: defaultFolder.appendingPathComponent("cpu-sustained.json"), keptPerKey: 10, keptKeys: 5)
    }
}
