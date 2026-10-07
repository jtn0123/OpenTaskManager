import Foundation

/// A stretch of a history graph with nothing recorded: the app wasn't
/// running, the Mac slept, or updates were paused. Graphs break their lines
/// and fills across one and mark it, rather than draw the values dropping.
public struct HistoryGap: Sendable, Equatable, Identifiable {
    /// Points further apart than this many buckets have a gap between them
    /// (`FlightRecorder.points` numbers the segments the same way).
    public static let spacing = 2.5

    public var id: Date { start }
    /// Where recording stopped: the last recorded moment before the gap, or
    /// the start of the range shown.
    public let start: Date
    /// Where recording picked up again: the start of the stretch the next
    /// point averages, or the end of the range shown.
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(end, start)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Whether `time` falls in the gap. One narrower than `minimumSpan`
    /// seconds counts as that wide around its middle, so a hairline gap can
    /// still be pointed at.
    public func contains(_ time: Date, minimumSpan: TimeInterval = 0) -> Bool {
        let widen = max(minimumSpan - duration, 0) / 2
        return time >= start.addingTimeInterval(-widen) && time <= end.addingTimeInterval(widen)
    }

    /// The gaps among `points` (oldest first, numbered by
    /// `HistoryPoint.segmented`), each point averaging the `bucket` seconds
    /// up to its time: one wherever the segment changes and, given the range
    /// shown, one at either end where the first or last point sits more than
    /// `spacing` buckets from its edge. A leading one never reaches back
    /// before `earliest`, the first record kept: before that the recorder
    /// hadn't started, which the graphs show as "not recorded yet" instead.
    public static func gaps(in points: [HistoryPoint], bucket: TimeInterval, within domain: ClosedRange<Date>? = nil,
                            since earliest: Date? = nil) -> [HistoryGap] {
        guard let first = points.first, let last = points.last else { return [] }
        let threshold = bucket * spacing
        var gaps: [HistoryGap] = []
        if let domain {
            let from = max(domain.lowerBound, earliest ?? domain.lowerBound)
            if first.time.timeIntervalSince(from) > threshold {
                gaps.append(HistoryGap(start: from, end: first.time.addingTimeInterval(-bucket)))
            }
        }
        for index in points.indices.dropFirst() where points[index].segment != points[index - 1].segment {
            gaps.append(HistoryGap(start: points[index - 1].time, end: points[index].time.addingTimeInterval(-bucket)))
        }
        if let domain, domain.upperBound.timeIntervalSince(last.time) > threshold {
            gaps.append(HistoryGap(start: last.time, end: domain.upperBound))
        }
        return gaps
    }

    /// The stretch a graph of `points` leaves empty for this gap: on to the
    /// first point after it, where the line picks up again (the point that
    /// averages the gap's last `bucket` seconds of recording), or the gap's
    /// own end when none follows.
    public func drawn(in points: [HistoryPoint]) -> HistoryGap {
        HistoryGap(start: start, end: points.first { $0.time > end }?.time ?? end)
    }

    /// The gap at `time` among `gaps` (oldest first), each at least
    /// `minimumSpan` seconds wide as in `contains`.
    public static func gap(at time: Date, in gaps: [HistoryGap], minimumSpan: TimeInterval = 0) -> HistoryGap? {
        gaps.first { $0.contains(time, minimumSpan: minimumSpan) }
    }

    /// Indices of the points that border a gap: the last point before each
    /// and the first after, where a line breaks off and picks up again. A
    /// run of one point borders on both sides and is listed once.
    public static func borders(of gaps: [HistoryGap], in points: [HistoryPoint], bucket: TimeInterval) -> [Int] {
        let starts = Set(gaps.map(\.start))
        let ends = Set(gaps.map(\.end))
        return points.indices.filter { index in
            starts.contains(points[index].time) || ends.contains(points[index].time.addingTimeInterval(-bucket))
        }
    }

    /// Stretches a graph shades for `gaps`: each gap, plus a fade up to
    /// `fade` seconds long on either side of it, where the fill beside the
    /// gap dissolves into it instead of ending in an edge that reads as the
    /// value dropping. A fade never runs past halfway to the next gap, nor
    /// out of `domain`.
    public static func shading(_ gaps: [HistoryGap], fade: TimeInterval, within domain: ClosedRange<Date>) -> [Shade] {
        var shades: [Shade] = []
        for (index, gap) in gaps.enumerated() {
            let before = index > 0 ? gaps[index - 1].end : domain.lowerBound
            let after = index + 1 < gaps.count ? gaps[index + 1].start : domain.upperBound
            let lead = min(fade, max(gap.start.timeIntervalSince(before), 0) / (index > 0 ? 2 : 1))
            let trail = min(fade, max(after.timeIntervalSince(gap.end), 0) / (index + 1 < gaps.count ? 2 : 1))
            if lead > 0 { shades.append(Shade(start: gap.start.addingTimeInterval(-lead), end: gap.start, kind: .fadeIn)) }
            shades.append(Shade(start: gap.start, end: gap.end, kind: .gap))
            if trail > 0 { shades.append(Shade(start: gap.end, end: gap.end.addingTimeInterval(trail), kind: .fadeOut)) }
        }
        return shades
    }

    /// One stretch of `shading`.
    public struct Shade: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Fading in towards a gap that follows.
            case fadeIn
            /// The gap itself.
            case gap
            /// Fading out after the gap.
            case fadeOut
        }

        public let start: Date
        public let end: Date
        public let kind: Kind

        public init(start: Date, end: Date, kind: Kind) {
            self.start = start
            self.end = end
            self.kind = kind
        }
    }
}
