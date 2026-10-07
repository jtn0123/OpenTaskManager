import Foundation
@testable import OTMKit
import Testing

struct GraphMathTests {
    @Test(arguments: [
        (0.0, 1.0), (-3.0, 1.0), (1.0, 1.0), (1.1, 1.25), (1.3, 1.5), (2.0, 2.0), (2.2, 2.5),
        (2.9, 3.0), (3.5, 4.0), (4.5, 5.0), (5.5, 6.0), (7.0, 8.0), (9.0, 10.0), (0.042, 0.05), (1_700.0, 2_000.0),
    ])
    func niceCeilingRoundsUpToTidySteps(value: Double, expected: Double) {
        #expect(abs(GraphMath.niceCeiling(value) - expected) < expected * 1e-9)
    }

    @Test func niceCeilingIgnoresFloatingPointNoise() {
        #expect(abs(GraphMath.niceCeiling(0.1 + 0.2) - 0.3) < 1e-12)
        #expect(GraphMath.niceCeiling(1e-320) == 1)
        #expect(GraphMath.niceCeiling(Double.infinity) == 1)
        #expect(GraphMath.niceCeiling(Double.nan) == 1)
    }

    @Test func ceilingAddsHeadroomAndRespectsFloor() {
        #expect(GraphMath.ceiling(peak: 2.0) == 2.5)
        #expect(GraphMath.ceiling(peak: 2.0, headroom: 1) == 2.0)
        #expect(GraphMath.ceiling(peak: 0.1, floor: 5) == 5)
        #expect(GraphMath.ceiling(peak: 0) == 1)
    }

    @Test func ceilingLandsOnRoundNumbersInDisplayUnits() {
        let mebibyte = 1_048_576.0
        // 381 MiB/s of traffic gets a 400 MB/s axis, not 381.
        #expect(GraphMath.ceiling(peak: 381 * mebibyte, headroom: 1, units: .binaryBytes) == 400 * mebibyte)
        #expect(GraphMath.ceiling(peak: 1010 * mebibyte, headroom: 1, units: .binaryBytes) == 1024 * mebibyte)
        #expect(GraphMath.ceiling(peak: 700, headroom: 1, units: .binaryBytes) == 800)
        // 5.6 Mbps (700 kB/s) gets a 6 Mbps axis.
        #expect(GraphMath.ceiling(peak: 700_000, headroom: 1, units: .bits) == 750_000)
    }

    @Test func tangentsAreZeroAtPeaksAndFlats() {
        let tangents = GraphMath.monotoneTangents([0, 1, 0, 0, 2])
        #expect(tangents[1] == 0)
        #expect(tangents[2] == 0)
        #expect(tangents[3] == 0)
    }

    @Test func curveNeverOvershootsItsNeighbours() {
        // Spiky data that a Catmull-Rom spline would push above 1 and below 0.
        let values: [Double] = [0, 0, 1, 1, 0, 0.05, 1, 0, 1, 0.98, 1]
        let tangents = GraphMath.monotoneTangents(values)
        for index in 0..<values.count - 1 {
            let low = min(values[index], values[index + 1])
            let high = max(values[index], values[index + 1])
            for step in 0...20 {
                let y = GraphMath.hermite(
                    from: values[index], to: values[index + 1],
                    startTangent: tangents[index], endTangent: tangents[index + 1], at: Double(step) / 20
                )
                #expect(y >= low - 1e-12 && y <= high + 1e-12, "segment \(index) left its range at t=\(step)/20: \(y)")
            }
        }
    }

    @Test func hermiteHitsBothEnds() {
        #expect(GraphMath.hermite(from: 3, to: 7, startTangent: 1, endTangent: -2, at: 0) == 3)
        #expect(GraphMath.hermite(from: 3, to: 7, startTangent: 1, endTangent: -2, at: 1) == 7)
    }

    @Test func tangentsForShortInputs() {
        #expect(GraphMath.monotoneTangents([]).isEmpty)
        #expect(GraphMath.monotoneTangents([4]) == [0])
        #expect(GraphMath.monotoneTangents([1, 3]) == [2, 2])
    }

