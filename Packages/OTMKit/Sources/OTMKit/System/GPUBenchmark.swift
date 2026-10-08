import Foundation
import Metal
import os

/// The GPU benchmark's workloads, in the order a run measures them.
public enum GPUWorkload: String, Sendable, Codable, CaseIterable {
    case compute, memory, fill

    public var title: String {
        switch self {
        case .compute: "FP32 compute"
        case .memory: "Memory"
        case .fill: "Fill rate"
        }
    }

    /// What the workload does, in a few words.
    public var summary: String {
        switch self {
        case .compute: "chains of 32-bit fused multiply–adds, eight to a thread"
        case .memory: "adding up a 256 MB buffer, far larger than the GPU's caches"
        case .fill: "blending full-screen layers into an offscreen 2048 × 2048 image"
        }
    }

    /// "8.71 TFLOP/s", "262 GB/s" or "98.4 Gpixel/s": decimal units, as benchmarks quote them.
    public func format(_ perSecond: Double) -> String {
        guard perSecond.isFinite, perSecond >= 0 else { return "—" }
        let scaled = scale(perSecond)
        return "\(Format.fixed(perSecond / scaled.divisor, digits(perSecond / scaled.divisor))) \(scaled.unit)"
    }

    /// The unit `format` would pick for `perSecond`, and what it divides by.
    public func scale(_ perSecond: Double) -> (unit: String, divisor: Double) {
        let units = switch self {
        case .compute: ["FLOP/s", "KFLOP/s", "MFLOP/s", "GFLOP/s", "TFLOP/s"]
        case .memory: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        case .fill: ["pixel/s", "Kpixel/s", "Mpixel/s", "Gpixel/s", "Tpixel/s"]
        }
        var divisor = 1.0
        var unit = 0
        while perSecond / divisor >= 1000, unit < units.count - 1 {
            divisor *= 1000
            unit += 1
        }
        return (units[unit], divisor)
    }

    private func digits(_ scaled: Double) -> Int {
        scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
    }
}

/// How big each workload's unit is and how long it's timed. The standard
/// configuration belongs to `GPUBenchmark.suiteVersion`; tests use smaller ones.
public struct GPUBenchmarkConfiguration: Sendable, Codable, Equatable {
    /// FP32 compute: threads per dispatch, steps per chain, and distinct seed groups.
    public var computeThreads = 1 << 20
    public var computeIterations = 1024
    public var computeSeedGroups = 64
    /// Memory: the buffer read per unit, and the lanes that read it.
    public var memoryBytes = 256 << 20
    public var memoryLanes = 1 << 17
    /// Fill rate: the square target's side, and layers per render pass.
    public var fillSize = 2048
    public var fillLayers = 256
    /// Each workload runs this long untimed first, so the GPU's clock rises.
    public var warmUpSeconds = 0.5
    /// Each timed repeat holds about this much GPU time.
    public var repeatSeconds = 0.5
    public var repeats = 5
    /// Seeds the workloads' inputs. Fixed, so every run checks against the same answers.
    public var seed: UInt64 = 0x4F54_4D2D_4750_5531

    public init() {}

    public static let standard = GPUBenchmarkConfiguration()

    /// Seconds a run takes when nothing holds it up: a warm-up and the
    /// repeats for each workload, and about 0.2 s each to compile, fill and check.
    public var plannedSeconds: Double {
        Double(GPUWorkload.allCases.count) * (0.2 + warmUpSeconds + Double(repeats) * repeatSeconds)
    }
}

/// A workload's speed over the timed repeats.
public struct GPUBenchmarkMeasurement: Sendable, Codable, Equatable {
    /// Work per second of GPU time in each timed repeat, in the workload's measure.
    public var repeats: [Double]
    /// Each repeat's GPU time: its command buffer's gpuEndTime − gpuStartTime.
    public var gpuSeconds: [Double]
    /// Each repeat from commit until the CPU saw it finish: the GPU time,
    /// plus scheduling and the wake-up.
    public var wallSeconds: [Double]
    /// Units of work (dispatches or render passes) in each repeat, sized from the warm-up.
    public var unitsPerRepeat: Int

    public init(repeats: [Double], gpuSeconds: [Double], wallSeconds: [Double], unitsPerRepeat: Int) {
        self.repeats = repeats
        self.gpuSeconds = gpuSeconds
        self.wallSeconds = wallSeconds
        self.unitsPerRepeat = unitsPerRepeat
    }

    /// The middle repeat: the figure to quote.
    public var median: Double { Self.median(repeats) }

