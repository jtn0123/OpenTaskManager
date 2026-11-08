import Foundation

/// The sampler's two memory readings have different meanings. Each observed
/// stretch uses one measure; changing it starts another line, never a join.
public enum ProcessMemoryMeasure: String, Sendable, Codable {
    case footprint
    case resident

    public var title: String { self == .footprint ? "Footprint" : "Resident" }
}

public struct ProcessMemoryStep: Sendable, Equatable, Codable {
    public let time: Date
    public let footprint: UInt64
    public let measure: ProcessMemoryMeasure
    /// Bit 1 starts an observed stretch; bit 2 closes it at its last reading.
    public var edges: Int

    public init(time: Date, footprint: UInt64, measure: ProcessMemoryMeasure, edges: Int = 0) {
        self.time = time
        self.footprint = footprint
        self.measure = measure
        self.edges = edges
    }
}

/// One value change, with no array allocation for an individual process.
public struct ProcessMemoryUpdate: Sendable, Equatable {
    public let identity: ProcessIdentity
    public let step: ProcessMemoryStep?
    public let peak: ProcessMemoryStep?

    public init(identity: ProcessIdentity, step: ProcessMemoryStep? = nil, peak: ProcessMemoryStep? = nil) {
        self.identity = identity
        self.step = step
        self.peak = peak
    }
}

public enum ProcessMemoryKeep {
    public static let minimumChange: UInt64 = 16 * 1_024 * 1_024
    public static let maximumSpacing: TimeInterval = 30 * 60

    public static func keeps(_ next: ProcessMemoryStep, after previous: ProcessMemoryStep) -> Bool {
        guard next.measure == previous.measure else { return true }
        let change = next.footprint >= previous.footprint ? next.footprint - previous.footprint : previous.footprint - next.footprint
        guard change > 0 else { return false }
        return Double(change) >= max(Double(previous.footprint) * 0.1, Double(minimumChange))
            || next.time.timeIntervalSince(previous.time) >= maximumSpacing
    }
}

/// Lives inside the tracker's existing counter entry, not in another map.
/// The first reading waits with a deferred start until it earns a lifetime.
struct ProcessMemoryState: Sendable, Equatable {
    var first: ProcessMemoryStep
    var stored: ProcessMemoryStep?
    var latest: ProcessMemoryStep
    var peak: ProcessMemoryStep
    var reportedPeak: ProcessMemoryStep?

    init(_ process: ProcessSample, at time: Date) {
        let step = ProcessMemoryStep(time: time, footprint: process.memory,
                                     measure: process.isRestricted ? .resident : .footprint, edges: 1)
        first = step
        latest = step
        peak = step
    }

    mutating func record(_ process: ProcessSample, at time: Date, ending: Bool = false, reportPeak: Bool = true,
                         into updates: inout [ProcessMemoryUpdate]) {
        record(ProcessMemoryStep(time: time, footprint: process.memory,
                                 measure: process.isRestricted ? .resident : .footprint), identity: process.identity,
               ending: ending, reportPeak: reportPeak, into: &updates)
    }

    mutating func record(_ next: ProcessMemoryStep, identity: ProcessIdentity, ending: Bool = false, reportPeak: Bool = true,
                         into updates: inout [ProcessMemoryUpdate]) {
        if latest.measure != next.measure {
            var end = latest
            end.edges |= 2
            updates.append(ProcessMemoryUpdate(identity: identity, step: end))
            first = ProcessMemoryStep(time: next.time, footprint: next.footprint, measure: next.measure, edges: 1)
            stored = nil
            peak = first
            reportedPeak = nil
        }
        latest = next
        if next.footprint > peak.footprint { peak = next }
        if stored == nil {
            updates.append(ProcessMemoryUpdate(identity: identity, step: first, peak: reportPeak ? peak : nil))
            stored = first
            if reportPeak { reportedPeak = peak }
        }
        var step: ProcessMemoryStep?
        if let stored, ending || ProcessMemoryKeep.keeps(next, after: stored) {
            var kept = next
            if ending { kept.edges |= 2 }
            step = kept
            self.stored = kept
        }
        let newPeak = reportPeak && reportedPeak != peak ? peak : nil
        if step != nil || newPeak != nil {
            updates.append(ProcessMemoryUpdate(identity: identity, step: step, peak: newPeak))
            if reportPeak { reportedPeak = peak }
        }
    }
}

/// Chart points are prepared only when a lifetime is selected. Coverage
/// comes from real records, while step edges bound this process's watching.
public struct ProcessMemoryPoint: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let time: Date
    public let footprint: UInt64
    public let measure: ProcessMemoryMeasure
    public let segment: Int
}

public enum ProcessMemoryTrack {
    public static func figure(at time: Date, steps: [ProcessMemoryStep], coverage: [ClosedRange<Date>]) -> ProcessMemoryStep? {
        guard let stretch = coverage.first(where: { $0.contains(time) }),
              let step = steps.last(where: { $0.time <= time }) else { return nil }
        // An interrupted app may not have written its final edge. A new
        // watch after a gap cannot inherit that run's held figure.
        if step.time < stretch.lowerBound,
           let restart = steps.first(where: { $0.time >= stretch.lowerBound && $0.time <= stretch.upperBound && $0.edges & 1 != 0 }),
           restart.time > time,
           !steps.contains(where: { $0.time >= stretch.lowerBound && $0.time < restart.time && $0.edges & 2 != 0 }) {
            return nil
        }
        if step.edges & 2 != 0 && time > step.time { return nil }
        return step
    }

    /// Extends each held reading only through watched time, ending a line
    /// before any gap or measure change. No per-record chart rows are made.
    public static func points(steps: [ProcessMemoryStep], coverage: [ClosedRange<Date>]) -> [ProcessMemoryPoint] {
        var result: [ProcessMemoryPoint] = []
        var segment = 0
        for stretch in coverage {
            var held = figure(at: stretch.lowerBound, steps: steps, coverage: coverage)
            func append(_ step: ProcessMemoryStep, at time: Date) {
                result.append(ProcessMemoryPoint(index: result.count, time: time, footprint: step.footprint,
                                                 measure: step.measure, segment: segment))
            }
            if let figure = held {
                append(figure, at: stretch.lowerBound)
                if figure.edges & 2 != 0 {
                    held = nil
                    segment += 1
                }
            }
            for step in steps where step.time > stretch.lowerBound && step.time <= stretch.upperBound {
                if step.edges & 1 != 0 { segment += 1 }
                append(step, at: step.time)
                held = step.edges & 2 == 0 ? step : nil
                if held == nil { segment += 1 }
            }
            if let held { append(held, at: stretch.upperBound) }
            segment += 1
        }
        return result
    }
}

public enum ProcessHistorySort: String, Sendable, CaseIterable {
    case latest
    case grew
}
