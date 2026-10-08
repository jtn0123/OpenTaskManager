import Foundation
@testable import OTMKit
import Testing

// MARK: - Fixtures

private let machine = CPUBenchmarkMachine(chip: "Apple M5 Pro", model: "Mac17,8", logicalCores: 18,
                                          coreTypes: [.init(name: "Super", cores: 6), .init(name: "Performance", cores: 12)],
                                          memoryBytes: 48 << 30)

/// Windows of `seconds` each, with these throughputs and thermal states (nominal where left out).
private func windows(_ throughputs: [Double], thermal: [ThermalState] = [], seconds: Double = 10) -> [CPUSustainedWindow] {
    throughputs.enumerated().map { index, throughput in
        CPUSustainedWindow(start: Double(index) * seconds, seconds: seconds, throughput: throughput,
                           slices: [throughput * 0.99, throughput, throughput * 1.01],
                           thermalState: index < thermal.count ? thermal[index] : .nominal)
    }
}

private func sustained(at time: TimeInterval, minutes: Int = 2, throughputs: [Double] = [100, 99, 98, 98, 97, 97, 96, 98, 97],
                       optimized: Bool = true, thermal: [ThermalState] = []) -> CPUSustainedResult {
    CPUSustainedResult(date: Date(timeIntervalSince1970: time), configuration: .standard(minutes: minutes), workers: 18, machine: machine,
                       osVersion: "macOS 27.2 (27C61)", appVersion: "OpenTaskManager 0.1.0", optimized: optimized,
                       thermalStateAtStart: .nominal, thermalStateAtEnd: thermal.last ?? .nominal, lowPowerMode: false, seconds: 121,
                       windows: windows(throughputs, thermal: thermal))
}

private func cpu(at time: TimeInterval) -> CPUBenchmarkResult {
    let workloads = CPUWorkload.allCases.map {
        CPUWorkloadResult(workload: $0, single: CPUBenchmarkMeasurement(workers: 1, repeats: [10, 11, 9]),
                          multi: CPUBenchmarkMeasurement(workers: 18, repeats: [120, 100, 110]))
    }
    return CPUBenchmarkResult(date: Date(timeIntervalSince1970: time), suiteVersion: 1, configuration: .standard, machine: machine,
                              osVersion: "macOS 27.2 (27C61)", appVersion: "OpenTaskManager 0.1.0", optimized: true,
                              thermalStateAtStart: .nominal, thermalStateAtEnd: .nominal, lowPowerMode: false, seconds: 21,
                              workloads: workloads)
}

/// Tiny kernels and windows, so a whole run takes a fraction of a second.
private var quick: CPUSustainedConfiguration {
    var kernels = CPUBenchmarkConfiguration()
    kernels.matrixSize = 16
    return CPUSustainedConfiguration(durationSeconds: 0.06, windowSeconds: 0.02, slicesPerWindow: 2, warmUpSeconds: 0.01, kernels: kernels)
}

// MARK: - The summary's maths

struct CPUSustainedSummaryTests {
    @Test func theSustainedLevelIsTheMedianOfTheLastThird() throws {
        let summary = try #require(CPUSustainedSummary(windows: windows([100, 99, 98, 98, 97, 97, 96, 98, 97])))
        #expect(summary.first == 100)
        // Nine windows: the last three, 96, 98 and 97.
        #expect(summary.sustainedWindows == 3)
        #expect(summary.sustained == 97)
        #expect(summary.sustainedLow == 96)
        #expect(summary.sustainedHigh == 98)
        #expect(summary.ratio == 0.97)
        #expect(summary.heldPercent == 97)
        #expect(summary.heldText == "Held 97% of its starting speed")
        #expect(summary.lowest == 96)
        #expect(summary.highest == 100)
        #expect(summary.windowCount == 9)
    }

    @Test func theLastThirdRoundsUp() {
        #expect([1, 2, 3, 4, 5, 6, 12, 30].map(CPUSustainedSummary.lastThird) == [1, 1, 1, 2, 2, 2, 4, 10])
        // An even count takes the middle two's mean.
        #expect(CPUSustainedSummary(windows: windows([100, 90, 80, 70, 60, 50, 40, 30, 20, 10, 8, 6]))?.sustained == 9)
    }

