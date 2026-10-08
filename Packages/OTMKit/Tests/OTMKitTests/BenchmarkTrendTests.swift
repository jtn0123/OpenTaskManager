import Foundation
@testable import OTMKit
import Testing

// MARK: - Fixtures

/// A run of `kind` at `time` with one figure per entry in `figures`, each a
/// median then its slowest and fastest repeats, `[100, 98, 102]`, or a
/// figure measured once, `[300]`.
private func run(_ kind: BenchmarkKind = .cpu, at time: TimeInterval, version: Int = 1, optimized: Bool? = true,
                 machine: String = "mac-a", target: String? = nil, file: String = "1 GB",
                 figures: [String: [Double]] = ["speed": [100, 98, 102]],
                 caveat: BenchmarkFigureCaveat? = nil, conditions: [String] = []) -> BenchmarkRun {
    let date = Date(timeIntervalSince1970: time)
    let measurements = figures.keys.sorted().map { id in
        let values = figures[id] ?? [0]
        let low = values.count == 3 ? values[1] : nil
        let high = values.count == 3 ? values[2] : nil
        return BenchmarkMeasurement(id: id, name: id.capitalized, value: values.first ?? 0, unit: .megabytesPerSecond, low: low, high: high,
                                    repeats: low == nil ? nil : 5, caveat: id == "fill" ? caveat : nil)
    }
    let usesMachine = kind == .cpu || kind == .gpu
    return BenchmarkRun(id: BenchmarkRun.id(kind, date), kind: kind, date: date, workloadVersion: version,
                        settings: [BenchmarkSetting(name: "Test file", value: file)],
                        build: optimized.map { BenchmarkBuild(app: "OpenTaskManager 0.1.0", optimized: $0) },
                        machine: usesMachine ? BenchmarkMachine(key: machine, name: machine == "mac-a" ? "Apple M5 Pro" : "Apple M2") : nil,
                        target: target.map { BenchmarkTarget(key: $0, name: $0) }, osVersion: nil, conditions: conditions,
                        measurements: measurements)
}

struct BenchmarkTrendTests {
    // MARK: Lines

    @Test func onlyComparableRunsShareALine() {
        let runs = [
            run(at: 100), run(at: 200, optimized: false), run(at: 300), run(at: 400, optimized: false), run(at: 500, version: 2),
        ]
        let trend = BenchmarkTrend(runs: runs.shuffled())
        // Newest line first: v2's run, then debug's (newest 400), then release v1's (newest 300).
        #expect(trend.lines.map(\.runIDs) == [[runs[4].id], [runs[1].id, runs[3].id], [runs[0].id, runs[2].id]])
        #expect(trend.lines.map(\.id) == [0, 1, 2])
        // Every pair on a line can be compared; no pair across lines can.
        for line in trend.lines {
            let members = runs.filter { line.runIDs.contains($0.id) }
            for first in members {
                for second in members where first.id != second.id {
                    #expect(BenchmarkComparison.refusal(first, second) == nil)
                }
            }
            for other in runs where !line.runIDs.contains(other.id) {
                #expect(members.allSatisfy { BenchmarkComparison.refusal($0, other) != nil })
            }
        }
    }

    @Test func linesAreNamedByWhatSetsThemApart() {
        let builds = BenchmarkTrend(runs: [run(at: 100), run(at: 200, optimized: false)])
        #expect(builds.lines.map(\.title) == ["Debug build", "Release build"])

        let versions = BenchmarkTrend(runs: [run(at: 100), run(at: 200, optimized: false), run(at: 300, version: 2)])
        #expect(versions.lines.map(\.title) == ["Workloads v2 · Release build", "Workloads v1 · Debug build", "Workloads v1 · Release build"])

        let volumes = BenchmarkTrend(runs: [run(.disk, at: 100, optimized: nil, target: "Macintosh HD"),
                                            run(.disk, at: 200, optimized: nil, target: "Backup")])
        #expect(volumes.lines.map(\.title) == ["Backup", "Macintosh HD"])

        let files = BenchmarkTrend(runs: [run(.disk, at: 100, optimized: nil, target: "HD"),
                                          run(.disk, at: 200, optimized: nil, target: "HD", file: "512 MB")])
        #expect(files.lines.map(\.title) == ["Test file 512 MB", "Test file 1 GB"])

        let macs = BenchmarkTrend(runs: [run(at: 100), run(at: 200, machine: "mac-b")])
        #expect(macs.lines.map(\.title) == ["Apple M2", "Apple M5 Pro"])
    }

