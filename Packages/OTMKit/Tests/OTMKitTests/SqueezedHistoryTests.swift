import Foundation
@testable import OTMKit
import Testing

struct TimeWarpTests {
    private let warp = TimeWarp.standard

    @Test func runsFromNowAtTheRightToTheOldestAtTheLeft() {
        #expect(warp.offset(age: 0) == 0)
        #expect(warp.offset(age: warp.span) == 1)
        #expect(warp.offset(age: -2) == 0)
        #expect(warp.offset(age: warp.span * 3) == 1)
        #expect(warp.span == 15)
        #expect(warp.linearShare == 0.6)
        #expect(warp.zoneEdges == [1, 3, 7])
    }

    @Test func risesWithAgeWithoutAJumpAtAnyZoneEdge() {
        var previous = -1.0
        for step in 0...1_500 {
            let offset = warp.offset(age: Double(step) / 100)
            #expect(offset > previous)
            previous = offset
        }
        for stop in warp.stops {
            #expect(abs(warp.offset(age: stop.age - 1e-9) - stop.offset) < 1e-6)
            #expect(abs(warp.offset(age: stop.age + 1e-9) - stop.offset) < 1e-6)
        }
    }

    @Test func eachOlderZoneIsSqueezedHarderThanTheOneBeforeIt() {
        let densities = warp.densities
        #expect(densities.count == 4)
        for (newer, older) in zip(densities, densities.dropFirst()) {
            #expect(older < newer)
        }
        // The newest window keeps the usual scale over its share of the width.
        #expect(densities[0] == warp.linearShare)
    }

    @Test func theInverseFindsTheAgeAgain() {
        for step in 0...300 {
            let age = Double(step) / 20
            #expect(abs(warp.age(offset: warp.offset(age: age)) - age) < 1e-9)
        }
        for step in 0...100 {
            let offset = Double(step) / 100
            #expect(abs(warp.offset(age: warp.age(offset: offset)) - offset) < 1e-9)
        }
        #expect(warp.age(offset: 2) == warp.span)
        #expect(warp.age(offset: -1) == 0)
    }
}

struct LongHistoryTests {
    @Test func aBucketKeepsItsSamplesMeanAndPeak() {
        var history = LongHistory(capacity: 4)
        for value in 1...10 { history.add(Double(value)) }
        history.close()
        #expect(history.buckets == [LongHistory.Bucket(mean: 5.5, peak: 10)])
        #expect(history.peak == 10)
    }

    @Test func aBucketWithNothingInItIsUnrecorded() {
        var history = LongHistory(capacity: 4)
        history.add(.nan)
        history.add(.infinity)
        history.close()
        #expect(history.buckets.count == 1)
        #expect(!history.buckets[0].isRecorded)
        #expect(history.isEmpty)
    }

    @Test func weightCountsASlowTickAsTheSamplesItSpans() {
        var history = LongHistory(capacity: 4)
        history.add(10, weight: 2)
        history.add(40)
        history.close()
        #expect(history.buckets == [LongHistory.Bucket(mean: 20, peak: 40)])
    }

    @Test func theOldestBucketsGiveWayAndTakeTheirPeakWithThem() {
        var history = LongHistory(capacity: 3)
        for value in [9.0, 2, 3, 4] {
            history.add(value)
            history.close()
        }
        #expect(history.buckets.map(\.mean) == [2, 3, 4])
        #expect(history.peak == 4)
    }

    @Test func aSkipMarksTheStretchUnrecorded() {
        var history = LongHistory(capacity: 10)
        history.add(5)
        history.close()
        history.skip(3)
        #expect(history.buckets.count == 4)
        #expect(history.buckets[0].mean == 5)
        #expect(history.buckets.dropFirst().allSatisfy { !$0.isRecorded })
        history.skip(50)
        #expect(history.buckets.count == 10)
        #expect(history.isEmpty)
    }

    @Test func seriesCloseTheirBucketsTogether() {
        var histories = LongHistories<String>(span: 300)
        #expect(histories.capacity == 450)
        for tick in 0..<25 {
            histories.startTick()
            histories.add(Double(tick), for: "cpu")
            // A disk that turns up part way through a bucket.
            if tick >= 15 { histories.add(1, for: "disk") }
            let closed = histories.finishTick()
            #expect(closed == ((tick + 1) % 10 == 0))
        }
        #expect(histories.revision == 2)
        #expect(histories.buckets("cpu")?.map(\.mean) == [4.5, 14.5])
        // Its buckets line up with the others' from the newest.
        #expect(histories.buckets("disk")?.map(\.mean) == [1])
        #expect(histories.peak("cpu") == 19)
        #expect(histories.buckets("network") == nil)
    }

