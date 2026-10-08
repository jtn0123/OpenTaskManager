import Foundation
@testable import OTMKit
import Testing

private func timing(counter: GPUTimingEvidence.Interval? = .init(start: 10.001, end: 10.499),
                    command: GPUTimingEvidence.Interval? = .init(start: 10, end: 10.5),
                    wall: GPUTimingEvidence.Interval? = .init(start: 0, end: 0.501)) -> GPUTimingEvidence {
    GPUTimingEvidence(counterInterval: counter, commandBufferInterval: command, wallInterval: wall)
}

private func clock(_ cpu: UInt64, _ gpu: UInt64) -> GPUTimingEvidence.ClockSample {
    .init(cpuNanoseconds: cpu, gpuTicks: gpu)
}

struct GPUTimingEvidenceTests {
    @Test func verifiesOnlyContainedCountersAndCredibleCommandTime() {
        #expect(timing().verdict == .verified)
        #expect(timing(counter: .init(start: 9.9995, end: 10.5005)).verdict == .verified)
        #expect(timing(counter: .init(start: 9.998, end: 10.49)).verdict == .qualified(.countersDisagreed))
        #expect(timing(counter: .init(start: 10.01, end: 10.502)).verdict == .qualified(.countersDisagreed))
        #expect(timing(counter: nil).verdict == .qualified(.noCounterSampling))
        var unavailable = timing(counter: nil)
        unavailable.unavailableReason = .counterSamplesUnavailable
        #expect(unavailable.verdict == .qualified(.counterSamplesUnavailable))
        #expect(timing(wall: .init(start: 0, end: 0.6)).verdict == .qualified(.gpuTimeShort))
        // A short render interval is legitimate when its enclosing command buffer agrees with wall time.
        #expect(timing(counter: .init(start: 10.1, end: 10.2)).verdict == .verified)
        #expect(!GPUTimingEvidence.gpuTimeLooksShort(gpu: 0.020, wall: 0.024))
        #expect(!GPUTimingEvidence.gpuTimeLooksShort(gpu: 19, wall: 20))
        #expect(GPUTimingEvidence.gpuTimeLooksShort(gpu: 0.448, wall: 0.498))
    }

    @Test func missingAndInvalidIntervalsCannotVerify() {
        #expect(timing(command: nil).verdict == .qualified(.missingTiming))
        #expect(timing(wall: nil).verdict == .qualified(.missingTiming))
        let invalid: [GPUTimingEvidence.Interval] = [
            .init(start: 10, end: 10), .init(start: 10, end: 9), .init(start: -1, end: 1),
            .init(start: .nan, end: 10), .init(start: 0, end: .infinity),
        ]
        for interval in invalid {
            #expect(!interval.isValid)
            #expect(timing(command: interval).verdict == .qualified(.missingTiming))
            #expect(timing(wall: interval).verdict == .qualified(.missingTiming))
            #expect(timing(counter: interval).verdict == .qualified(.counterSamplesUnavailable))
        }
    }

