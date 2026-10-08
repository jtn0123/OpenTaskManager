import Foundation
@testable import OTMKit
import Testing

struct GraphMotionTests {
    @Test func ratesFollowWidthScaleAndSamplingInterval() {
        #expect(GraphFrameRate.rate(distance: 594.0 / 299, scale: 2, interval: 1, displayRate: 60) == 4)
        #expect(GraphFrameRate.rate(distance: 294.0 / 119, scale: 2, interval: 1, displayRate: 60) == 5)
        #expect(GraphFrameRate.rate(distance: 94.0 / 119, scale: 2, interval: 1, displayRate: 60) == 4)
        #expect(GraphFrameRate.rate(distance: 8, scale: 1, interval: 1, displayRate: 60) == 8)
        #expect(GraphFrameRate.rate(distance: 8, scale: 2, interval: 1, displayRate: 60) == 16)
        #expect(GraphFrameRate.rate(distance: 8, scale: 2, interval: 2, displayRate: 60) == 8)
    }

    @Test func respectsTheDisplayAndStopsAtZeroOrInvalidMotion() {
        #expect(GraphFrameRate.rate(distance: 200, scale: 2, interval: 1, displayRate: 120) == 60)
        #expect(GraphFrameRate.rate(distance: 200, scale: 2, interval: 1, displayRate: 24) == 24)
        #expect(GraphFrameRate.rate(distance: 0.01, scale: 1, interval: 1, displayRate: 2) == 2)
        for invalid in [0.0, -1, .nan, .infinity] {
            #expect(GraphFrameRate.rate(distance: invalid, scale: 2, interval: 1, displayRate: 60) == 0)
            #expect(GraphFrameRate.rate(distance: 2, scale: invalid, interval: 1, displayRate: 60) == 0)
            #expect(GraphFrameRate.rate(distance: 2, scale: 2, interval: invalid, displayRate: 60) == 0)
            #expect(GraphFrameRate.rate(distance: 2, scale: 2, interval: 1, displayRate: invalid) == 0)
        }
    }

    @Test func pixelStepsStayMonotoneAndEndExactlyAtTheNextSample() {
        for scale in [1.0, 2] {
            let step = 594.0 / 299
            let rate = GraphFrameRate.rate(distance: step, scale: scale, interval: 1, displayRate: 60)
            var previous = 0.0
            for frame in 0...Int(rate) {
                let offset = GraphFrameRate.scrollOffset(step: step, progress: Double(frame) / rate, scale: scale)
                #expect(offset <= previous && offset >= -step)
                #expect(abs(offset - previous) <= 1 / scale)
                previous = offset
            }
            #expect(GraphFrameRate.scrollOffset(step: step, progress: 1, scale: scale) == -step)
            #expect(GraphFrameRate.scrollOffset(step: step, progress: 10, scale: scale) == -step)
        }
        #expect(GraphFrameRate.scrollOffset(step: 2, progress: -1, scale: 2) == 0)
        #expect(GraphFrameRate.scrollOffset(step: 2, progress: .nan, scale: 2) == 0)
    }

    @Test func aFixedSixtyHertzDisplayOnlyCommitsTheRequestedFrames() {
        var cadence = GraphFrameCadence(rate: 4, start: 10)
        var frames: [Int] = []
        for callback in 0..<60 where cadence.takeFrame(at: 10 + Double(callback) / 60) {
            frames.append(callback)
        }
        #expect(frames == [0, 15, 30, 45])
        let subsequent = [10.75, 9, 12, 12].map { cadence.takeFrame(at: $0) }
        #expect(subsequent == [false, false, true, false])
        var idle = GraphFrameCadence(rate: 0, start: 10)
        let idleFrame = idle.takeFrame(at: 12)
        #expect(!idleFrame)
    }

    @Test func headRateAccountsForTheCurvesSteepMiddle() {
        let eased = GraphMotionSegment(start: 0, end: 20, startTangent: 0, endTangent: 0)
        #expect(eased.peakSpeed == 30)
        #expect(eased.value(at: 0) == 0)
        #expect(eased.value(at: 0.5) == 10)
        #expect(eased.value(at: 1) == 20)
        #expect(GraphFrameRate.rate(distance: eased.peakSpeed, scale: 2, interval: 1, displayRate: 60) == 60)
        let flat = GraphMotionSegment(start: 20, end: 20, startTangent: 0, endTangent: 0)
        #expect(flat.peakSpeed == 0)
        let linear = GraphMotionSegment(start: 20, end: 0, startTangent: -20, endTangent: -20)
        #expect(linear.peakSpeed == 20)
    }

    @Test func scrollAndHeadStayOnTheSamePartOfTheCurve() {
        let segment = GraphMotionSegment(start: 0, end: 40, startTangent: 0, endTangent: 0)
        let step = 594.0 / 299
        for frame in 0...60 {
            let progress = Double(frame) / 60
            let x = GraphFrameRate.scrollOffset(step: step, progress: progress, scale: 2)
            let progressAtEdge = -x / step
            #expect(abs(segment.value(at: progressAtEdge) - segment.value(at: progress)) < 1e-8)
        }
    }

    @Test func peakSpeedBoundsEveryPartOfAMonotoneSegment() {
        for values in [[0.0, 1, 20, 21], [21.0, 20, 1, 0], [0.0, 20, 20, 0]] {
            let tangents = GraphMath.monotoneTangents(values)
            for index in 0..<(values.count - 1) {
                let segment = GraphMotionSegment(start: values[index], end: values[index + 1],
                                                 startTangent: tangents[index], endTangent: tangents[index + 1])
                for frame in 0..<100 {
                    let distance = abs(segment.value(at: Double(frame + 1) / 100) - segment.value(at: Double(frame) / 100))
                    #expect(distance * 100 <= segment.peakSpeed + 1e-8)
                }
            }
        }
    }
}
