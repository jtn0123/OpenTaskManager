import Foundation
@testable import OTMKit
import Testing

struct GraphFrameBatchTests {
    @Test func aBatchSkipsItsMembersUntilTheDeadline() {
        for count in [6, 18] {
            var batch = GraphFrameCadence(rate: 4, start: 0)
            var batchFrames: [Int] = []
            var clientCalls = 0
            for callback in 0..<60 {
                let time = Double(callback) / 60
                if time >= batch.nextFrameTime, batch.takeFrame(at: time) {
                    batchFrames.append(callback)
                    clientCalls += count
                }
            }
            #expect(batchFrames == [0, 15, 30, 45])
            #expect(clientCalls == count * 4)
        }
    }

    @Test func batchingMatchesIndependentCadencesEvenWithDifferentSampleTimes() {
        for rate in [4.0, 5, 17, 30, 60] {
            var batch = GraphFrameCadence(rate: rate, start: 0)
            var independent = GraphFrameCadence(rate: rate, start: 0)
            var lastFrame = -1.0
            for callback in 0..<180 {
                let time = 150.137 + Double(callback) / 60
                let expectedFrame = floor(time * rate + 1e-7)
                let expected = expectedFrame > lastFrame
                let batchDue = time >= batch.nextFrameTime && batch.takeFrame(at: time)
                let independentDue = independent.takeFrame(at: time)
                #expect(batchDue == expected && independentDue == expected)
                if expected { lastFrame = expectedFrame }
            }
        }
    }

    @Test func aDelayedCallbackCatchesUpOnceAndDoesNotDrift() {
        var batch = GraphFrameCadence(rate: 4, start: 10)
        let first = batch.takeFrame(at: 10)
        #expect(first)
        #expect(abs(batch.nextFrameTime - 10.25) < 1e-6)
        let delayed = batch.takeFrame(at: 13.17)
        #expect(delayed)
        #expect(abs(batch.nextFrameTime - 13.25) < 1e-6)
        let backwards = batch.takeFrame(at: 12)
        let duplicate = batch.takeFrame(at: 13.17)
        #expect(!backwards && !duplicate)
        for invalid in [0.0, -1, .nan, .infinity] {
            var idle = GraphFrameCadence(rate: invalid, start: 0)
            let due = idle.takeFrame(at: 13.17)
            #expect(!due && idle.nextFrameTime == .infinity)
        }
    }

    @Test func differentRatesKeepTheirPhaseWhenMembershipChanges() {
        var slow = GraphFrameCadence(rate: 4, start: 0)
        var fast = GraphFrameCadence(rate: 30, start: 0)
        let slowFirst = slow.takeFrame(at: 150.1)
        let fastFirst = fast.takeFrame(at: 150.1)
        #expect(slowFirst && fastFirst)
        // A member joins the slow batch. Its existing cadence must not reset.
        let slowNext = slow.takeFrame(at: 150.2)
        let fastNext = fast.takeFrame(at: 150.2)
        #expect(!slowNext && fastNext)
        let slowBoundary = slow.takeFrame(at: 150.25)
        #expect(slowBoundary)
    }

    @Test func preparedCurvesMatchTheDrawnHermiteSegments() {
        for values in [[0.0, 1, 20, 21], [21.0, 20, 1, 0], [0.0, 20, 20, 0]] {
            let tangents = GraphMath.monotoneTangents(values)
            for index in 0..<(values.count - 1) {
                let segment = GraphMotionSegment(start: values[index], end: values[index + 1],
                                                 startTangent: tangents[index], endTangent: tangents[index + 1])
                let curve = GraphMotionCurve(segment)
                for frame in 0...60 {
                    let progress = Double(frame) / 60
                    #expect(abs(curve.value(at: progress) - segment.value(at: progress)) < 1e-8)
                }
            }
        }
    }

    @Test func preparedTimingPreservesTheScrollAcrossRedrawsAndLateFrames() {
        let timing = GraphMotionTiming(start: 150.137, interval: 2)
        #expect(timing.progress(at: 150) == 0)
        #expect(abs(timing.progress(at: 150.637) - 0.25) < 1e-8)
        #expect(abs(timing.progress(at: 151.637) - 0.75) < 1e-8)
        #expect(timing.progress(at: 152.137) == 1)
        #expect(timing.progress(at: 160) == 1)
        // A between-sample render reads the same timing; it never restarts it.
        #expect(abs(timing.progress(at: 151.637) - 0.75) < 1e-8)
        #expect(GraphMotionTiming(start: 0, interval: 0).progress(at: 1) == 1)
    }

    @Test func countingKeepsItsCubicEaseOut() {
        let curve = GraphMotionCurve(GraphMotionSegment(start: 20, end: 80, startTangent: 180, endTangent: 0))
        for frame in 0...60 {
            let progress = Double(frame) / 60
            let expected = 20 + 60 * (1 - pow(1 - progress, 3))
            #expect(abs(curve.value(at: progress) - expected) < 1e-8)
        }
    }
}
