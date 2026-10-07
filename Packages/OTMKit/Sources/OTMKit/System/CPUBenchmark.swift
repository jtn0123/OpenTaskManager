import Darwin
import Foundation
import os

/// The benchmark's workloads, in the order a run measures them.
public enum CPUWorkload: String, Sendable, Codable, CaseIterable {
    case integer, floatingPoint, memory

    public var title: String {
        switch self {
        case .integer: "Integer"
        case .floatingPoint: "Floating point"
        case .memory: "Memory"
        }
    }

    /// What the workload does, in a few words.
    public var summary: String {
        switch self {
        case .integer: "64-bit multiply–xor hashing of a buffer held in cache"
        case .floatingPoint: "a 64 × 64 matrix product in doubles, with fused multiply–adds"
        case .memory: "adding up a 256 MB buffer, far larger than the caches"
        }
    }

    /// Bytes for the integer and memory workloads, floating-point operations for the other.
    public var countsBytes: Bool { self != .floatingPoint }

    /// "12.4 GB/s" or "38.2 GFLOP/s": decimal units, as benchmarks quote them.
    public func format(_ perSecond: Double) -> String {
        guard perSecond.isFinite, perSecond >= 0 else { return "—" }
        let units = countsBytes ? ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"] : ["FLOP/s", "KFLOP/s", "MFLOP/s", "GFLOP/s", "TFLOP/s"]
        var scaled = perSecond
        var unit = 0
        while scaled >= 1000, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        return "\(Format.fixed(scaled, scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2)) \(units[unit])"
    }
}

/// How big each workload is and how long it's timed. The standard
/// configuration belongs to `CPUBenchmark.suiteVersion`; tests use smaller ones.
public struct CPUBenchmarkConfiguration: Sendable, Codable, Equatable {
    public var hashBytes = 256 << 10
    public var matrixSize = 64
    public var memoryBytes = 256 << 20
    public var memoryChunkBytes = 4 << 20
    /// Each phase runs this long untimed first, so caches fill and clocks rise.
    public var warmUpSeconds = 0.5
    /// Each timed repeat runs about this long.
    public var repeatSeconds = 0.6
    public var repeats = 5
    /// Seeds the workloads' inputs. Fixed, so every run checks against the same answers.
    public var seed: UInt64 = 0x4F54_4D2D_4350_5531

    public init() {}

    public static let standard = CPUBenchmarkConfiguration()

    /// Seconds a run takes when nothing holds it up: a warm-up and the
    /// repeats for each workload, on one worker and then on all.
    public var plannedSeconds: Double {
        Double(CPUWorkload.allCases.count * 2) * (warmUpSeconds + Double(repeats) * repeatSeconds)
    }
}

/// A workload's speed on one number of workers.
public struct CPUBenchmarkMeasurement: Sendable, Codable, Equatable {
    public var workers: Int
    /// Work per second in each timed repeat, in the workload's measure.
    public var repeats: [Double]

    public init(workers: Int, repeats: [Double]) {
        self.workers = workers
        self.repeats = repeats
    }

    /// The middle repeat: the figure to quote.
    public var median: Double {
        let sorted = repeats.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// How far apart the slowest and fastest repeats were, as a share of the median.
    public var spread: Double {
        guard let low = repeats.min(), let high = repeats.max(), median > 0 else { return 0 }
        return (high - low) / median
    }
}

/// One workload's result on one worker and on all of them.
public struct CPUWorkloadResult: Sendable, Codable, Equatable {
    public var workload: CPUWorkload
    public var single: CPUBenchmarkMeasurement
    public var multi: CPUBenchmarkMeasurement

    public init(workload: CPUWorkload, single: CPUBenchmarkMeasurement, multi: CPUBenchmarkMeasurement) {
        self.workload = workload
        self.single = single
        self.multi = multi
    }

    /// How many times one worker's speed all of them reached.
    public var scaling: Double {
        single.median > 0 ? multi.median / single.median : 0
    }

    /// `scaling` per worker: 1 when every worker kept the single worker's pace.
    public var efficiency: Double {
        multi.workers > 0 ? scaling / Double(multi.workers) : 0
    }
}

/// The Mac a result was measured on, so the history keeps each Mac's apart.
public struct CPUBenchmarkMachine: Sendable, Codable, Equatable {
    public struct CoreCount: Sendable, Codable, Equatable {
        public var name: String
        public var cores: Int