    @Test func oneLineNeedsNoName() {
        let trend = BenchmarkTrend(runs: [run(at: 100), run(at: 200), run(at: 300)])
        #expect(trend.lines.count == 1)
        #expect(trend.lines[0].title.isEmpty)
        #expect(trend.lines[0].runIDs.count == 3)
    }

    // MARK: Points

    @Test func pointsShareOneAxisOldestFirstAndKeepTheirSpread() throws {
        let runs = [run(at: 300, figures: ["speed": [110, 108, 113]]), run(at: 100), run(at: 200, optimized: false)]
        let trend = BenchmarkTrend(runs: runs)
        #expect(trend.kind == .cpu)
        #expect(trend.dates == [100, 200, 300].map { Date(timeIntervalSince1970: $0) })
        let figure = try #require(trend.figures.first)
        #expect(figure.id == "speed")
        #expect(figure.points.map(\.sequence) == [0, 1, 2])
        // The release runs are line 0 (it has the newest run); the debug run is line 1.
        #expect(figure.points.map(\.line) == [0, 1, 0])
        #expect(figure.points[2].value == 110)
        #expect(figure.points[2].low == 108)
        #expect(figure.points[2].high == 113)
        #expect(figure.points[2].repeats == 5)
        #expect(figure.hasSpread)
        #expect(figure.scaleUnit == "MB/s")
        #expect(figure.divisor == 1)
    }

    @Test func aFigureInDoubtIsMarkedAtItsPoint() throws {
        let trend = BenchmarkTrend(runs: [
            run(.gpu, at: 100, figures: ["fill": [300, 290, 310]]),
            run(.gpu, at: 200, figures: ["fill": [335, 300, 370]], caveat: .timingUnverified),
        ])
        let fill = try #require(trend.figures.first)
        #expect(fill.points.map(\.caveat) == [nil, .timingUnverified])
    }

    @Test func aFigureOnlySomeRunsHaveKeepsItsPlaceOnTheAxis() {
        let trend = BenchmarkTrend(runs: [
            run(.network, at: 100, optimized: nil, target: "en0", figures: ["download": [300], "latency": [16]]),
            run(.network, at: 200, optimized: nil, target: "en0", figures: ["download": [310]]),
        ])
        #expect(trend.figures.map(\.id) == ["download", "latency"])
        #expect(trend.figures[1].points.map(\.sequence) == [0])
        #expect(!trend.figures[0].hasSpread)
    }

    @Test func figuresGoInTheNewestRunsOrder() {
        let trend = BenchmarkTrend(runs: [run(at: 100, figures: ["b": [1], "old": [1]]),
                                          run(at: 200, figures: ["a": [1], "b": [1]])])
        #expect(trend.figures.map(\.id) == ["a", "b", "old"])
    }

    // MARK: Baseline

    @Test func comparableRunsCarryTheirChangeFromTheBaseline() throws {
        let runs = [
            run(at: 100, figures: ["speed": [100, 99.5, 100.5]]),
            run(at: 200, figures: ["speed": [90, 89, 91]]),
            run(at: 300, figures: ["speed": [100.8, 100.6, 101.0]]),
            run(at: 400, optimized: false, figures: ["speed": [20, 19, 21]]),
            run(at: 500, figures: ["speed": [101, 99, 103]]),
        ]
        let trend = BenchmarkTrend(runs: runs, baseline: runs[0].id)
        #expect(trend.baseline == runs[0].id)
        let figure = try #require(trend.figures.first)
        let points = figure.points
        #expect(points[0].isBaseline)
        #expect(points[0].fromBaseline?.verdict == .unchanged)
        #expect(points[1].fromBaseline?.verdict == .worse)
        #expect(abs((points[1].fromBaseline?.change ?? 0) + 0.1) < 1e-12)
        // Past both ranges, but by under 1%.
        #expect(points[2].fromBaseline?.verdict == .negligible)
        // A debug run can't be compared with a release baseline.
        #expect(points[3].fromBaseline == nil)
        #expect(points[4].fromBaseline?.verdict == .withinSpread)
        #expect(figure.baseline?.runID == runs[0].id)
        #expect(figure.latestCompared?.runID == runs[4].id)
    }

    @Test func theLatestComparedSkipsRunsTheBaselineCantBeComparedWith() throws {
        let runs = [run(at: 100), run(at: 200), run(at: 300, optimized: false)]
        let figure = try #require(BenchmarkTrend(runs: runs, baseline: runs[0].id).figures.first)
        #expect(figure.latestCompared?.runID == runs[1].id)
        // The baseline alone has nothing to compare.
        let alone = try #require(BenchmarkTrend(runs: [runs[0], runs[2]], baseline: runs[0].id).figures.first)
        #expect(alone.latestCompared == nil)
    }