    @Test func hiddenTicksAtTwiceTheStepFillABucketInHalfTheTicks() {
        var histories = LongHistories<String>(span: 300)
        var closes = 0
        for _ in 0..<10 {
            histories.startTick(weight: 2)
            histories.add(3, for: "cpu")
            if histories.finishTick() { closes += 1 }
        }
        #expect(closes == 2)
        #expect(histories.buckets("cpu")?.map(\.mean) == [3, 3])
    }

    @Test func aGapLeavesUnrecordedBucketsAndAGoneSeriesLeaves() {
        var histories = LongHistories<String>(span: 2, bucketSize: 1, windows: 2)
        #expect(histories.capacity == 4)
        histories.startTick()
        histories.add(1, for: "cpu")
        histories.add(2, for: "disk")
        histories.finishTick()
        // Two samples asleep: two buckets, the open one being empty.
        histories.gap(samples: 2)
        #expect(histories.buckets("cpu")?.map(\.isRecorded) == [true, false, false])
        // The disk is gone; once its last reading leaves, so does it.
        histories.startTick()
        histories.add(1, for: "cpu")
        histories.finishTick()
        #expect(histories.buckets("disk")?.map(\.isRecorded) == [true, false, false, false])
        histories.startTick()
        histories.add(1, for: "cpu")
        histories.finishTick()
        #expect(histories.buckets("disk") == nil)
        #expect(histories.buckets("cpu")?.map(\.isRecorded) == [false, false, true, true])
    }

    @Test func removingEverythingMovesTheRevisionOn() {
        var histories = LongHistories<String>(span: 10, bucketSize: 1)
        histories.startTick()
        histories.add(1, for: "cpu")
        histories.finishTick()
        let revision = histories.revision
        histories.removeAll()
        #expect(histories.isEmpty)
        #expect(histories.revision == revision + 1)
    }
}

struct SqueezedTraceTests {
    private let warp = TimeWarp.standard

    private func buckets(_ count: Int, _ value: (Int) -> Double = { _ in 1 }) -> [LongHistory.Bucket] {
        (0..<count).map { LongHistory.Bucket(mean: value($0), peak: value($0)) }
    }

    @Test func nothingOlderThanTheWindowIsAllUnrecorded() {
        let trace = SqueezedTrace(buckets: buckets(30), bucketSize: 10, span: 300, width: 500, scale: 2)
        #expect(trace.columns.isEmpty)
        #expect(trace.gaps == [SqueezedTrace.Gap(from: 0, to: 200)])
    }

    @Test func columnsRunLeftToRightAndMeetTheNewestWindow() {
        let trace = SqueezedTrace(buckets: buckets(450), bucketSize: 10, span: 300, width: 500, scale: 2)
        let xs = trace.columns.map(\.x)
        #expect(xs.last == 200)
        #expect(xs.allSatisfy { $0 >= 0 && $0 <= 200 })
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 })
        #expect(trace.gaps.isEmpty)
    }

    @Test func noMoreThanAColumnPerDevicePixel() {
        let trace = SqueezedTrace(buckets: buckets(450), bucketSize: 10, span: 300, width: 500, scale: 2)
        // Every column but the one at the window's edge has its own pixel.
        let pixels = trace.columns.dropLast().map { Int(($0.x * 2).rounded(.down)) }
        #expect(Set(pixels).count == pixels.count)
        #expect(trace.columns.count <= 200 * 2 + 1)
        // The oldest zone packs several buckets to a pixel; the newest squeezed one doesn't.
        #expect(trace.columns.count < 420)
    }

    @Test func aMergedColumnKeepsItsPeak() {
        // A one-bucket burst an hour ago, in the oldest zone.
        let burst = 450 - 1 - 360
        let trace = SqueezedTrace(buckets: buckets(450) { $0 == burst ? 100 : 1 }, bucketSize: 10, span: 300,
                                  width: 500, scale: 2)
        let column = trace.columns.first { $0.peak == 100 }
        #expect(column != nil)
        #expect((column?.mean ?? 100) < 100)
    }

    @Test func unrecordedStretchesAreGaps() {
        // Half an hour of history with ten minutes asleep in the middle of it.
        var history = buckets(180)
        for index in 60..<120 { history[index] = .unrecorded }
        let trace = SqueezedTrace(buckets: history, bucketSize: 10, span: 300, width: 500, scale: 2)
        func x(_ minutes: Double) -> Double { 500 * (1 - warp.offset(age: minutes / 5)) }
        #expect(trace.gaps.count == 2)
        // Older than the oldest bucket, half an hour back.
        #expect(trace.gaps[0].from == 0)
        #expect(abs(trace.gaps[0].to - x(30)) < 1e-9)
        // Asleep from 20 to 10 minutes ago.
        #expect(abs(trace.gaps[1].from - x(20)) < 1e-9)
        #expect(abs(trace.gaps[1].to - x(10)) < 1e-9)
        #expect(trace.columns.contains { !$0.isRecorded })
    }
}