        public init(name: String, cores: Int) {
            self.name = name
            self.cores = cores
        }
    }

    public var chip: String
    public var model: String?
    public var logicalCores: Int
    public var coreTypes: [CoreCount]
    public var memoryBytes: UInt64

    public init(chip: String, model: String?, logicalCores: Int, coreTypes: [CoreCount], memoryBytes: UInt64) {
        self.chip = chip
        self.model = model
        self.logicalCores = logicalCores
        self.coreTypes = coreTypes
        self.memoryBytes = memoryBytes
    }

    public var key: String {
        [model ?? "", chip, String(logicalCores)].joined(separator: "|")
    }

    /// "6 Super + 12 Performance cores", or "6 cores".
    public var coreSummary: String {
        coreTypes.count > 1 ? coreTypes.map { "\($0.cores) \($0.name)" }.joined(separator: " + ") + " cores"
            : "\(coreTypes.first?.cores ?? logicalCores) cores"
    }

    /// This Mac.
    public static func current() -> Self {
        let topology = CPUTopologyReader.read(clusterTypes: [:])
        return Self(chip: topology.brand, model: Sysctl.string("hw.model"), logicalCores: topology.logicalCores,
                    coreTypes: topology.tiers.map { CoreCount(name: $0.name, cores: $0.physicalCPUs) },
                    memoryBytes: UInt64(Sysctl.int("hw.memsize") ?? 0))
    }
}

/// A finished benchmark, with what it takes to compare it with another:
/// the workloads' version and sizes, the build, the Mac, and its state.
public struct CPUBenchmarkResult: SpeedTestRecord, Equatable, Identifiable {
    public static let currentVersion = 1

    public var id: Date { date }
    public var version = Self.currentVersion
    public var date: Date
    /// `CPUBenchmark.suiteVersion` when it ran.
    public var suiteVersion: Int
    public var configuration: CPUBenchmarkConfiguration
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
    /// The whole run, setup included.
    public var seconds: Double
    public var workloads: [CPUWorkloadResult]

    public var historyKey: String { machine.key }

    public func result(_ workload: CPUWorkload) -> CPUWorkloadResult? {
        workloads.first { $0.workload == workload }
    }

    /// The worse of the thermal states at the start and end.
    public var worstThermalState: ThermalState {
        let order: [ThermalState] = [.nominal, .fair, .serious, .critical]
        return (order.firstIndex(of: thermalStateAtStart) ?? 0) >= (order.firstIndex(of: thermalStateAtEnd) ?? 0)
            ? thermalStateAtStart : thermalStateAtEnd
    }

    /// Whether the figures compare with `other`'s: same workloads, sizes,
    /// kind of build and number of workers.
    public func isComparable(with other: Self) -> Bool {
        suiteVersion == other.suiteVersion && configuration == other.configuration && optimized == other.optimized
            && workloads.first?.multi.workers == other.workloads.first?.multi.workers
    }
}

/// A phase of a run: one workload on one or all workers.
public struct CPUBenchmarkPhase: Sendable, Equatable, Hashable {
    public var workload: CPUWorkload
    public var workers: Int
    public var isMulti: Bool
}

/// How far a running benchmark is.
public struct CPUBenchmarkProgress: Sendable, Equatable {
    public var phase: CPUBenchmarkPhase
    /// 0...1 through the whole run.
    public var fraction: Double
    /// Workloads measured so far, on one worker and on all.
    public var single: [CPUWorkload: CPUBenchmarkMeasurement] = [:]
    public var multi: [CPUWorkload: CPUBenchmarkMeasurement] = [:]
}

public enum CPUBenchmarkError: Error, Equatable, Sendable {
    /// A unit's result wasn't the expected one.
    case verificationFailed(CPUWorkload)
    case cancelled

    public var message: String {
        switch self {
        case let .verificationFailed(workload):
            "The \(workload.title.lowercased()) workload gave a wrong result, so its figures were discarded. "
                + "That points to a hardware or memory fault, or a bug in the benchmark."
        case .cancelled: "The benchmark was cancelled."
        }
    }
}

/// Stops a running benchmark from another thread; workers notice within a few milliseconds.
public final class CPUBenchmarkCancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func cancel() {
        flag.withLock { $0 = true }
    }

    public var isCancelled: Bool { flag.withLock { $0 } }
}