    @Test func saysPlainlyHowMuchItHeld() {
        #expect(CPUSustainedSummary(windows: windows([100, 100, 100]))?.heldText == "Held its starting speed")
        #expect(CPUSustainedSummary(windows: windows([100, 101, 103]))?.heldText == "Ended 3% faster than it started")
        #expect(CPUSustainedSummary(windows: windows([200, 150, 120]))?.heldText == "Held 60% of its starting speed")
        let empty = CPUSustainedSummary(windows: windows([0, 10, 10]))
        #expect(empty?.ratio == nil)
        #expect(empty?.heldText == "Nothing was measured in the first window")
        #expect(CPUSustainedSummary(windows: []) == nil)
    }

    @Test func saysWhatChangedWithFigures() {
        let summary = CPUSustainedSummary(windows: windows([100, 99, 98, 98, 97, 97, 96, 98, 97]))
        let text = summary?.changeText(format: { "\(Int($0)) u/s" }, windowSeconds: 10)
        #expect(text == "The first 10 s window ran at 100 u/s; the last 3 settled at a median of 97 u/s (96 u/s to 98 u/s).")
        let two = CPUSustainedSummary(windows: windows([100, 95]))?.changeText(format: { "\(Int($0))" }, windowSeconds: 10)
        #expect(two == "The first 10 s window ran at 100; the last window ran at 95.")
        let one = CPUSustainedSummary(windows: windows([100]))?.changeText(format: { "\(Int($0))" }, windowSeconds: 10)
        #expect(one == "The first 10 s window ran at 100, the only window of the run.")
    }

    @Test func reportsTheThermalStateWithoutClaimingWhy() throws {
        let steady = try #require(CPUSustainedSummary(windows: windows([100, 99, 98]), thermalAtStart: .nominal))
        #expect(steady.thermalText == "macOS reported thermal state nominal throughout.")
        let warming = try #require(CPUSustainedSummary(windows: windows([100, 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 89],
                                                                        thermal: [.nominal, .nominal, .nominal, .nominal, .fair,
                                                                                  .fair, .fair, .fair, .fair, .serious]),
                                                       thermalAtStart: .nominal))
        // A window's state is as it ended: the fifth ends at 0:50, the tenth at 1:40.
        #expect(warming.thermalText == "macOS reported thermal state nominal at the start, fair from 0:50, serious from 1:40 "
            + "and nominal from 1:50.")
        #expect(warming.worstThermal == .serious)
        #expect(!warming.thermalText.contains("throttl"))
        #expect(!warming.heldText.contains("throttl"))
        let started = try #require(CPUSustainedSummary(windows: windows([100, 99], thermal: [.fair, .fair]), thermalAtStart: .nominal))
        #expect(started.thermalText == "macOS reported thermal state nominal at the start, fair from 0:10.")
    }

    @Test func chartsFromZeroInClockTicks() {
        let trace = BenchmarkSustainedTrace(unit: .flopsPerSecond, windowSeconds: 10, thermalAtStart: .nominal,
                                            windows: windows([100, 99, 98, 98, 97, 97, 96, 98, 97]))
        let axis = trace.axis
        #expect(axis.top == 125)
        #expect(axis.ticks == [0, 50, 100])
        #expect(axis.unit == "FLOP/s")
        #expect(axis.label(50) == "50")
        #expect(axis.seconds == 90)
        #expect(axis.timeTicks == [0, 30, 60, 90])
        let fast = SustainedChartAxis(unit: .flopsPerSecond, highest: 1.6e11, seconds: 120)
        #expect(fast.unit == "GFLOP/s")
        #expect(fast.top == 2e11)
        #expect(fast.ticks == [0, 1e11, 2e11])
        #expect(fast.label(1e11) == "100")
        #expect(fast.timeTicks == [0, 30, 60, 90, 120])
        #expect(SustainedChartAxis(unit: .flopsPerSecond, highest: 1e9, seconds: 300).timeTicks == [0, 60, 120, 180, 240, 300])
        let empty = SustainedChartAxis(unit: .flopsPerSecond, highest: 0, seconds: 0)
        #expect(empty.top == 1)
        #expect(empty.seconds == 1)
    }

    @Test func clockReadsMinutesAndSeconds() {
        #expect(CPUSustainedSummary.clock(0) == "0:00")
        #expect(CPUSustainedSummary.clock(5) == "0:05")
        #expect(CPUSustainedSummary.clock(100) == "1:40")
        #expect(CPUSustainedSummary.clock(300.4) == "5:00")
    }
}

