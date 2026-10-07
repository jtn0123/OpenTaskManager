import Foundation

/// Steps the History page's pinned moment through recorded points, to play
/// a recording back at 1×, 10× or 60× its own pace.
///
/// Playback keeps the recording's clock: points a minute apart are a minute
/// apart at 1×. A gap (the app wasn't running, or the Mac slept) is crossed
/// in one jump, never filled in, and takes its own time too, up to
/// `longestGapWait`. Steps are never closer than `shortestStep`, so faster
/// playback skips points rather than redrawing the page more often.
public enum HistoryPlayback {
    public static let speeds: [Double] = [1, 10, 60]
    /// The least time between steps: the fastest the pinned moment moves.
    /// Each step redraws the moment panel and the markers (never the
    /// charts), so twice a second keeps 60× playback light.
    public static let shortestStep: TimeInterval = 0.5
    /// The most time a gap takes to cross, however long it was.
    public static let longestGapWait: TimeInterval = 3

    public struct Step: Sendable, Equatable {
        /// The point to pin next.
        public let time: Date
        /// Seconds to wait before pinning it.
        public let delay: TimeInterval
        /// Set when the step jumps a gap: the seconds between the points on
        /// either side of it.
        public let gap: TimeInterval?

        public init(time: Date, delay: TimeInterval, gap: TimeInterval? = nil) {
            self.time = time
            self.delay = delay
            self.gap = gap
        }
    }

    /// Where Play starts among `points`: from the pinned moment (a moment
    /// picked to play from), else on from the playhead, where playback was
    /// paused, whichever is set and lies before the last point; else nil,
    /// the first point.
    public static func start(playhead: Date?, pinned: Date?, in points: [HistoryPoint]) -> Date? {
        guard let first = points.first?.time, let last = points.last?.time else { return nil }
        return [pinned, playhead].compactMap { $0 }.first { $0 >= first && $0 < last }
    }

    /// The step after the moment `current` among `points` (oldest first,
    /// numbered by `HistoryPoint.segmented`), or nil once playback reaches
    /// the last point. With no current moment, or one before the first
    /// point, playback starts on the first point at once.
    public static func step(after current: Date?, in points: [HistoryPoint], speed: Double) -> Step? {
        guard speed > 0, let first = points.first else { return nil }
        guard let current, current >= first.time else { return Step(time: first.time, delay: 0) }
        guard let next = points.firstIndex(where: { $0.time > current }) else { return nil }
        let segment = points[next].segment
        if points[next - 1].segment != segment {
            let wait = points[next].time.timeIntervalSince(current) / speed
            return Step(time: points[next].time, delay: min(max(wait, shortestStep), longestGapWait),
                        gap: points[next].time.timeIntervalSince(points[next - 1].time))
        }
        // Skip ahead until the step takes at least `shortestStep`, but never
        // over a gap: the last point before one is always shown.
        let target = current.addingTimeInterval(speed * shortestStep)
        var index = next
        while points[index].time < target, index + 1 < points.count, points[index + 1].segment == segment {
            index += 1
        }
        let delay = points[index].time.timeIntervalSince(current) / speed
        return Step(time: points[index].time, delay: max(delay, shortestStep))
    }
}

/// Which moment the History page's side panel shows, and what it's called:
/// the one under the pointer, else one pinned with a click, else where
/// playback has reached, else the latest (a recording file's end). So the
/// panel follows playback whenever no preview or pin is set apart from it.
public enum HistoryFocus: Sendable, Equatable {
    /// The moment under the pointer.
    case preview(Date)
    /// A moment picked with a click or drag, held while playback moves on.
    case pinned(Date)
    /// Where playback has reached, playing or paused.
    case playback(Date, playing: Bool)
    /// The last moment recorded.
    case end

    public init(hovered: Date?, pinned: Date?, playhead: Date?, isPlaying: Bool) {
        if let hovered {
            self = .preview(hovered)
        } else if let pinned {
            self = .pinned(pinned)
        } else if let playhead {
            self = .playback(playhead, playing: isPlaying)
        } else {
            self = .end
        }
    }

    /// The moment shown; nil for the end, which is the last point.
    public var time: Date? {
        switch self {
        case .preview(let time), .pinned(let time), .playback(let time, _): time
        case .end: nil
        }
    }
}
