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

    @Test func tangentsMatchTheTextbookFritschCarlson() {
        // The method as usually written, slopes first, against the pointer
        // loops: plateaus, spikes, steep runs and gentle ones, bit for bit.
        func reference(_ values: [Double]) -> [Double] {
            let count = values.count
            let deltas = (0..<count - 1).map { values[$0 + 1] - values[$0] }
            var tangents = [Double](repeating: 0, count: count)
            tangents[0] = deltas[0]
            tangents[count - 1] = deltas[count - 2]
            for index in 1..<count - 1 where deltas[index - 1] * deltas[index] > 0 {
                tangents[index] = (deltas[index - 1] + deltas[index]) / 2
            }
            for index in 0..<count - 1 {
                guard deltas[index] != 0 else {
                    tangents[index] = 0
                    tangents[index + 1] = 0
                    continue
                }
                let alpha = tangents[index] / deltas[index]
                let beta = tangents[index + 1] / deltas[index]
                let length = alpha * alpha + beta * beta
                if length > 9 {
                    tangents[index] = 3 / length.squareRoot() * alpha * deltas[index]
                    tangents[index + 1] = 3 / length.squareRoot() * beta * deltas[index]
                }
            }
            return tangents
        }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let values = (0..<300).map { index -> Double in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(seed >> 11) / Double(1 << 53)
            switch index % 50 {
            case 0..<8: return 2
            case 8..<10: return noise * 100
            case 10..<20: return Double(index % 50) * 7.5
            default: return 40 + noise
            }
        }
        #expect(GraphMath.monotoneTangents(values) == reference(values))
        #expect(GraphMath.monotoneTangents([3, 0, 9, 9, 1]) == reference([3, 0, 9, 9, 1]))
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

    @Test func tailSumAlignsOnNewestValues() {
        #expect(GraphMath.tailSum([[1, 2, 3], [10, 20], [-5]]) == [1, 12, 18])
        #expect(GraphMath.tailSum([]).isEmpty)
        #expect(GraphMath.tailSum([[], [4]]) == [4])
    }

    @Test func remainderIsWhatThePartsLeaveAndNeverNegative() {
        // Parts newer than the total's start line up on its newest values.
        #expect(GraphMath.remainder(of: [10, 10, 10, 10], minus: [[1, 2], [3]]) == [10, 10, 9, 5])
        // More used than the total, from rounding, floors at zero.
        #expect(GraphMath.remainder(of: [1, 2], minus: [[5, 1]]) == [0, 1])
        // Parts longer than the total: only their newest values count.
        #expect(GraphMath.remainder(of: [5, 5], minus: [[9, 9, 1, 2]]) == [4, 3])
        #expect(GraphMath.remainder(of: [3, 4], minus: []) == [3, 4])
        #expect(GraphMath.remainder(of: [], minus: [[1]]).isEmpty)
    }

    @Test func finitePeakSkipsUnreadableValuesAndLooksOnlyAtTheTail() {
        #expect(GraphMath.finitePeak([1, .nan, 7, .infinity, 3]) == 7)
        #expect(GraphMath.finitePeak([9, 1, 2], last: 2) == 2)
        #expect(GraphMath.finitePeak([9, 1, 2], last: 10) == 9)
        #expect(GraphMath.finitePeak([]) == 0)
        #expect(GraphMath.finitePeak([.nan]) == 0)
        #expect(GraphMath.finitePeak([-3, -1]) == -1)
    }

    @Test func aSampleOnGrowsTheWindowOrSlidesAFullOne() {
        // Filling: one more value at the end.
        #expect(GraphMath.advancesOneSample(from: [1, 2], to: [1, 2, 5]))
        #expect(GraphMath.advancesOneSample(from: [], to: [4]))
        // Full: the oldest gone as the newest comes.
        #expect(GraphMath.advancesOneSample(from: [1, 2, 3], to: [2, 3, 9]))
        // An unreadable value is still the same value a sample later.
        #expect(GraphMath.advancesOneSample(from: [.nan, 2, 3], to: [2, 3, .nan]))
        #expect(GraphMath.advancesOneSample(from: [1, .nan], to: [1, .nan, 0]))
    }

    @Test func valuesChangedInPlaceOrTwoSamplesOnAreNotOneSampleOn() {
        // Rescaled in place (a setting), not moved on.
        #expect(!GraphMath.advancesOneSample(from: [1, 2, 3], to: [2, 4, 6]))
        // Two samples on, or fewer values.
        #expect(!GraphMath.advancesOneSample(from: [1, 2, 3], to: [3, 4, 5]))
        #expect(!GraphMath.advancesOneSample(from: [1, 2], to: [1, 2, 3, 4]))
        #expect(!GraphMath.advancesOneSample(from: [1, 2, 3], to: [2, 3]))
        #expect(!GraphMath.advancesOneSample(from: [], to: []))
    }

    @Test func aGraphGainingALineStillAdvancesOnTheLinesItKeeps() {
        // An app joins a by-app graph: the first app's line moved on.
        #expect(GraphMath.advances(from: [[1, 2, 3], [5, 5, 5]], to: [[2, 3, 4], [9, 9, 9], [5, 5, 6]]))
        // The second app leaves: the first one's line moved on.
        #expect(GraphMath.advances(from: [[1, 2, 3], [7, 7, 7]], to: [[2, 3, 4]]))
        // The first app leaves, so the line in its place was another's.
        #expect(!GraphMath.advances(from: [[7, 8, 9], [1, 2, 3]], to: [[1, 2, 3]]))
        // Every line changed in place: a redraw, not a sample.
        #expect(!GraphMath.advances(from: [[1, 2, 3], [3, 4, 5]], to: [[2, 4, 6], [6, 8, 10], [1, 1, 1]]))
        #expect(!GraphMath.advances(from: [], to: [[1]]))
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

    @Test func fittingSpansTheFirstAndLastRecordsInTheRange() {
        let hour = 3_600.0
        let end = Date(timeIntervalSince1970: 2_000_000)
        let start = end.addingTimeInterval(-hour)
        // Records from 40 minutes before the end to 5 s before it.
        let recorded = end.addingTimeInterval(-2_400)...end.addingTimeInterval(-5)
        #expect(GraphMath.historyDomain(range: hour, end: end, recorded: recorded, fit: false) == start...end)
        // Fitted, the axis starts where the first record's ten seconds began and ends at the last record.
        #expect(GraphMath.historyDomain(range: hour, end: end, recorded: recorded, fit: true)
            == end.addingTimeInterval(-2_410)...end.addingTimeInterval(-5))
        // Records that cover the range leave it as it is.
        let full = start.addingTimeInterval(4)...end
        #expect(GraphMath.historyDomain(range: hour, end: end, recorded: full, fit: true) == start...end)
        // Nothing recorded: nothing to fit.
        #expect(GraphMath.historyDomain(range: hour, end: end, recorded: nil, fit: true) == start...end)
        // A record seconds old still gets a readable minute.
        let fresh = end.addingTimeInterval(-2)...end.addingTimeInterval(-2)
        #expect(GraphMath.historyDomain(range: hour, end: end, recorded: fresh, fit: true)
            == end.addingTimeInterval(-62)...end.addingTimeInterval(-2))
    }

    @Test func aRecordingStartsLateWhenItLeavesTheRangeOpeningEmpty() {
        let hour = 3_600.0
        let end = Date(timeIntervalSince1970: 2_000_000)
        #expect(GraphMath.recordingStartsLate(range: hour, end: end, recorded: end.addingTimeInterval(-1_140)...end))
        // Within the first 5% (three minutes) of the hour isn't late.
        #expect(!GraphMath.recordingStartsLate(range: hour, end: end, recorded: end.addingTimeInterval(-3_500)...end))
    }

    @Test func timeTicksThinOutBeforeTheirLabelsCrowd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let start = Date(timeIntervalSince1970: 6 * 3_600 + 11 * 60 + 23)
        let hour = start...start.addingTimeInterval(3_600)
        func clock(_ ticks: [Date]) -> [Int] { ticks.map { Int($0.timeIntervalSince1970) % 86_400 / 60 } }
        // Wide enough for every quarter hour.
        let wide = GraphMath.timeTicks(in: hour, step: 900, width: 640, labelWidth: 46, calendar: calendar)
        #expect(clock(wide) == [6 * 60 + 15, 6 * 60 + 30, 6 * 60 + 45, 7 * 60])
        // Room for three 46-point labels: half-hourly instead, never more than fit.
        let narrow = GraphMath.timeTicks(in: hour, step: 900, width: 180, labelWidth: 46, calendar: calendar)
        #expect(clock(narrow) == [6 * 60 + 30, 7 * 60])
        for width in stride(from: 60.0, through: 900, by: 7) {
            let ticks = GraphMath.timeTicks(in: hour, step: 900, width: width, labelWidth: 46, calendar: calendar)
            let positions = ticks.map { $0.timeIntervalSince(hour.lowerBound) / 3_600 * width }
            // Each label clears the ends and its neighbour.
            #expect(positions.allSatisfy { $0 >= 23 && $0 <= width - 23 }, "\(width) pt: \(positions)")
            #expect(zip(positions, positions.dropFirst()).allSatisfy { $1 - $0 >= 46 }, "\(width) pt: \(positions)")
        }
        // Until the width is known, it keeps the old 8% margins.
        #expect(GraphMath.timeTicks(in: hour, step: 900, width: 0, labelWidth: 46, calendar: calendar)
            == GraphMath.timeTicks(in: hour, step: 900, margin: 0.08, calendar: calendar))
    }
}