// MARK: - The run

struct CPUSustainedTests {
    @Test func offersTwoAndFiveMinutes() {
        let two = CPUSustainedConfiguration.standard()
        #expect(two.durationSeconds == 120)
        #expect(two.windowCount == 12)
        #expect(two.sliceSeconds == 2)
        #expect(two.plannedSeconds == 120.5)
        #expect(two.durationText == "2 min")
        #expect(two.workload == .floatingPoint)
        #expect(two.kernels == .standard)
        #expect(CPUSustainedConfiguration.standard(minutes: 5).windowCount == 30)
        // Any other length falls back to the default.
        #expect(CPUSustainedConfiguration.standard(minutes: 3).durationSeconds == 120)
        #expect(CPUSustainedConfiguration.offeredMinutes == [2, 5])
    }

    @Test func runsItsWindowsAndReportsProgress() throws {
        let reports = Locked<[CPUSustainedProgress]>([])
        let result = try CPUSustained.run(configuration: quick, workers: 2, appVersion: "otm test") { progress in
            reports.update { $0.append(progress) }
        }
        #expect(result.windows.count == 3)
        #expect(result.workers == 2)
        #expect(result.suiteVersion == CPUSustained.suiteVersion)
        #expect(result.windows.allSatisfy { $0.throughput > 0 && $0.slices.count == 2 })
        #expect(zip(result.windows, result.windows.dropFirst()).allSatisfy { $0.start < $1.start })
        #expect(result.summary != nil)
        let seen = reports.value
        #expect(seen.first?.warmingUp == true)
        #expect(seen.last?.fraction == 1)
        #expect(seen.last?.windows.count == 3)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
    }

    @Test func aCancelledRunStops() {
        let cancellation = CPUBenchmarkCancellation()
        cancellation.cancel()
        #expect(throws: CPUBenchmarkError.cancelled) {
            try CPUSustained.run(configuration: quick, workers: 2, appVersion: "otm test", cancellation: cancellation)
        }
    }

    @Test func keepsItsOwnHistoryFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-sustained-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SpeedTestHistory<CPUSustainedResult>.cpuSustained.file.lastPathComponent == "cpu-sustained.json")
        let history = SpeedTestHistory<CPUSustainedResult>(file: folder.appendingPathComponent("cpu-sustained.json"), keptPerKey: 10)
        try history.append(sustained(at: 100))
        try history.append(sustained(at: 200, minutes: 5))
        #expect(history.load().map(\.date.timeIntervalSince1970) == [200, 100])
        try SpeedTestHistory<CPUBenchmarkResult>(file: folder.appendingPathComponent("cpu-benchmark.json")).append(cpu(at: 150))
        let runs = BenchmarkLibrary(folder: folder).load()
        #expect(runs.map(\.kind) == [.sustained, .cpu, .sustained])
    }
}

// MARK: - As a saved run, and its cohort