    @Test func aBaselineThatIsntSavedIsIgnored() throws {
        let trend = BenchmarkTrend(runs: [run(at: 100), run(at: 200)], baseline: "cpu-1")
        #expect(trend.baseline == nil)
        let figure = try #require(trend.figures.first)
        #expect(figure.baseline == nil)
        #expect(figure.points.allSatisfy { $0.fromBaseline == nil && !$0.isBaseline })
        #expect(figure.latestCompared == nil)
    }

    // MARK: Range

    @Test func theRangeCoversEverySpreadWithRoomEachSide() throws {
        let figure = try #require(BenchmarkTrend(runs: [run(at: 100, figures: ["speed": [100, 80, 120]]),
                                                        run(at: 200, figures: ["speed": [150, 140, 160]])]).figures.first)
        // 80 to 160, a tenth of the 80 more each side.
        #expect(abs(figure.domain.lowerBound - 72) < 1e-9)
        #expect(abs(figure.domain.upperBound - 168) < 1e-9)
    }

    @Test func aFlatTrendKeepsAMinimumRange() throws {
        let figure = try #require(BenchmarkTrend(runs: [run(at: 100, figures: ["speed": [100, 99.9, 100.1]]),
                                                        run(at: 200, figures: ["speed": [100, 99.9, 100.1]])]).figures.first)
        // At least 5% of 100 wide, plus a tenth of that each side, centred.
        #expect(abs((figure.domain.upperBound - figure.domain.lowerBound) - 6) < 1e-9)
        #expect(abs((figure.domain.upperBound + figure.domain.lowerBound) / 2 - 100) < 1e-9)
    }

    @Test func theRangeNeverGoesBelowZero() throws {
        let figure = try #require(BenchmarkTrend(runs: [run(at: 100, figures: ["speed": [1, 0, 2]])]).figures.first)
        #expect(figure.domain.lowerBound == 0)
        #expect(figure.domain.upperBound > 2)
    }

    @Test func ticksAreRoundSoTheirLabelsReadExactly() {
        // 104.3 to 112.8: steps of 1 would give 8 ticks, so steps of 2.
        let speeds = BenchmarkTrend.ticks(104.3...112.8, divisor: 1)
        #expect(speeds.values == [106, 108, 110, 112])
        #expect(speeds.decimals == 0)
        // Read in GB/s, 5.12 to 5.71: steps of 0.2, one decimal, back in B/s.
        let memory = BenchmarkTrend.ticks(5.12e9...5.71e9, divisor: 1e9)
        #expect(memory.values.count == 3)
        #expect(zip(memory.values, [5.2e9, 5.4e9, 5.6e9]).allSatisfy { abs($0 - $1) < 1 })
        #expect(memory.decimals == 1)
        #expect(BenchmarkTrend.ticks(1...1, divisor: 1).values.isEmpty)
    }

    @Test func aFiguresTicksAreLabelledInItsScale() throws {
        let figure = try #require(BenchmarkTrend(runs: [run(at: 100, figures: ["speed": [30.9, 30.6, 31.1]]),
                                                        run(at: 200, figures: ["speed": [31.6, 31.3, 31.9]])]).figures.first)
        #expect(!figure.ticks.isEmpty && figure.ticks.count <= BenchmarkTrend.maximumTicks)
        #expect(figure.ticks.allSatisfy { figure.domain.contains($0) })
        #expect(figure.tickLabel(31) == Format.fixed(31, figure.tickDecimals))
        #expect(BenchmarkTrend.Figure(id: "x", title: "X", unit: .operationsPerSecond, points: [], scaleUnit: "IOPS", divisor: 1,
                                      domain: 0...1, ticks: [], tickDecimals: 0).tickLabel(12_500) == 12_500.formatted())
    }

    // MARK: The pair a compare link picks

    @Test func theLatestPairIsTheNewestAndTheNewestComparableBeforeIt() throws {
        let runs = [run(at: 100), run(at: 200), run(at: 300, optimized: false), run(at: 400)]
        let pair = try #require(BenchmarkComparison.latestPair(runs.shuffled()))
        #expect(pair.earlier.id == runs[1].id)
        #expect(pair.later.id == runs[3].id)
        // Nothing earlier can be compared with a lone debug run.
        #expect(BenchmarkComparison.latestPair([run(at: 100), run(at: 200, optimized: false)]) == nil)
        #expect(BenchmarkComparison.latestPair([run(at: 100)]) == nil)
        #expect(BenchmarkComparison.latestPair([]) == nil)
    }
}