/// A CPU benchmark the user starts: integer, floating-point and memory
/// workloads (see `CPUBenchmarkKernels`), each on one worker thread and then
/// on one per logical CPU. Each phase warms up, then times a few repeats on
/// the monotonic clock, and every unit of work is checked. macOS decides
/// which cores the threads run on: nothing pins a worker to a kind of core.
public enum CPUBenchmark {
    /// The workloads' version. Bump it whenever their inputs, sizes or
    /// arithmetic change, so old results aren't compared with new ones.
    public static let suiteVersion = 1

    /// Whether this code was compiled with optimisation. A debug build runs
    /// the workloads many times slower.
    public static var isOptimizedBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// One worker per logical CPU.
    public static var defaultWorkers: Int { max(ProcessInfo.processInfo.activeProcessorCount, 1) }

    /// "macOS 27.2 (27C61)".
    public static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = version.patchVersion > 0 ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        return "macOS \(number)" + (Sysctl.string("kern.osversion").map { " (\($0))" } ?? "")
    }

    /// The phases in order: every workload on one worker first, so the
    /// all-core phases' heat doesn't slow the single-worker ones.
    public static func phases(workers: Int) -> [CPUBenchmarkPhase] {
        CPUWorkload.allCases.map { CPUBenchmarkPhase(workload: $0, workers: 1, isMulti: false) }
            + CPUWorkload.allCases.map { CPUBenchmarkPhase(workload: $0, workers: max(workers, 1), isMulti: true) }
    }

    /// Runs the benchmark, blocking the calling thread for about
    /// `configuration.plannedSeconds`. Progress comes from the calling thread.
    public static func run(configuration: CPUBenchmarkConfiguration = .standard, workers: Int = defaultWorkers, appVersion: String,
                           cancellation: CPUBenchmarkCancellation? = nil,
                           progress: (CPUBenchmarkProgress) -> Void = { _ in }) throws(CPUBenchmarkError) -> CPUBenchmarkResult {
        let started = BenchmarkClock.now
        let date = Date()
        let thermalAtStart = ThermalState(ProcessInfo.processInfo.thermalState)
        let phases = phases(workers: workers)
        var report = CPUBenchmarkProgress(phase: phases[0], fraction: 0)
        let kernels = Kernels(configuration)
        for (index, phase) in phases.enumerated() {
            report.phase = phase
            report.fraction = Double(index) / Double(phases.count)
            progress(report)
            let measurement = try measurePhase(phase, kernel: kernels.kernel(phase.workload), configuration: configuration,
                                               cancellation: cancellation) { done in
                report.fraction = (Double(index) + done) / Double(phases.count)
                progress(report)
            }
            if phase.isMulti { report.multi[phase.workload] = measurement } else { report.single[phase.workload] = measurement }
        }
        report.fraction = 1
        progress(report)
        let workloads = CPUWorkload.allCases.compactMap { workload in
            report.single[workload].flatMap { single in
                report.multi[workload].map { CPUWorkloadResult(workload: workload, single: single, multi: $0) }
            }
        }
        return CPUBenchmarkResult(
            date: date, suiteVersion: suiteVersion, configuration: configuration, machine: .current(), osVersion: osVersion,
            appVersion: appVersion, optimized: isOptimizedBuild, thermalStateAtStart: thermalAtStart,
            thermalStateAtEnd: ThermalState(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            seconds: BenchmarkClock.seconds(since: started), workloads: workloads
        )
    }

    /// `run` on its own thread, so it doesn't hold a Swift concurrency
    /// thread. Cancelling the calling task stops it.
    public static func measure(configuration: CPUBenchmarkConfiguration = .standard, workers: Int = defaultWorkers, appVersion: String,
                               progress: @escaping @Sendable (CPUBenchmarkProgress) -> Void) async throws(CPUBenchmarkError)
        -> CPUBenchmarkResult {
        let cancellation = CPUBenchmarkCancellation()
        let outcome: Result<CPUBenchmarkResult, CPUBenchmarkError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    Thread.current.qualityOfService = .userInitiated
                    continuation.resume(returning: Result { () throws(CPUBenchmarkError) -> CPUBenchmarkResult in
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

    // MARK: - Measuring

    /// One phase: a warm-up, then the timed repeats. `done` gets the share
    /// of the phase finished after each step.
    static func measurePhase(_ phase: CPUBenchmarkPhase, kernel: any BenchmarkKernel, configuration: CPUBenchmarkConfiguration,
                             cancellation: CPUBenchmarkCancellation?, done: (Double) -> Void) throws(CPUBenchmarkError)
        -> CPUBenchmarkMeasurement {
        let steps = Double(configuration.repeats + 1)
        _ = try pass(phase, kernel: kernel, seconds: configuration.warmUpSeconds, cancellation: cancellation)
        done(1 / steps)
        var repeats: [Double] = []
        for index in 0..<configuration.repeats {
            let timed = try pass(phase, kernel: kernel, seconds: configuration.repeatSeconds, cancellation: cancellation)
            if timed.seconds > 0 { repeats.append(timed.work / timed.seconds) }
            done(Double(index + 2) / steps)
        }
        return CPUBenchmarkMeasurement(workers: phase.workers, repeats: repeats)
    }

    /// What one worker did in a pass.
    private struct WorkerTally {
        var units = 0
        var start: UInt64 = 0
        var end: UInt64 = 0
        var failed = false
        var cancelled = false
    }

    /// Every worker runs units on a thread of its own until `seconds` have
    /// passed; the pass's time runs from the first worker's start to the
    /// last one's end. Workers check for cancellation every few milliseconds.
    static func pass(_ phase: CPUBenchmarkPhase, kernel: any BenchmarkKernel, seconds: Double,
                     cancellation: CPUBenchmarkCancellation?) throws(CPUBenchmarkError) -> (work: Double, seconds: Double) {
        let workers = max(phase.workers, 1)
        let tallies = OSAllocatedUnfairLock(initialState: [WorkerTally]())
        let group = DispatchGroup()
        let deadline = BenchmarkClock.now + UInt64(max(seconds, 0) * 1e9)
        let checkInterval: UInt64 = 5_000_000
        for index in 0..<workers {
            let worker = kernel.makeWorker(index, of: workers)
            group.enter()
            let thread = Thread {
                var tally = WorkerTally(start: BenchmarkClock.now)
                var lastCheck = tally.start
                var unit = 0
                while true {
                    if !worker.run(unit: unit) {
                        tally.failed = true
                        break
                    }
                    unit += 1
                    let now = BenchmarkClock.now
                    if now >= deadline { break }
                    if now - lastCheck >= checkInterval {
                        lastCheck = now
                        if cancellation?.isCancelled == true {
                            tally.cancelled = true
                            break
                        }
                    }
                }
                tally.units = unit
                tally.end = BenchmarkClock.now
                let finished = tally
                tallies.withLock { $0.append(finished) }
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        let finished = tallies.withLock { $0 }
        if cancellation?.isCancelled == true || finished.contains(where: \.cancelled) { throw .cancelled }
        let units = finished.reduce(0) { $0 + $1.units }
        guard !finished.contains(where: \.failed), let start = finished.map(\.start).min(), let end = finished.map(\.end).max() else {
            throw .verificationFailed(phase.workload)
        }
        return (Double(units) * kernel.workPerUnit, Double(end - start) / 1e9)
    }

    /// Each workload's inputs, made when its first phase starts (the memory
    /// buffer takes a moment to fill) and kept for its second.
    private final class Kernels {
        private let configuration: CPUBenchmarkConfiguration
        private var made: [CPUWorkload: any BenchmarkKernel] = [:]

        init(_ configuration: CPUBenchmarkConfiguration) {
            self.configuration = configuration
        }

        func kernel(_ workload: CPUWorkload) -> any BenchmarkKernel {
            if let kernel = made[workload] { return kernel }
            let kernel: any BenchmarkKernel = switch workload {
            case .integer: HashKernel(bytes: configuration.hashBytes, seed: configuration.seed)
            case .floatingPoint: MatrixKernel(size: configuration.matrixSize, seed: configuration.seed)
            case .memory: MemoryKernel(bytes: configuration.memoryBytes, chunkBytes: configuration.memoryChunkBytes, seed: configuration.seed)
            }
            made[workload] = kernel
            return kernel
        }
    }
}

/// The monotonic clock the benchmark times with: nanoseconds that don't
/// count time asleep.
enum BenchmarkClock {
    static var now: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func seconds(since start: UInt64) -> Double {
        Double(now - start) / 1e9
    }
}

public extension SpeedTestHistory where Record == CPUBenchmarkResult {
    /// CPU benchmark results: the last 10 on each Mac.
    static var cpuBenchmark: Self {
        Self(file: defaultFolder.appendingPathComponent("cpu-benchmark.json"), keptPerKey: 10, keptKeys: 5)
    }
}
