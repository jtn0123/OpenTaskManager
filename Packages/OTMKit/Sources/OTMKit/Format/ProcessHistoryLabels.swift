import Foundation

/// Missing busy figures mean idle only where a watched record says so.
/// A lifetime alone never fills a gap with an idle reading.
public enum ProcessHistoryLabels {
    public static let idleSummary = "Idle throughout: no busy figures kept"
    public static let idleMoment = "Idle (not kept)"
    public static let notRecorded = "Not recorded"

    public enum Moment: Sendable, Equatable {
        case figures(ProcessHistoryPoint)
        case idle
        case notRunning
        case notRecorded
    }

    public static func moment(of lifetime: ProcessLifetime, at time: Date, points: [ProcessHistoryPoint],
                              bucket: TimeInterval) -> Moment {
        if time < lifetime.started.addingTimeInterval(-bucket) { return .notRunning }
        if let ended = lifetime.ended, time > ended.addingTimeInterval(bucket) { return .notRunning }
        guard let point = ProcessHistoryPoint.at(time, in: points, bucket: bucket) else { return .notRecorded }
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