struct CPUSustainedRunTests {
    @Test func adaptsASustainedResult() throws {
        let run = BenchmarkRun(sustained(at: 100))
        #expect(run.kind == .sustained)
        #expect(run.kind.title == "Sustained CPU run")
        #expect(run.measurements.map(\.id) == ["firstWindow", "sustained"])
        let first = try #require(run.measurement("firstWindow"))
        #expect(first.value == 100)
        #expect(first.low == 99)
        #expect(first.high == 101)
        let level = try #require(run.measurement("sustained"))
        #expect(level.value == 97)
        #expect(level.low == 96)
        #expect(level.high == 98)
        #expect(level.title == "Sustained, median of the last 3")
        #expect(level.unit == .flopsPerSecond)
        #expect(run.settings.map(\.name) == ["Workload", "Workers", "Duration", "Windows", "Warm-up", "Seed"])
        #expect(run.settings.first { $0.name == "Duration" }?.value == "2 min")
        #expect(run.settings.first { $0.name == "Windows" }?.value == "12 × 10 s, 5 slices each")
        #expect(run.build?.optimized == true)
        #expect(run.sustained?.windows.count == 9)
        #expect(run.sustained?.narrative?.hasPrefix("Held 97% of its starting speed. The first 10 s window ran at 100 FLOP/s;") == true)
        #expect(run.sustained?.narrative?.hasSuffix("macOS reported thermal state nominal throughout.") == true)
        #expect(BenchmarkRun(sustained(at: 100, thermal: [.nominal, .serious])).conditions == ["thermal pressure serious"])
    }

    @Test func neverComparesWithTheShortBenchmark() {
        guard case let .refused(refusal) = BenchmarkComparison.compare(BenchmarkRun(cpu(at: 100)), BenchmarkRun(sustained(at: 200))) else {
            Issue.record("A sustained run must not compare with a short one")
            return
        }
        #expect(refusal == .differentTests(.cpu, .sustained))
        #expect(refusal.reason.hasPrefix("A sustained run is compared only with other sustained runs"))
    }

    @Test func comparesOnlyRunsOfTheSameLength() {
        guard case let .refused(refusal) = BenchmarkComparison.compare(BenchmarkRun(sustained(at: 100)),
                                                                      BenchmarkRun(sustained(at: 200, minutes: 5))) else {
            Issue.record("A 2-minute run must not compare with a 5-minute one")
            return
        }
        #expect(refusal == .differentSettings(name: "Duration", baseline: "2 min", compared: "5 min"))
        guard case let .compared(comparison) = BenchmarkComparison.compare(
            BenchmarkRun(sustained(at: 100)), BenchmarkRun(sustained(at: 200, throughputs: [110, 108, 107, 106, 106, 105, 105, 104, 104]))
        ) else {
            Issue.record("Two 2-minute runs compare")
            return
        }
        #expect(comparison.changes.map(\.id) == ["firstWindow", "sustained"])
        #expect(comparison.changes.allSatisfy { $0.verdict == .better })
        // A debug and a release run refuse, as the short benchmark's do.
        if case .compared = BenchmarkComparison.compare(BenchmarkRun(sustained(at: 100)), BenchmarkRun(sustained(at: 200, optimized: false))) {
            Issue.record("A debug and a release sustained run must not compare")
        }
    }

    @Test func exportsSustainedRunsAndReadsVersionOne() throws {
        let runs = [BenchmarkRun(sustained(at: 0)), BenchmarkRun(sustained(at: 60, throughputs: [101, 100, 99]))]
        let export = BenchmarkExport(exported: Date(timeIntervalSince1970: 120), app: "otm", runs: runs, comparisons: [(runs[0], runs[1])])
        let read = try BenchmarkExport.read(export.json())
        #expect(read == export)
        #expect(read.version == 2)
        #expect(read.runs.last?.sustained?.windows.count == 9)
        let markdown = export.markdown(timeZone: TimeZone(identifier: "UTC") ?? .current)
        #expect(markdown.contains("## Sustained CPU run"))
        #expect(markdown.contains("- 1970-01-01 00:00: Context not recorded. Held 97% of its starting speed."))

        // A file from before sustained runs and contexts still reads.
        var old = BenchmarkExport(exported: Date(timeIntervalSince1970: 0), app: "otm", runs: [BenchmarkRun(cpu(at: 0))])
        old.version = 1
        #expect(try BenchmarkExport.read(old.json()).runs.first?.context == nil)
    }
}

/// A value several threads can update.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}
