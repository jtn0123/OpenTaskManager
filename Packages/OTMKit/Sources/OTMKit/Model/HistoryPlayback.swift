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
