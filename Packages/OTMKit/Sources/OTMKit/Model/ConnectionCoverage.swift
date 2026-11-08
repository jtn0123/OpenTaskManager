import Foundation

/// Coverage stops at the last real walk. A single look has no observed duration.
public struct ConnectionWatchInterval: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var start: Date
    public var end: Date
    public let spacing: TimeInterval
    /// The largest unreadable-process count in this interval, not an invented socket count.
    public var hiddenProcesses: Int
    public var walks: Int

    public init(id: String = UUID().uuidString, start: Date, end: Date, spacing: TimeInterval,
                hiddenProcesses: Int, walks: Int = 1) {
        self.id = id
        self.start = start
        self.end = end
        self.spacing = spacing
        self.hiddenProcesses = hiddenProcesses
        self.walks = walks
    }
}

public struct ConnectionCoverageTracker: Sendable {
    private var current: ConnectionWatchInterval?
    public init() {}

    public mutating func observe(at time: Date, spacing: TimeInterval, hidden: Int) -> ConnectionWatchInterval {
        if var interval = current, interval.spacing == spacing, time >= interval.end,
           time.timeIntervalSince(interval.end) <= spacing * 2 + 1 {
            interval.end = time
            interval.hiddenProcesses = max(interval.hiddenProcesses, hidden)
            interval.walks += 1
            current = interval
            return interval
        }
        // Changing cadence keeps the last real sighting as the new interval's start when the walks still follow on.
        let previous = current.flatMap { interval in
            time >= interval.end && time.timeIntervalSince(interval.end) <= max(spacing, interval.spacing) * 2 + 1 ? interval : nil
        }
        let interval = ConnectionWatchInterval(start: previous?.end ?? time, end: time, spacing: spacing,
                                               hiddenProcesses: max(hidden, previous?.hiddenProcesses ?? 0),
                                               walks: previous == nil ? 1 : 2)
        current = interval
        return interval
    }

    public mutating func stop() { current = nil }
}

public struct ConnectionHistoryCoverage: Sendable, Codable {
    public let from: Date
    public let to: Date
    public let intervals: [ConnectionWatchInterval]
    public let droppedRows: Int

    public init(from: Date, to: Date, intervals: [ConnectionWatchInterval], droppedRows: Int = 0) {
        self.from = from
        self.to = to
        self.intervals = intervals.compactMap { interval in
            guard interval.end >= from, interval.start <= to else { return nil }
            var clipped = interval
            clipped.start = max(from, interval.start)
            clipped.end = min(to, interval.end)
            return clipped
        }.sorted { $0.start < $1.start }
        self.droppedRows = droppedRows
    }

    public var watchedSeconds: TimeInterval {
        var end = from
        var seconds: TimeInterval = 0
        for interval in intervals {
            seconds += max(0, interval.end.timeIntervalSince(max(end, interval.start)))
            end = max(end, interval.end)
        }
        return seconds
    }

    /// Includes leading and trailing unwatched stretches, not just holes between visits.
    public var gaps: Int {
        var end = from
        var count = 0
        for interval in intervals {
            if interval.start > end { count += 1 }
            end = max(end, interval.end)
        }
        if end < to { count += 1 }
        return count
    }

    public func isWatched(at time: Date) -> Bool {
        intervals.contains { time >= $0.start && time <= $0.end }
    }

    public var summary: String {
        let span = Format.timeSpan(max(0, to.timeIntervalSince(from)))
        var words = "Watched \(Format.timeSpan(watchedSeconds)) of \(span) · " + Self.count(gaps, "gap", "gaps")
        if let hidden = intervals.map(\.hiddenProcesses).max(), hidden > 0 {
            words += " · up to " + Self.count(hidden, "process", "processes") + " unreadable per interval"
        }
        if droppedRows > 0 { words += " · " + Self.count(droppedRows, "oldest lifetime", "oldest lifetimes") + " dropped at the row limit" }
        return words
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    public var watchedWords: String {
        guard !intervals.isEmpty else { return "Not watched in this range. Absence from history does not mean no connection." }
        // Each day is named once, as Startup's watched spans are: "Oct 8, 2026: 10:07 AM–10:09 AM, 2:15 PM–2:20 PM".
        let spans = LaunchHistoryCoverage.merged(intervals.map { LaunchHistoryInterval(start: $0.start, end: $0.end) })
        let remaining = spans.count > 8 ? " and \(spans.count - 8) more intervals" : ""
        return "Watched " + LaunchHistoryCoverage.spansText(Array(spans.prefix(8))) + remaining + ". Other stretches were not watched."
    }
}
