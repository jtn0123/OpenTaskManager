import Foundation
@testable import OTMKit
import Testing

struct AutoScaleTests {
    @Test(arguments: [
        (0.0, 0.1), (0.03, 0.1), (0.084, 0.1), (0.086, 0.2), (0.169, 0.2), (0.18, 0.25), (0.21, 0.25),
        (0.22, 0.5), (0.42, 0.5), (0.43, 1.0), (0.97, 1.0), (1.4, 1.0), (-0.2, 0.1),
    ])
    func boundIsTheSmallestRoundStepWithHeadroom(peak: Double, expected: Double) {
        #expect(AutoScale.bound(for: peak) == expected)
    }

    @Test func boundNeverGoesUnderTenPercentOrPastTheWhole() {
        #expect(AutoScale.bound(for: 0) == 0.1)
        #expect(AutoScale.bound(for: .nan) == 0.1)
        #expect(AutoScale.bound(for: .infinity) == 1)
        #expect(AutoScale.steps.min() == 0.1)
        #expect(AutoScale.steps.max() == 1)
    }

    @Test func startsFittedToTheData() {
        #expect(AutoScale(peak: 0.04).bound == 0.1)
        #expect(AutoScale(peak: 0.3).bound == 0.5)
    }

    @Test func growsAtOnceWhenTheDataNeedsRoom() {
        var scale = AutoScale(peak: 0.03)
        #expect(scale.update(peak: 0.09, at: 1) == 0.2)
        #expect(scale.update(peak: 0.6, at: 2) == 1)
    }

    @Test func shrinksOnlyAfterTheDataStaysLowForAWhile() {
        var scale = AutoScale(peak: 0.3)
        for second in 0..<Int(AutoScale.hold) {
            #expect(scale.update(peak: 0.05, at: TimeInterval(second)) == 0.5)
        }
        // Several steps at once, straight to the smallest that fits.
        #expect(scale.update(peak: 0.05, at: AutoScale.hold) == 0.1)
    }

    @Test func aBriefRiseRestartsTheWait() {
        var scale = AutoScale(peak: 0.3)
        for second in 0...10 {
            scale.update(peak: 0.05, at: TimeInterval(second))
        }
        // Still inside 50%, but too high to shrink: the clock starts over.
        #expect(scale.update(peak: 0.4, at: 11) == 0.5)
        for second in 12..<27 {
            #expect(scale.update(peak: 0.05, at: TimeInterval(second)) == 0.5)
        }
        #expect(scale.update(peak: 0.05, at: 27) == 0.1)
    }

    @Test func loadHoveringNearAStepNeverFlicks() {
        // Between shrinking to 10% (7%) and growing past it (8.5%).
        var low = AutoScale(peak: 0.05)
        // Between shrinking to 10% (7%) and growing past 20% (17%).
        var high = AutoScale(peak: 0.15)
        for second in 0..<600 {
            let wobble = second.isMultiple(of: 2)
            #expect(low.update(peak: wobble ? 0.072 : 0.084, at: TimeInterval(second)) == 0.1)
            #expect(high.update(peak: wobble ? 0.075 : 0.165, at: TimeInterval(second)) == 0.2)
        }
    }

    @Test func aGrowCancelsAPendingShrink() {
        var scale = AutoScale(peak: 0.15)
        scale.update(peak: 0.02, at: 0)
        scale.update(peak: 0.3, at: 10)
        #expect(scale.bound == 0.5)
        // The wait for the smaller bound starts again from here.
        #expect(scale.update(peak: 0.02, at: 16) == 0.5)
        #expect(scale.update(peak: 0.02, at: 31) == 0.1)
    }
}