    @Test func stackAlignsOnNewestValues() {
        let stacked = GraphMath.stack([[1, 2, 3], [10, 20], [-5, 100]])
        #expect(stacked[0] == [1, 2, 3])
        #expect(stacked[1] == [1, 12, 23])
        // Negative values don't pull a band below the one beneath it.
        #expect(stacked[2] == [1, 12, 123])
    }

    @Test func timeTicksLandOnRoundTimesAwayFromTheEnds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let start = Date(timeIntervalSince1970: 6 * 3_600 + 11 * 60 + 23)
        let ticks = GraphMath.timeTicks(in: start...start.addingTimeInterval(3_600), step: 900, calendar: calendar)
        let clock = ticks.map { Int($0.timeIntervalSince1970) % 86_400 / 60 }
        // From 6:11:23 to 7:11:23, keeping 3 minutes (5%) clear of each end.
        #expect(clock == [6 * 60 + 15, 6 * 60 + 30, 6 * 60 + 45, 7 * 60])
        // From 6:14 the 6:15 tick falls inside the margin, where its label would be cut off.
        let late = Date(timeIntervalSince1970: 6 * 3_600 + 14 * 60)
        let lateTicks = GraphMath.timeTicks(in: late...late.addingTimeInterval(3_600), step: 900, calendar: calendar)
        #expect(lateTicks.map { Int($0.timeIntervalSince1970) % 86_400 / 60 } == [6 * 60 + 30, 6 * 60 + 45, 7 * 60])
        #expect(GraphMath.timeTicks(in: start...start, step: 900).isEmpty)
    }

    /// Spans and the step each gets, in seconds.
    private static let tickSteps: [(Double, Double)] = [
        (60, 10), (180, 30), (1_440, 300), (3_600, 600),
        (9_000, 1_800), (21_600, 3_600), (86_400, 14_400), (259_200, 43_200),
    ]

    @Test(arguments: tickSteps)
    func tickStepIsRoundForAnySpan(span: Double, expected: Double) {
        #expect(GraphMath.timeTickStep(for: span) == expected)
    }

    @Test func tickStepNeverCrowdsTheAxis() {
        var previous = 0.0
        for span in stride(from: 30.0, through: 30 * 86_400, by: 97) {
            let step = GraphMath.timeTickStep(for: span)
            #expect(span / step <= 6 + 1e-6, "\(span) s got a step of \(step) s")
            #expect(step >= previous, "a longer span shouldn't get a finer step")
            previous = step
        }
        // A week fits seven daily labels when asked for seven.
        #expect(GraphMath.timeTickStep(for: 7 * 86_400, maximumTicks: 7) == 86_400)
        // Past the list it counts in whole weeks.
        #expect(GraphMath.timeTickStep(for: 100 * 86_400) == 21 * 86_400)
    }

    @Test func tickStepForDegenerateSpans() {
        #expect(GraphMath.timeTickStep(for: 0) == 10)
        #expect(GraphMath.timeTickStep(for: -60) == 10)
        #expect(GraphMath.timeTickStep(for: .nan) == 10)
        #expect(GraphMath.timeTickStep(for: 5) == 10)
        #expect(GraphMath.timeTickStep(for: 3_600, maximumTicks: 0) == 10)
    }

    @Test func fittingOnlyShortensARangeTheRecordingDoesNotFill() {
        let hour = 3_600.0
        // Ten minutes recorded: fitted, the axis spans ten minutes.
        #expect(GraphMath.canFit(range: hour, recorded: 600))
        #expect(GraphMath.historySpan(range: hour, recorded: 600, fit: true) == 600)
        #expect(GraphMath.historySpan(range: hour, recorded: 600, fit: false) == hour)
        // A recording that fills the range (or nearly) leaves it alone.
        #expect(!GraphMath.canFit(range: hour, recorded: 5 * hour))
        #expect(!GraphMath.canFit(range: hour, recorded: 0.97 * hour))
        #expect(GraphMath.historySpan(range: hour, recorded: 5 * hour, fit: true) == hour)
        // Nothing recorded yet: nothing to fit.
        #expect(!GraphMath.canFit(range: hour, recorded: nil))
        #expect(GraphMath.historySpan(range: hour, recorded: nil, fit: true) == hour)
        // A recording seconds old still gets a readable minute.
        #expect(GraphMath.historySpan(range: hour, recorded: 12, fit: true) == 60)
    }
}
