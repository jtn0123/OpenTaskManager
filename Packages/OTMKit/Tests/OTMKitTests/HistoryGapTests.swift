import Foundation
@testable import OTMKit
import Testing

struct HistoryGapTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// Ten-second points at these times, numbered as `FlightRecorder.points` numbers them.
    private func points(_ times: [Double], bucket: TimeInterval = 10) -> [HistoryPoint] {
        HistoryPoint.segmented(times.map { HistoryPoint(time: date($0), values: HistoryValues()) }, gap: bucket * HistoryGap.spacing)
    }

    @Test func findsAGapWhereverTheSegmentChanges() {
        // Recording stopped after 30 and picked up for the stretch before 630.
        let gaps = HistoryGap.gaps(in: points([0, 10, 20, 30, 630, 640, 700, 710]), bucket: 10)
        #expect(gaps == [HistoryGap(start: date(30), end: date(620)), HistoryGap(start: date(640), end: date(690))])
        #expect(gaps.map(\.duration) == [590, 50])
    }

    @Test func pointsCloseTogetherHaveNoGap() {
        // 25 s apart is within two and a half buckets, so the line carries on.
        #expect(HistoryGap.gaps(in: points([0, 10, 35, 60]), bucket: 10).isEmpty)
        #expect(HistoryGap.gaps(in: [], bucket: 10, within: date(0)...date(100)).isEmpty)
    }

    @Test func marksEmptyEndsOfTheRangeShown() {
        let shown = points([300, 310, 320])
        let gaps = HistoryGap.gaps(in: shown, bucket: 10, within: date(0)...date(600))
        #expect(gaps == [HistoryGap(start: date(0), end: date(290)), HistoryGap(start: date(320), end: date(600))])
        // Ends within the threshold aren't gaps.
        #expect(HistoryGap.gaps(in: shown, bucket: 10, within: date(290)...date(340)).isEmpty)
    }

    @Test func aLeadingGapStartsNoEarlierThanTheFirstRecord() {
        let shown = points([300, 310, 320])
        // Before the first record the recorder hadn't started: that's not a gap.
        #expect(HistoryGap.gaps(in: shown, bucket: 10, within: date(0)...date(330), since: date(300)).isEmpty)
        // Recorded long before the range, then off at its start: a gap from the range's start.
        #expect(HistoryGap.gaps(in: shown, bucket: 10, within: date(100)...date(330), since: date(0))
            == [HistoryGap(start: date(100), end: date(290))])
        // Recorded since partway in, then off for a while: a gap from the first record.
        #expect(HistoryGap.gaps(in: shown, bucket: 10, within: date(0)...date(330), since: date(150))
            == [HistoryGap(start: date(150), end: date(290))])
    }

    @Test func coarserBucketsMoveTheThreshold() {
        // Minute points 120 s apart are within 2.5 buckets; 200 s apart aren't.
        #expect(HistoryGap.gaps(in: points([0, 60, 180, 240], bucket: 60), bucket: 60).isEmpty)
        #expect(HistoryGap.gaps(in: points([0, 60, 260], bucket: 60), bucket: 60) == [HistoryGap(start: date(60), end: date(200))])
    }

    @Test func aHairlineGapCanStillBePointedAt() {
        let gap = HistoryGap(start: date(100), end: date(104))
        #expect(gap.contains(date(102)))
        #expect(!gap.contains(date(98)))
        // Counted ten seconds wide around its middle: 97...107.
        #expect(gap.contains(date(98), minimumSpan: 10))
        #expect(gap.contains(date(107), minimumSpan: 10))
        #expect(!gap.contains(date(108), minimumSpan: 10))
        // A wide one keeps its own edges.
        let wide = HistoryGap(start: date(100), end: date(200))
        #expect(!wide.contains(date(99), minimumSpan: 10))
        #expect(HistoryGap.gap(at: date(150), in: [gap, wide]) == wide)
        #expect(HistoryGap.gap(at: date(250), in: [gap, wide]) == nil)
    }

    @Test func aGapIsDrawnOnToWhereTheLinePicksUp() {
        let shown = points([0, 10, 20, 300, 310])
        let gaps = HistoryGap.gaps(in: shown, bucket: 10, within: date(0)...date(600))
        // Recording picked up at 290, the stretch the point at 300 averages; the graph is empty until 300.
        #expect(gaps.map { $0.drawn(in: shown) } == [HistoryGap(start: date(20), end: date(300)), HistoryGap(start: date(310), end: date(600))])
    }

    @Test func anEndNeverPrecedesTheStart() {
        #expect(HistoryGap(start: date(100), end: date(90)).duration == 0)
    }

    @Test func bordersAreThePointsEitherSideOfEachGap() {
        // A run of one point (300) borders a gap on each side.
        let shown = points([0, 10, 20, 300, 600, 610])
        let gaps = HistoryGap.gaps(in: shown, bucket: 10)
        #expect(gaps.count == 2)
        #expect(HistoryGap.borders(of: gaps, in: shown, bucket: 10) == [2, 3, 4])
        // Empty ends of the range shown make the first and last points borders too.
        let ended = HistoryGap.gaps(in: shown, bucket: 10, within: date(-500)...date(900))
        #expect(HistoryGap.borders(of: ended, in: shown, bucket: 10) == [0, 2, 3, 4, 5])
        #expect(HistoryGap.borders(of: [], in: shown, bucket: 10).isEmpty)
    }

    @Test func shadingFadesIntoEachGapWithoutOverlapping() {
        let domain = date(0)...date(1_000)
        let gaps = [HistoryGap(start: date(100), end: date(200)), HistoryGap(start: date(220), end: date(400))]
        let shades = HistoryGap.shading(gaps, fade: 30, within: domain)
        #expect(shades == [
            HistoryGap.Shade(start: date(70), end: date(100), kind: .fadeIn),
            HistoryGap.Shade(start: date(100), end: date(200), kind: .gap),
            // Twenty seconds between the gaps: each side fades over half of them.
            HistoryGap.Shade(start: date(200), end: date(210), kind: .fadeOut),
            HistoryGap.Shade(start: date(210), end: date(220), kind: .fadeIn),
            HistoryGap.Shade(start: date(220), end: date(400), kind: .gap),
            HistoryGap.Shade(start: date(400), end: date(430), kind: .fadeOut),
        ])
    }

    @Test func shadingKeepsInsideTheRange() {
        let domain = date(0)...date(500)
        let shades = HistoryGap.shading([HistoryGap(start: date(0), end: date(100)), HistoryGap(start: date(480), end: date(500))],
                                        fade: 30, within: domain)
        #expect(shades.map(\.kind) == [.gap, .fadeOut, .fadeIn, .gap])
        #expect(shades.allSatisfy { domain.contains($0.start) && domain.contains($0.end) })
    }
}
