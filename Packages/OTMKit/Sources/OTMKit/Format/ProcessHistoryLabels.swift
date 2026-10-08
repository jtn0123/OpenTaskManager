import Foundation

/// Missing busy figures mean idle only where a watched record says so.
/// A lifetime alone never fills a gap with an idle reading.
public enum ProcessHistoryLabels {
    public static let idleSummary = "Idle throughout: no busy figures kept"
    public static let memoryOnly = "Memory only: changes of 10% or 16 MB, CPU and disk stayed under the history's floors"

    public static func memoryMoment(_ step: ProcessMemoryStep) -> String {
        "\(step.measure.title) about \(Format.bytes(step.footprint)) (from the memory track)"
    }

    public static func latestMemoryMoment(_ step: ProcessMemoryStep) -> String {
        "\(step.measure.title) about \(Format.bytes(step.footprint)) at "
            + "\(step.time.formatted(date: .omitted, time: .standard)), the latest record"
    }

    public static func growth(_ bytes: Int64) -> String {
        let sign = bytes >= 0 ? "+" : "−"
        return "\(sign)\(Format.bytes(bytes.magnitude)) since first seen"
    }

    public static let idleMoment = "Idle (not kept)"
    public static let notRecorded = "Not recorded"

    public enum Moment: Sendable, Equatable {
        case figures(ProcessHistoryPoint)
        case idle
        case memory(ProcessMemoryStep)
        case latestMemory(ProcessMemoryStep)
        case notRunning
        /// Gone by now, but it went while nothing watched, so its end is unknown.
        case notSeenAfter(Date)
        case notRecorded
    }

    /// "Not seen after 11:07:19 AM": never "not running", which the gap
    /// between its last sighting and the next watched record can't tell.
    public static func notSeen(after date: Date) -> String {
        "Not seen after \(date.formatted(date: .omitted, time: .standard))"
    }

    public static func moment(of lifetime: ProcessLifetime, at time: Date, points: [ProcessHistoryPoint],
                              bucket: TimeInterval, memory: [ProcessMemoryStep] = [], coverage: [ClosedRange<Date>] = [],
                              isGone: Bool = false, recordSpan: TimeInterval = 10) -> Moment {
        if time < lifetime.started.addingTimeInterval(-bucket) { return .notRunning }
        if let ended = lifetime.ended, time > ended.addingTimeInterval(bucket) { return .notRunning }
        // `isGone`: not running now, though no record saw it end.
        if lifetime.ended == nil, isGone, time > lifetime.lastSeen.addingTimeInterval(bucket) {
            return .notSeenAfter(lifetime.lastSeen)
        }
        // Memory coverage uses the actual records, not a coarse bucket's reach.
        if !memory.isEmpty, !coverage.contains(where: { $0.contains(time) }) {
            // Only the unfinished record at the live edge can show an older kept figure.
            // A stopped watch or an internal gap cannot borrow one from earlier coverage.
            if lifetime.ended == nil, !isGone, recordSpan.isFinite, recordSpan > 0,
               let end = coverage.max(by: { $0.upperBound < $1.upperBound })?.upperBound,
               time > end, time.timeIntervalSince(end) <= recordSpan,
               let step = ProcessMemoryTrack.figure(at: end, steps: memory, coverage: coverage), step.edges & 2 == 0 {
                return .latestMemory(step)
            }
            return .notRecorded
        }
        guard let point = ProcessHistoryPoint.at(time, in: points, bucket: bucket) else { return .notRecorded }
        if point.state == .idle, !memory.isEmpty {
            guard let step = ProcessMemoryTrack.figure(at: time, steps: memory, coverage: coverage) else { return .notRecorded }
            return .memory(step)
        }
        return point.state == .idle ? .idle : .figures(point)
    }

    /// The real start, rather than the range's clipped start. A running
    /// lifetime's duration stops at its last sighting, never a ticking clock.
    public static func lifetime(_ lifetime: ProcessLifetime, isRunning: Bool) -> String {
        let style: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute().second()
        let end = lifetime.ended ?? lifetime.lastSeen
        let state = isRunning ? "Still running" : "\(lifetime.ended == nil ? "Last seen" : "Ended") \(end.formatted(style))"
        let duration = Format.roughDuration(max(end.timeIntervalSince(lifetime.started), 0))
        return "Started \(lifetime.started.formatted(style)) · \(state) · \(duration)\(isRunning ? " at last sighting" : "")"
    }
}
