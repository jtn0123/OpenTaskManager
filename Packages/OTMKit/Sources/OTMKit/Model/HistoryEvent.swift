import Foundation

/// Something that happened on the Mac while the flight recorder ran, kept
/// beside its records so the History page can line a spike up with what
/// coincided with it: an app launched or quit, a busy background process
/// started or exited, the network changed, the Mac went to sleep or woke, a
/// spike was captured.
///
/// Most times come from notifications and are exact. Process starts and
/// exits are found by comparing one update's process list with the next
/// (`ProcessEventTracker`), so an exit, and a start whose process didn't say
/// when it began, is only known to within the update interval:
/// `isApproximate`.
public struct HistoryEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        case appLaunched
        case appQuit
        /// A background process that became busy (`ProcessEventTracker.busyPercent`).
        case processStarted
        /// A process that had been busy, gone.
        case processExited
        /// The network in use changed, or there's none now.
        case networkChanged
        case sleep
        case wake
        /// The spike recorder kept a capture (`SpikeTrigger.event`): the
        /// kind that crossed as its name, what crossed as its detail.
        case spike
    }

    public var id: String { "\(time.timeIntervalSince1970) \(kind.rawValue) \(name)" }
    public let time: Date
    public let kind: Kind
    /// The app or process; for a network change, the network now in use
    /// ("Wi-Fi (en0)"), empty when there's none.
    public let name: String
    /// A word more: an app's bundle ID, the address a network change brought.
    public let detail: String
    /// How many of a kind and name happened together: a build's compiler
    /// runs, started within a few seconds of each other.
    public let count: Int
    /// The time is only known to within the update interval.
    public let isApproximate: Bool

    public init(time: Date, kind: Kind, name: String, detail: String = "", count: Int = 1, isApproximate: Bool = false) {
        self.time = time
        self.kind = kind
        self.name = name
        self.detail = detail
        self.count = max(count, 1)
        self.isApproximate = isApproximate
    }

    /// The events in `events` (oldest first) from `before` seconds before
    /// `time` to `after` seconds after it.
    public static func near(_ time: Date, in events: [HistoryEvent], before: TimeInterval, after: TimeInterval) -> [HistoryEvent] {
        let from = time.addingTimeInterval(-before)
        let to = time.addingTimeInterval(after)
        var low = 0
        var high = events.count
        while low < high {
            let middle = (low + high) / 2
            if events[middle].time < from { low = middle + 1 } else { high = middle }
        }
        return Array(events[low...].prefix { $0.time <= to })
    }

    /// `events` (oldest first) with those of one kind and name less than
    /// `window` seconds after the first of them folded into it: one event,
    /// at the first one's time, with their count, approximate if any was.
    public static func merged(_ events: [HistoryEvent], within window: TimeInterval) -> [HistoryEvent] {
        var merged: [HistoryEvent] = []
        /// Where each kind and name's latest group sits in `merged`.
        var open: [String: Int] = [:]
        for event in events {
            let key = event.kind.rawValue + "\u{1F}" + event.name
            if let index = open[key], event.time.timeIntervalSince(merged[index].time) < window {
                let first = merged[index]
                merged[index] = HistoryEvent(time: first.time, kind: first.kind, name: first.name, detail: first.detail,
                                             count: first.count + event.count, isApproximate: first.isApproximate || event.isApproximate)
            } else {
                open[key] = merged.count
                merged.append(event)
            }
        }
        return merged
    }

    /// `events` (oldest first) in runs whose neighbours are no more than
    /// `spacing` seconds apart: what one marker on a timeline stands for,
    /// where events closer than a few points would draw over each other.
    public static func clusters(_ events: [HistoryEvent], spacing: TimeInterval) -> [[HistoryEvent]] {
        var clusters: [[HistoryEvent]] = []
        for event in events {
            if let last = clusters.last?.last, event.time.timeIntervalSince(last.time) <= spacing {
                clusters[clusters.count - 1].append(event)
            } else {
                clusters.append([event])
            }
        }
        return clusters
    }
}

extension HistoryPoint {
    /// The point among `points` (oldest first, each averaging the `bucket`
    /// seconds up to its time) whose stretch holds `time`, else the nearest:
    /// where the History page puts its playhead for an event.
    public static func covering(_ time: Date, in points: [HistoryPoint], bucket: TimeInterval) -> HistoryPoint? {
        if let after = points.first(where: { $0.time >= time }), after.time.timeIntervalSince(time) < bucket {
            return after
        }
        return nearest(to: time, in: points)
    }
}
