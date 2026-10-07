import Foundation
@testable import OTMKit
import Testing

struct GraphCoverageTests {
    @Test func captionsAFillingWindow() {
        let coverage = GraphCoverage(samples: 45, capacity: 300, interval: 1)
        #expect(!coverage.isFull)
        #expect(coverage.caption == "45 s collected · 5-minute window")
        #expect(coverage.shortCaption == "45 s collected")
    }

    @Test func noCaptionBeforeTheFirstSampleOrOnceFull() {
        #expect(GraphCoverage(samples: 0, capacity: 300, interval: 1).caption == nil)
        #expect(GraphCoverage(samples: 300, capacity: 300, interval: 1).caption == nil)
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
        (300.0, "5-minute window"), (120.0, "2-minute window"), (60.0, "1-minute window"), (30.0, "30-second window"),
        (150.0, "2 min 30 s window"), (7_200.0, "2-hour window"), (2.5, "2.5 s window"),
    ])
    func windowNamesItsSpan(seconds: Double, expected: String) {
        #expect(GraphCoverage.window(seconds) == expected)
    }
}
