import Foundation

/// A domain watched between successful bulk reads. Individual changes are
/// still bounded by two reads, never timed to an instant within that stretch.
public struct LaunchHistoryInterval: Sendable, Codable, Hashable, Identifiable {
    public let start: Date
    public let end: Date
    public var id: Date { start }

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct LaunchHistoryReport: Sendable, Codable, Hashable {
    public let coverage: [LaunchHistoryInterval]
    public let events: [LaunchHistoryEvent]

    public init(coverage: [LaunchHistoryInterval], events: [LaunchHistoryEvent]) {
        self.coverage = coverage
        self.events = events
    }
}

public enum LaunchHistoryCoverage {
    public static let maximumReadGap: TimeInterval = 90

    /// Unions overlapping windows from multiple app copies without counting
    /// their overlap twice. Touching windows also have no coverage hole.
    public static func merged(_ intervals: [LaunchHistoryInterval]) -> [LaunchHistoryInterval] {
        var result: [LaunchHistoryInterval] = []
        for interval in intervals.filter({ $0.end >= $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = LaunchHistoryInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    public static func watches(_ intervals: [LaunchHistoryInterval], from start: Date, to end: Date) -> Bool {
        merged(intervals).contains { $0.start <= start && $0.end >= end }
    }

    public static func seconds(_ intervals: [LaunchHistoryInterval], from start: Date, to end: Date) -> TimeInterval {
        merged(intervals).reduce(0) { $0 + max(0, min($1.end, end).timeIntervalSince(max($1.start, start))) }
    }

    public static func caption(_ intervals: [LaunchHistoryInterval], at end: Date) -> String {
        let minutes = Int(seconds(intervals, from: end.addingTimeInterval(-86_400), to: end) / 60)
        let duration = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "Watched \(duration) of the last 24 h; changes between reads are bounded, not timed"
    }

    /// Each day once, then its watched spans: "Oct 8, 2026: 9:05 AM–9:07 AM, 9:09 AM–9:12 AM".
    /// A span that runs past midnight names its end's day too.
    public static func spansText(_ intervals: [LaunchHistoryInterval], calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                                   timeZone: calendar.timeZone)
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                    timeZone: calendar.timeZone)
        var days: [(day: String, spans: [String])] = []
        for interval in merged(intervals) {
            let start = interval.start.formatted(day)
            let end = calendar.isDate(interval.start, inSameDayAs: interval.end)
                ? interval.end.formatted(time) : "\(interval.end.formatted(day)) \(interval.end.formatted(time))"
            let span = "\(interval.start.formatted(time))–\(end)"
            if days.last?.day == start {
                days[days.count - 1].spans.append(span)
            } else {
                days.append((start, [span]))
            }
        }
        return days.map { "\($0.day): \($0.spans.joined(separator: ", "))" }.joined(separator: "; ")
    }
}

/// One row started, or the same row's end moved on; no row per job or read.
struct LaunchHistoryReadChange: Sendable {
    let domain: String
    let interval: LaunchHistoryInterval
    let extends: Bool
}

struct LaunchHistoryReadTracker: Sendable {
    private var open: [String: LaunchHistoryInterval] = [:]
    private var last: [String: Date] = [:]
    var domains: Set<String> { Set(last.keys) }

    mutating func interrupt(domain: String, at time: Date) {
        guard last[domain].map({ time >= $0 }) ?? true else { return }
        open[domain] = nil
        last[domain] = time
    }

    mutating func observe(domain: String, at time: Date) -> LaunchHistoryReadChange? {
        guard last[domain].map({ time > $0 }) ?? true else { return nil }
        let before = open[domain]
        let extends = before.map { time.timeIntervalSince($0.end) <= LaunchHistoryCoverage.maximumReadGap } ?? false
        let interval = LaunchHistoryInterval(start: extends ? before?.start ?? time : time, end: time)
        open[domain] = interval
        last[domain] = time
        return LaunchHistoryReadChange(domain: domain, interval: interval, extends: extends)
    }
}
