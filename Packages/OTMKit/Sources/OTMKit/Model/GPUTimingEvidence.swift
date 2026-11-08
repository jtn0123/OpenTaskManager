import Foundation

/// Timing is evidence about the clock, separate from checking the workload's output.
public struct GPUTimingEvidence: Sendable, Codable, Equatable {
    /// Seconds on one clock. Counter and command-buffer intervals use Metal's CPU time base.
    public struct Interval: Sendable, Codable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        public var seconds: Double { end - start }
        public var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && seconds > 0 && seconds.isFinite }
    }

    public enum Qualification: String, Sendable, Codable {
        case noCounterSampling, counterSamplesUnavailable, countersDisagreed, gpuTimeShort, missingTiming, notRecorded

        public var reason: String {
            switch self {
            case .noCounterSampling: "No render-pass counter sampling on this GPU."
            case .counterSamplesUnavailable: "Render-pass counter samples were unavailable or non-monotonic."
            case .countersDisagreed: "Render-pass counters disagreed with the command-buffer interval."
            case .gpuTimeShort: "Command-buffer GPU time fell short of commit-to-completion wall time."
            case .missingTiming: "Command-buffer or wall timing was missing or invalid."
            case .notRecorded: "Render-pass timing evidence was not recorded in this saved result."
            }
        }
    }

    public enum Verdict: Sendable, Codable, Equatable {
        case verified
        case qualified(Qualification)

        public var isVerified: Bool { self == .verified }
        public var text: String {
            switch self {
            case .verified: "Timing verified"
            case let .qualified(reason): "Timing unverified: " + reason.reason
            }
        }
    }

    /// A simultaneous CPU/GPU clock reading. Metal supplies CPU nanoseconds and GPU ticks.
    public struct ClockSample: Sendable, Equatable {
        public var cpuNanoseconds: UInt64
        public var gpuTicks: UInt64

        public init(cpuNanoseconds: UInt64, gpuTicks: UInt64) {
            self.cpuNanoseconds = cpuNanoseconds
            self.gpuTicks = gpuTicks
        }
    }

    public var counterInterval: Interval?
    public var commandBufferInterval: Interval?
    /// Commit to completion, excluding counter resolution and output verification.
    public var wallInterval: Interval?
    public var unavailableReason: Qualification

    public init(counterInterval: Interval?, commandBufferInterval: Interval?, wallInterval: Interval?,
                unavailableReason: Qualification = .noCounterSampling) {
        self.counterInterval = counterInterval
        self.commandBufferInterval = commandBufferInterval
        self.wallInterval = wallInterval
        self.unavailableReason = unavailableReason
    }

    /// One millisecond allows for the clock-pair sampling skew, without hiding a materially different interval.
    public static let containmentTolerance = 0.001
    public static let fillExclusion = "Fill rate left out: timing not verified on this GPU"
    public static let fillInterval = "Pixels blended divided by time from the first pass's vertex start to the last pass's fragment end. "
        + "Render passes only; no resolves, stores into other targets, or command-buffer scheduling. "
        + "Where render-pass counters are unavailable, command-buffer GPU time is used."

    public var verdict: Verdict {
        guard let commandBufferInterval, commandBufferInterval.isValid, let wallInterval, wallInterval.isValid else {
            return .qualified(.missingTiming)
        }
        if Self.gpuTimeLooksShort(gpu: commandBufferInterval.seconds, wall: wallInterval.seconds) {
            return .qualified(.gpuTimeShort)
        }
        guard let counterInterval else { return .qualified(unavailableReason) }
        guard counterInterval.isValid else { return .qualified(.counterSamplesUnavailable) }
        guard counterInterval.start >= commandBufferInterval.start - Self.containmentTolerance,
              counterInterval.end <= commandBufferInterval.end + Self.containmentTolerance else {
            return .qualified(.countersDisagreed)
        }
        return .verified
    }

    public static func gpuTimeLooksShort(gpu: Double, wall: Double) -> Bool {
        let gap = wall - gpu
        return gap > 0.005 && gap > 0.05 * wall
    }

    /// Subtract integer timestamps before conversion so large clock epochs keep small tick differences.
    public static func counterInterval(start: UInt64?, end: UInt64?, before: ClockSample?, after: ClockSample?) -> Interval? {
        guard let start, let end, let before, let after,
              start != UInt64.max, end != UInt64.max,
              before.cpuNanoseconds != UInt64.max, after.cpuNanoseconds != UInt64.max,
              before.gpuTicks != UInt64.max, after.gpuTicks != UInt64.max,
              after.cpuNanoseconds > before.cpuNanoseconds, after.gpuTicks > before.gpuTicks,
              end > start, start >= before.gpuTicks, end <= after.gpuTicks else { return nil }
        let secondsPerTick = Double(after.cpuNanoseconds - before.cpuNanoseconds) / 1e9 / Double(after.gpuTicks - before.gpuTicks)
        let first = Double(before.cpuNanoseconds) / 1e9 + Double(start - before.gpuTicks) * secondsPerTick
        let interval = Interval(start: first, end: first + Double(end - start) * secondsPerTick)
        return interval.isValid ? interval : nil
    }
}

public extension GPUBenchmarkMeasurement {
    /// Every repeat must carry valid evidence; a median must not hide one suspect clock reading.
    var fillTimingVerdict: GPUTimingEvidence.Verdict {
        guard let timingEvidence, !repeats.isEmpty, timingEvidence.count == repeats.count else { return .qualified(.notRecorded) }
        return timingEvidence.map(\.verdict).first { !$0.isVerified } ?? .verified
    }

    var timingSource: String {
        guard let timingEvidence, !timingEvidence.isEmpty else { return "command buffer" }
        let counters = timingEvidence.count { $0.counterInterval?.isValid == true }
        if counters == timingEvidence.count { return "render-pass counters" }
        return counters == 0 ? "command buffer" : "render-pass counters / command buffer (mixed repeats)"
    }

    func timingCaveat(for workload: GPUWorkload) -> BenchmarkFigureCaveat? {
        if gpuTimeLooksShort { return .timingUnverified }
        return workload == .fill && !fillTimingVerdict.isVerified ? .renderTimingUnverified : nil
    }

    func timingDescription(for workload: GPUWorkload) -> String {
        if workload == .fill { return fillTimingVerdict.text + ". " + GPUTimingEvidence.fillInterval }
        return gpuTimeLooksShort ? GPUTimingEvidence.Verdict.qualified(.gpuTimeShort).text : "Timing verdict: command-buffer GPU timing only"
    }
}