    @Test func convertsTicksUsingBothNanosecondClockPairs() throws {
        let interval = try #require(GPUTimingEvidence.counterInterval(start: 120, end: 180,
            before: clock(10_000_000_000, 100), after: clock(11_000_000_000, 200)))
        #expect(abs(interval.start - 10.2) < 1e-12)
        #expect(abs(interval.end - 10.8) < 1e-12)
        // Subtracting before Double conversion keeps single ticks even near the integer limit.
        let high = UInt64.max - 100
        let tiny = try #require(GPUTimingEvidence.counterInterval(start: high + 1, end: high + 2,
            before: clock(1_000_000_000, high), after: clock(1_000_000_100, high + 10)))
        #expect(abs(tiny.seconds - 1e-8) < 1e-15)
        #expect(GPUTimingEvidence.counterInterval(start: 100, end: 200,
            before: clock(0, 100), after: clock(1_000_000_000, 200)) == .init(start: 0, end: 1))
    }

    @Test func rejectsMissingErrorAndNonMonotonicTicks() {
        let before = clock(1_000_000_000, 100)
        let after = clock(2_000_000_000, 200)
        #expect(GPUTimingEvidence.counterInterval(start: nil, end: 180, before: before, after: after) == nil)
        #expect(GPUTimingEvidence.counterInterval(start: 120, end: nil, before: before, after: after) == nil)
        #expect(GPUTimingEvidence.counterInterval(start: 120, end: 180, before: nil, after: after) == nil)
        #expect(GPUTimingEvidence.counterInterval(start: 120, end: 180, before: before, after: nil) == nil)
        // Metal's MTLCounterErrorValue is UInt64.max, for both resolved samples and clock pairs.
        for bad in [UInt64.max, 180, 201] {
            #expect(GPUTimingEvidence.counterInterval(start: bad, end: 180, before: before, after: after) == nil)
        }
        for bad in [UInt64.max, 120, 119, 201] {
            #expect(GPUTimingEvidence.counterInterval(start: 120, end: bad, before: before, after: after) == nil)
        }
        #expect(GPUTimingEvidence.counterInterval(start: 99, end: 180, before: before, after: after) == nil)
        let badClocks = [clock(UInt64.max, 100), clock(1_000_000_000, UInt64.max)]
        for bad in badClocks {
            #expect(GPUTimingEvidence.counterInterval(start: 120, end: 180, before: bad, after: after) == nil)
            #expect(GPUTimingEvidence.counterInterval(start: 120, end: 180, before: before, after: bad) == nil)
        }
        #expect(GPUTimingEvidence.counterInterval(start: 120, end: 180,
            before: before, after: clock(1_000_000_000, 200)) == nil)
        #expect(GPUTimingEvidence.counterInterval(start: 120, end: 180,
            before: before, after: clock(2_000_000_000, 100)) == nil)
        #expect(GPUTimingEvidence.counterInterval(start: 120, end: 180, before: before, after: before) == nil)
        #expect(GPUTimingEvidence.counterInterval(start: 120, end: 180, before: after, after: before) == nil)
        // A positive interval too small for the CPU epoch's Double precision is unavailable rather than zero seconds.
        #expect(GPUTimingEvidence.counterInterval(start: 101, end: 102,
            before: clock(UInt64.max - 100, 100), after: clock(UInt64.max - 1, 200)) == nil)
    }

    @Test func aSingleSuspectRepeatQualifiesTheWholeFigure() throws {
        var measurement = GPUBenchmarkMeasurement(repeats: [90, 100, 110], gpuSeconds: [0.1, 0.1, 0.1],
            wallSeconds: [0.501, 0.501, 0.501], unitsPerRepeat: 10, timingEvidence: [timing(), timing(), timing()])
        #expect(measurement.fillTimingVerdict == .verified)
        #expect(!measurement.gpuTimeLooksShort)
        #expect(measurement.timingCaveat(for: .fill) == nil)
        #expect(measurement.timingSource == "render-pass counters")
        #expect(measurement.spread == 0.2)
        #expect(measurement.medianCommandBufferSeconds == 0.5)
        #expect(measurement.timingDescription(for: .fill).contains("first pass's vertex start"))
        measurement.timingEvidence?[1] = timing(wall: .init(start: 0, end: 0.6))
        #expect(measurement.fillTimingVerdict == .qualified(.gpuTimeShort))
        #expect(measurement.gpuTimeLooksShort)
        measurement.timingEvidence?[1] = timing(counter: nil)
        #expect(measurement.fillTimingVerdict == .qualified(.noCounterSampling))
        #expect(measurement.timingSource == "render-pass counters / command buffer (mixed repeats)")
        #expect(measurement.timingCaveat(for: .fill) == .renderTimingUnverified)
        // Repeatability stays separate from the timing verdict.
        #expect(measurement.spread == 0.2)
        let encoded = try JSONEncoder().encode(measurement)
        #expect(try JSONDecoder().decode(GPUBenchmarkMeasurement.self, from: encoded) == measurement)
        measurement.timingEvidence = [timing(counter: nil), timing(counter: nil), timing(counter: nil)]
        #expect(measurement.timingSource == "command buffer")
        #expect(measurement.timingDescription(for: .fill).contains("No render-pass counter sampling on this GPU."))
        #expect(measurement.timingCaveat(for: .compute) == nil)
        #expect(measurement.timingCaveat(for: .memory) == nil)
        measurement.timingEvidence = [timing()]
        #expect(measurement.fillTimingVerdict == .qualified(.notRecorded))
        measurement.timingEvidence = nil
        #expect(measurement.fillTimingVerdict == .qualified(.notRecorded))
        #expect(measurement.timingSource == "command buffer")
        measurement.timingEvidence = []
        measurement.repeats = []
        #expect(measurement.fillTimingVerdict == .qualified(.notRecorded))
    }

    @Test func qualifiedFillIsVisibleButCannotWinOrLose() {
        let baseline = BenchmarkMeasurement(id: "fill", name: "Fill rate", value: 100, unit: .pixelsPerSecond,
            low: 99, high: 101, repeats: 3)
        for value in [50.0, 100, 200] {
            let qualified = BenchmarkMeasurement(id: "fill", name: "Fill rate", value: value, unit: .pixelsPerSecond,
                low: value * 0.99, high: value * 1.01, repeats: 3, caveat: .timingUnverified)
            let later = BenchmarkChange(baseline: baseline, compared: qualified, conditionSummary: "Power changed")
            let earlier = BenchmarkChange(baseline: qualified, compared: baseline)
            #expect(later.verdict == .timingUnverified)
            #expect(earlier.verdict == .timingUnverified)
            #expect(later.verdictExplanation == "Fill rate left out: timing not verified on this GPU")
            #expect(!later.isQualified)
            #expect(later.compared == value)
        }
        var verified = baseline
        verified.value = 200
        verified.low = 199
        verified.high = 201
        #expect(BenchmarkChange(baseline: baseline, compared: verified).verdict == .better)
        #expect(BenchmarkChange(baseline: verified, compared: baseline).verdict == .worse)
        var suspectCompute = baseline
        suspectCompute.id = "compute"
        suspectCompute.caveat = .timingUnverified
        var fasterCompute = verified
        fasterCompute.id = "compute"
        #expect(BenchmarkChange(baseline: suspectCompute, compared: fasterCompute).verdict == .timingUnverified)
        verified.low = 100
        #expect(BenchmarkChange(baseline: baseline, compared: verified).verdict == .withinSpread)
    }

    @Test func groupedSessionsKeepTimingQualifications() throws {
        let result = try JSONDecoder().decode(GPUBenchmarkResult.self, from: Data(gpuBenchmarkV1JSON.utf8))
        let runs = (1...3).map { index in
            var run = BenchmarkRun(result)
            run.id = "repeat-\(index)"
            run.date = run.date.addingTimeInterval(Double(index))
            run.session = BenchmarkSession(id: "timing-fixture", preflight: BenchmarkPreflight(
                readings: [], rows: [], settled: true, verdict: "Quiet", elapsed: 30), repeatIndex: index)
            run.measurements[0].caveat = index == 2 ? .renderTimingUnverified : nil
            run.measurements[0].timingDetail = index == 2 ? "No render-pass counter sampling on this GPU." : "Timing verified"
            return run
        }
        let grouped = try #require(BenchmarkRun.groupedSessions(runs).first)
        #expect(grouped.measurement("fill")?.caveat == .renderTimingUnverified)
        #expect(grouped.measurement("fill")?.timingDetail == "No render-pass counter sampling on this GPU.")
    }

    @Test func v1JSONStillLoadsWithItsCaveatAndCannotCompareWithV2() throws {
        let result = try JSONDecoder().decode(GPUBenchmarkResult.self, from: Data(gpuBenchmarkV1JSON.utf8))
        #expect(result.suiteVersion == 1)
        let fill = try #require(result.result(.fill))
        #expect(fill.timingEvidence == nil)
        #expect(fill.gpuTimeLooksShort)
        #expect(fill.median == 3.4e11)
        #expect(fill.fillTimingVerdict == .qualified(.notRecorded))
        #expect(BenchmarkRun(result).measurement("fill")?.caveat == .timingUnverified)
        #expect(result.timingNote?.hasPrefix("The GPU timed fill rate at 448 ms a repeat, against 498 ms") == true)
        var newer = result
        newer.date = newer.date.addingTimeInterval(60)
        newer.suiteVersion = GPUBenchmark.suiteVersion
        #expect(!result.isComparable(with: newer))
        #expect(BenchmarkComparison.refusal(BenchmarkRun(result), BenchmarkRun(newer)) == .differentVersions(.gpu, 1, 2))
        #expect(try JSONDecoder().decode(GPUBenchmarkResult.self, from: JSONEncoder().encode(result)) == result)
    }
}

/// A saved v1 result, with no evidence, context or session fields.
private let gpuBenchmarkV1JSON = """
{
  "version": 1, "date": 100, "suiteVersion": 1,
  "configuration": {
    "computeThreads": 1048576, "computeIterations": 1024, "computeSeedGroups": 64,
    "memoryBytes": 268435456, "memoryLanes": 131072, "fillSize": 2048, "fillLayers": 256,
    "warmUpSeconds": 0.5, "repeatSeconds": 0.5, "repeats": 5, "seed": 5716279662461146417
  },
  "device": { "name": "Saved GPU", "model": "SavedMac", "unifiedMemory": true, "workingSetBytes": 4294967296 },
  "osVersion": "macOS fixture", "appVersion": "otm v1 fixture", "optimized": true,
  "thermalStateAtStart": "nominal", "thermalStateAtEnd": "nominal", "lowPowerMode": false, "seconds": 9,
  "workloads": [{ "workload": "fill", "measurement": {
    "repeats": [340000000000, 340000000000, 340000000000],
    "gpuSeconds": [0.448, 0.448, 0.448], "wallSeconds": [0.498, 0.498, 0.498], "unitsPerRepeat": 100
  }}]
}
"""
