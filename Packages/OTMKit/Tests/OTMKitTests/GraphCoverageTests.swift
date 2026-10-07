import Foundation
@testable import OTMKit
import Testing

struct GraphCoverageTests {
    @Test func captionsAFillingWindow() {
        let coverage = GraphCoverage(samples: 45, capacity: 300, interval: 1)
        #expect(!coverage.isFull)
        #expect(coverage.caption == "45 s collected · 5 min window")
        #expect(coverage.shortCaption == "45 s collected")
        #expect(coverage.spokenCaption == "45 s collected · 5 min window. Not recorded before that.")
    }

    @Test func noCaptionBeforeTheFirstSampleOrOnceFull() {
        #expect(GraphCoverage(samples: 0, capacity: 300, interval: 1).caption == nil)
        #expect(GraphCoverage(samples: 300, capacity: 300, interval: 1).caption == nil)
        #expect(GraphCoverage(samples: 300, capacity: 300, interval: 1).spokenCaption == nil)
        #expect(GraphCoverage(samples: 301, capacity: 300, interval: 1).isFull)
        #expect(GraphCoverage(samples: 12, capacity: 300, interval: 0).caption == nil)
    }

    @Test(arguments: [
        (3, 1.0, 3.0), (9, 1.0, 9.0), (3, 0.5, 1.5), (12, 1.0, 10.0), (44, 1.0, 40.0), (45, 1.0, 45.0),
        (74, 1.0, 60.0), (75, 1.0, 75.0), (299, 1.0, 285.0), (130, 5.0, 600.0), (131, 5.0, 600.0),
    ])
    func collectedSecondsStepRatherThanTickEverySample(samples: Int, interval: Double, expected: Double) {
        #expect(GraphCoverage(samples: samples, capacity: 1_000, interval: interval).collectedSeconds == expected)
    }

    @Test func collectedTextReadsAsATimeSpan() {
        #expect(GraphCoverage(samples: 3, capacity: 300, interval: 0.5).shortCaption == "1.5 s collected")
        #expect(GraphCoverage(samples: 100, capacity: 300, interval: 1).shortCaption == "1 min 30 s collected")
        #expect(GraphCoverage(samples: 120, capacity: 300, interval: 1).shortCaption == "2 min collected")
    }

    @Test(arguments: [
        (300.0, "5 min window"), (120.0, "2 min window"), (60.0, "1 min window"), (30.0, "30 s window"),
        (150.0, "2 min 30 s window"), (7_200.0, "2 h window"), (2.5, "2.5 s window"),
    ])
    func windowNamesItsSpanLikeTheTimeAxis(seconds: Double, expected: String) {
        #expect(GraphCoverage.window(seconds) == expected)
    }

    @Test(arguments: [
        (0, 10), (1, 10), (10, 10), (11, 20), (35, 40), (40, 40), (41, 60), (61, 90), (91, 120),
        (121, 150), (240, 240), (241, 270), (270, 270), (271, 300), (300, 300), (302, 300),
    ])
    func fittedWindowStepsUpToHoldWhatsCollected(samples: Int, expected: Int) {
        #expect(GraphCoverage.fittedCapacity(samples: samples, span: 300) == expected)
    }

    @Test func fittedWindowHoldsEverySampleAndFillsAtLeastHalfPastTheFirstStep() {
        for span in [120, 300] {
            var previous = 0
            for samples in 1...span {
                let capacity = GraphCoverage.fittedCapacity(samples: samples, span: span)
                #expect(capacity >= samples && capacity <= span)
                #expect(capacity >= previous, "a window never shrinks as samples come in")
                if samples > span / 30 { #expect(Double(samples) / Double(capacity) > 0.5) }
                previous = capacity
            }
        }
    }

    @Test func fittedWindowStaysAtLeastTwoSamples() {
        #expect(GraphCoverage.fittedCapacity(samples: 0, span: 2) == 2)
        #expect(GraphCoverage.fittedCapacity(samples: 1, span: 30) == 2)
        #expect(GraphCoverage.fittedCapacity(samples: 5, span: 1) == 2)
    }

    @Test func fittingStopsMatteringOnceOnlyTheFullWindowHoldsTheSamples() {
        #expect(GraphCoverage.canFit(samples: 0, span: 300))
        #expect(GraphCoverage.canFit(samples: 270, span: 300))
        #expect(!GraphCoverage.canFit(samples: 271, span: 300))
        #expect(!GraphCoverage.canFit(samples: 302, span: 300))
    }

    @Test func aFittedCaptionNamesTheFittedWindow() {
        let capacity = GraphCoverage.fittedCapacity(samples: 35, span: 300)
        #expect(GraphCoverage(samples: 35, capacity: capacity, interval: 1).caption == "35 s collected · 40 s window")
        #expect(GraphCoverage(samples: 35, capacity: capacity, interval: 2).caption == "1 min collected · 1 min 20 s window")
    }
}