    /// How far apart the slowest and fastest repeats were, as a share of the median.
    public var spread: Double {
        guard let low = repeats.min(), let high = repeats.max(), median > 0 else { return 0 }
        return (high - low) / median
    }

    /// A repeat's GPU time, the middle one.
    public var medianGPUSeconds: Double { Self.median(gpuSeconds) }

    /// A repeat from commit to completion, the middle one.
    public var medianWallSeconds: Double { Self.median(wallSeconds) }

    /// Whether the GPU's own time for a repeat fell well short of the time
    /// from commit to completion (over 5%, and over 5 ms). Normally they're
    /// within a millisecond. A virtual machine's GPU can under-report its
    /// time, which makes the figure read high; other apps' GPU work can also
    /// hold up a start.
    public var gpuTimeLooksShort: Bool {
        let gap = medianWallSeconds - medianGPUSeconds
        return gap > 0.005 && gap > 0.05 * medianWallSeconds
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// One workload's result.
public struct GPUWorkloadResult: Sendable, Codable, Equatable {
    public var workload: GPUWorkload
    public var measurement: GPUBenchmarkMeasurement

    public init(workload: GPUWorkload, measurement: GPUBenchmarkMeasurement) {
        self.workload = workload
        self.measurement = measurement
    }
}

/// The GPU a result was measured on, and the Mac it's in, so the history
/// keeps each Mac's apart.
public struct GPUBenchmarkDevice: Sendable, Codable, Equatable {
    /// Metal's name for it: "Apple M5 Pro", "Apple Paravirtual device".
    public var name: String
    /// GPU cores, where the driver reports them.
    public var cores: Int?
    /// "Mac17,8".
    public var model: String?
    /// Whether the GPU shares the Mac's memory (Apple silicon) rather than having its own.
    public var unifiedMemory: Bool
    /// How much memory Metal suggests one app keep in use on the GPU.
    public var workingSetBytes: UInt64

    public init(name: String, cores: Int?, model: String?, unifiedMemory: Bool, workingSetBytes: UInt64) {
        self.name = name
        self.cores = cores
        self.model = model
        self.unifiedMemory = unifiedMemory
        self.workingSetBytes = workingSetBytes
    }

    public var key: String {
        [model ?? "", name, cores.map(String.init) ?? ""].joined(separator: "|")
    }

    /// "Apple M5 Pro · 20 cores".
    public var summary: String {
        cores.map { "\(name) · \($0) cores" } ?? name
    }

    /// The GPU Metal gives apps by default, with its core count from the
    /// I/O Registry; nil when this Mac has no Metal GPU.
    public static func current() -> Self? {
        MTLCreateSystemDefaultDevice().map(describe)
    }

    static func describe(_ device: any MTLDevice) -> Self {
        let registered = ChipLayoutReader.gpus()
        let cores = registered.first { $0.name == device.name }?.cores ?? (registered.count == 1 ? registered[0].cores : nil)
        return Self(name: device.name, cores: cores, model: Sysctl.string("hw.model"), unifiedMemory: device.hasUnifiedMemory,
                    workingSetBytes: device.recommendedMaxWorkingSetSize)
    }
}

/// A finished benchmark, with what it takes to compare it with another:
/// the workloads' version and sizes, the GPU, the build, and the Mac's state.
public struct GPUBenchmarkResult: SpeedTestRecord, Equatable, Identifiable {
    public static let currentVersion = 1

    public var id: Date { date }
    public var version = Self.currentVersion
    public var date: Date
    /// `GPUBenchmark.suiteVersion` when it ran.
    public var suiteVersion: Int
    public var configuration: GPUBenchmarkConfiguration
    public var device: GPUBenchmarkDevice
    /// "macOS 27.2 (27C61)".
    public var osVersion: String
    /// "OpenTaskManager 0.1", "otm 0.1.0".
    public var appVersion: String
    /// An optimised (release) build. The shaders run the same in either;
    /// only the checks on the CPU are slower in a debug build.
    public var optimized: Bool
    public var thermalStateAtStart: ThermalState
    public var thermalStateAtEnd: ThermalState
    public var lowPowerMode: Bool
    /// The whole run, compiling and checking included.
    public var seconds: Double
    public var workloads: [GPUWorkloadResult]
    /// The Mac's state as the run started and ended; nil in runs saved
    /// before it was recorded.
    public var context: BenchmarkContext?

    public init(date: Date, suiteVersion: Int, configuration: GPUBenchmarkConfiguration, device: GPUBenchmarkDevice, osVersion: String,
                appVersion: String, optimized: Bool, thermalStateAtStart: ThermalState, thermalStateAtEnd: ThermalState,
                lowPowerMode: Bool, seconds: Double, workloads: [GPUWorkloadResult], context: BenchmarkContext? = nil) {
        self.context = context
        self.date = date
        self.suiteVersion = suiteVersion
        self.configuration = configuration
        self.device = device
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.optimized = optimized
        self.thermalStateAtStart = thermalStateAtStart
        self.thermalStateAtEnd = thermalStateAtEnd
        self.lowPowerMode = lowPowerMode
        self.seconds = seconds
        self.workloads = workloads
    }

    public var historyKey: String { device.key }

    public func result(_ workload: GPUWorkload) -> GPUBenchmarkMeasurement? {
        workloads.first { $0.workload == workload }?.measurement
    }

    /// Workloads whose GPU time fell well short of their wall time (see
    /// `GPUBenchmarkMeasurement.gpuTimeLooksShort`), whose figures may read high.
    public var shortTimedWorkloads: [GPUWorkloadResult] {
        workloads.filter(\.measurement.gpuTimeLooksShort)
    }

    /// "The GPU timed fill rate at 448 ms a repeat, against 498 ms from
    /// commit to completion…", or nil when the two agree.
    public var timingNote: String? {
        let short = shortTimedWorkloads
        guard !short.isEmpty else { return nil }
        let parts = short.map { result in
            let measurement = result.measurement
            return "\(result.workload.title.lowercased()) at \(Format.fixed(measurement.medianGPUSeconds * 1000, 0)) ms a repeat, "
                + "against \(Format.fixed(measurement.medianWallSeconds * 1000, 0)) ms from commit to completion"
        }
        return "The GPU timed " + parts.joined(separator: ", and ") + ". A virtual machine's GPU can under-report its time, "
            + "and other apps' GPU work can hold up a start, so \(short.count == 1 ? "that figure" : "those figures") may read high."
    }

    /// The worse of the thermal states at the start and end.
    public var worstThermalState: ThermalState {
        let order: [ThermalState] = [.nominal, .fair, .serious, .critical]
        return (order.firstIndex(of: thermalStateAtStart) ?? 0) >= (order.firstIndex(of: thermalStateAtEnd) ?? 0)
            ? thermalStateAtStart : thermalStateAtEnd
    }

    /// Whether the figures compare with `other`'s: same workloads, sizes and
    /// GPU. The build doesn't matter: the GPU runs the same shaders in either.
    public func isComparable(with other: Self) -> Bool {
        suiteVersion == other.suiteVersion && configuration == other.configuration && device.key == other.device.key
    }
}

/// How far a running benchmark is.
public struct GPUBenchmarkProgress: Sendable, Equatable {
    public var workload: GPUWorkload
    /// 0...1 through the whole run.
    public var fraction: Double
    /// Workloads measured so far.
    public var measured: [GPUWorkload: GPUBenchmarkMeasurement] = [:]
}

public enum GPUBenchmarkError: Error, Equatable, Sendable {
    /// No Metal GPU is available to apps.
    case noDevice
    /// The GPU can't run the workloads: why, in a few words.
    case unsupported(String)
    /// The GPU stopped a workload with an error.
    case failed(GPUWorkload, String)
    /// The GPU didn't say when it ran the work, so nothing could be timed.
    case noTiming
    /// A result wasn't the expected one.
    case verificationFailed(GPUWorkload)
    case cancelled

    public var message: String {
        switch self {
        case .noDevice:
            "This Mac has no Metal GPU that apps can use, so there's nothing to benchmark."
        case let .unsupported(reason):
            "This GPU can't run the benchmark: \(reason). A virtual machine's GPU often can't."
        case let .failed(workload, reason):
            "The GPU stopped the \(workload.title.lowercased()) workload: \(reason)."
        case .noTiming:
            "This GPU doesn't report when it runs work, so the benchmark can't time it. A virtual machine's GPU often doesn't."
        case let .verificationFailed(workload):
            "The \(workload.title.lowercased()) workload gave a wrong result, so its figures were discarded. "
                + "That points to a GPU or driver fault, or a bug in the benchmark."
        case .cancelled: "The benchmark was cancelled."
        }
    }
}

/// Stops a running benchmark from another thread; it stops before its next submission.
public final class GPUBenchmarkCancellation: Sendable {
    private struct State {
        var cancelled = false
        var heldBackSubmissions = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func cancel() {
        state.withLock { $0.cancelled = true }
    }

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Command buffers the run didn't send because it was cancelled: 1 once
    /// a cancel has stopped it before a submission. Tests read it to tell a
    /// stop before the next submission from one after it.
    var heldBackSubmissions: Int { state.withLock { $0.heldBackSubmissions } }

    /// Whether the run is cancelled, so the command buffer about to be sent
    /// is held back; counts it if so.
    func holdsBackSubmission() -> Bool {
        state.withLock { state in
            if state.cancelled { state.heldBackSubmissions += 1 }
            return state.cancelled
        }
    }
}

/// A GPU benchmark the user starts: FP32 compute, memory and fill-rate
/// workloads in Metal (see `GPUBenchmarkKernels`), compiled from source when
/// the run starts. Each workload warms up, then times a few repeats, each a
/// command buffer of units sized from the warm-up, on the GPU's own clock
/// (`gpuStartTime` to `gpuEndTime`). Every output is checked after every
/// command buffer, warm-up included.
public enum GPUBenchmark {
    /// The workloads' version. Bump it whenever their shaders, inputs, sizes
    /// or arithmetic change, so old results aren't compared with new ones.
    public static let suiteVersion = 1

    /// Warm-up command buffers hold about this much GPU time, so a cancel lands quickly.
    static let warmUpBatchSeconds = 0.1

    /// Runs the benchmark, blocking the calling thread for about
    /// `configuration.plannedSeconds`. Progress comes from the calling thread.
    public static func run(configuration: GPUBenchmarkConfiguration = .standard, appVersion: String,
                           cancellation: GPUBenchmarkCancellation? = nil,
                           progress: (GPUBenchmarkProgress) -> Void = { _ in }) throws(GPUBenchmarkError) -> GPUBenchmarkResult {
        if cancellation?.isCancelled == true { throw .cancelled }
        let started = BenchmarkClock.now
        let date = Date()
        let thermalAtStart = ThermalState(ProcessInfo.processInfo.thermalState)
        guard let device = MTLCreateSystemDefaultDevice() else { throw .noDevice }
        let context = try GPUBenchmarkContext(device: device)
        let workloads = GPUWorkload.allCases
        var report = GPUBenchmarkProgress(workload: workloads[0], fraction: 0)
        progress(report)
        var results: [GPUWorkloadResult] = []
        for (index, workload) in workloads.enumerated() {
            report.workload = workload
            report.fraction = Double(index) / Double(workloads.count)
            progress(report)
            // A workload's buffers live only while it runs, so the run never holds more than one's.
            let measurement = try autoreleasepool {
                Result { () throws(GPUBenchmarkError) -> GPUBenchmarkMeasurement in
                    let runner = try makeRunner(workload, context: context, configuration: configuration)
                    return try measure(runner, context: context, configuration: configuration, cancellation: cancellation) { done in
                        report.fraction = (Double(index) + done) / Double(workloads.count)
                        progress(report)
                    }
                }
            }.get()
            report.measured[workload] = measurement
            results.append(GPUWorkloadResult(workload: workload, measurement: measurement))
        }
        report.fraction = 1
        progress(report)
        return GPUBenchmarkResult(
            date: date, suiteVersion: suiteVersion, configuration: configuration, device: .describe(device),
            osVersion: CPUBenchmark.osVersion, appVersion: appVersion, optimized: CPUBenchmark.isOptimizedBuild,
            thermalStateAtStart: thermalAtStart, thermalStateAtEnd: ThermalState(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            seconds: BenchmarkClock.seconds(since: started), workloads: results
        )
    }

    /// `run` on its own thread, so it doesn't hold a Swift concurrency
    /// thread. Cancelling the calling task stops it before its next submission.
    public static func measure(configuration: GPUBenchmarkConfiguration = .standard, appVersion: String,
                               progress: @escaping @Sendable (GPUBenchmarkProgress) -> Void) async throws(GPUBenchmarkError)
        -> GPUBenchmarkResult {
        try await measure(configuration: configuration, appVersion: appVersion, cancellation: GPUBenchmarkCancellation(), progress: progress)
    }

    /// `measure`, with the cancellation that cancelling the task sets, so a
    /// test can see how the run stopped.
    static func measure(configuration: GPUBenchmarkConfiguration, appVersion: String, cancellation: GPUBenchmarkCancellation,
                        progress: @escaping @Sendable (GPUBenchmarkProgress) -> Void) async throws(GPUBenchmarkError)
        -> GPUBenchmarkResult {
        let outcome: Result<GPUBenchmarkResult, GPUBenchmarkError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    Thread.current.qualityOfService = .userInitiated
                    continuation.resume(returning: Result { () throws(GPUBenchmarkError) -> GPUBenchmarkResult in
                        try run(configuration: configuration, appVersion: appVersion, cancellation: cancellation, progress: progress)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        return try outcome.get()
    }

    /// Units for a command buffer of about `seconds` of GPU time, when one
    /// takes `unitSeconds`: at least one, at most `limit`.
    static func units(forSeconds seconds: Double, unitSeconds: Double, limit: Int) -> Int {
        guard unitSeconds > 0, unitSeconds.isFinite else { return 1 }
        let units = (seconds / unitSeconds).rounded()
        return units >= Double(limit) ? max(limit, 1) : max(Int(units), 1)
    }

    // MARK: - Measuring

    static func makeRunner(_ workload: GPUWorkload, context: GPUBenchmarkContext,
                           configuration: GPUBenchmarkConfiguration) throws(GPUBenchmarkError) -> any GPUWorkloadRunner {
        switch workload {
        case .compute: try GPUComputeRunner(context: context, configuration: configuration)
        case .memory: try GPUMemoryRunner(context: context, configuration: configuration)
        case .fill: try GPUFillRunner(context: context, configuration: configuration)
        }
    }

    /// One workload: a single unit to size the rest, warm-up command buffers
    /// until `warmUpSeconds` have passed, then the timed repeats. `done`
    /// gets the share of the workload finished after each step.
    static func measure(_ runner: any GPUWorkloadRunner, context: GPUBenchmarkContext, configuration: GPUBenchmarkConfiguration,
                        cancellation: GPUBenchmarkCancellation?, done: (Double) -> Void) throws(GPUBenchmarkError)
        -> GPUBenchmarkMeasurement {
        let steps = Double(configuration.repeats + 1)
        let warmUpEnd = BenchmarkClock.now + UInt64(max(configuration.warmUpSeconds, 0) * 1e9)
        var unitSeconds = try submit(runner, units: 1, context: context, cancellation: cancellation).gpu
        while BenchmarkClock.now < warmUpEnd {
            let units = units(forSeconds: warmUpBatchSeconds, unitSeconds: unitSeconds, limit: runner.maximumUnits)
            unitSeconds = try submit(runner, units: units, context: context, cancellation: cancellation).gpu / Double(units)
        }
        done(1 / steps)
        let units = units(forSeconds: configuration.repeatSeconds, unitSeconds: unitSeconds, limit: runner.maximumUnits)
        var measurement = GPUBenchmarkMeasurement(repeats: [], gpuSeconds: [], wallSeconds: [], unitsPerRepeat: units)
        for index in 0..<configuration.repeats {
            let timed = try submit(runner, units: units, context: context, cancellation: cancellation)
            measurement.repeats.append(Double(units) * runner.workPerUnit / timed.gpu)
            measurement.gpuSeconds.append(timed.gpu)
            measurement.wallSeconds.append(timed.wall)
            done(Double(index + 2) / steps)
        }
        return measurement
    }

    /// One command buffer of `units`: cleared outputs, the GPU's own timing,
    /// and every output checked afterwards. Its command buffers are let go
    /// at once, rather than when the thread ends.
    static func submit(_ runner: any GPUWorkloadRunner, units: Int, context: GPUBenchmarkContext,
                       cancellation: GPUBenchmarkCancellation?) throws(GPUBenchmarkError) -> (gpu: Double, wall: Double) {
        if cancellation?.holdsBackSubmission() == true { throw .cancelled }
        return try autoreleasepool {
            Result { () throws(GPUBenchmarkError) -> (gpu: Double, wall: Double) in
                runner.reset()
                guard let buffer = context.queue.makeCommandBuffer() else {
                    throw .failed(runner.workload, "it couldn't make a command buffer")
                }
                try runner.encode(units: units, into: buffer)
                let start = BenchmarkClock.now
                try context.finish(buffer, runner.workload)
                let wall = BenchmarkClock.seconds(since: start)
                let gpu = buffer.gpuEndTime - buffer.gpuStartTime
                guard buffer.gpuStartTime > 0, gpu > 0, gpu.isFinite else { throw .noTiming }
                guard try runner.verify(units: units) else { throw .verificationFailed(runner.workload) }
                return (gpu, wall)
            }
        }.get()
    }
}

public extension SpeedTestHistory where Record == GPUBenchmarkResult {
    /// GPU benchmark results: the last 10 on each Mac.
    static var gpuBenchmark: Self {
        Self(file: defaultFolder.appendingPathComponent("gpu-benchmark.json"), keptPerKey: 10, keptKeys: 5)
    }
}
