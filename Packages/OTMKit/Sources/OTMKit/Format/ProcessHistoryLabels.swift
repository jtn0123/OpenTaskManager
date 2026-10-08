import Foundation

/// Missing busy figures mean idle only where a watched record says so.
/// A lifetime alone never fills a gap with an idle reading.
public enum ProcessHistoryLabels {
    public static let idleSummary = "Idle throughout: no busy figures kept"
    public static let memoryOnly = "Memory only: changes of 10% or 16 MB, CPU and disk stayed under the history's floors"

    public static func memoryMoment(_ step: ProcessMemoryStep) -> String {
        "\(step.measure.title) about \(Format.bytes(step.footprint)) (from the memory track)"
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
        case notRunning
        case notRecorded
    }

    public static func moment(of lifetime: ProcessLifetime, at time: Date, points: [ProcessHistoryPoint],
                              bucket: TimeInterval, memory: [ProcessMemoryStep] = [], coverage: [ClosedRange<Date>] = []) -> Moment {
        if time < lifetime.started.addingTimeInterval(-bucket) { return .notRunning }
        if let ended = lifetime.ended, time > ended.addingTimeInterval(bucket) { return .notRunning }
        // Memory coverage uses the actual records, not a coarse bucket's reach.
        if !memory.isEmpty, !coverage.contains(where: { $0.contains(time) }) { return .notRecorded }
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
