import Foundation
@testable import OTMKit
import Testing

struct BenchmarkConditionsTests {
    private func run(_ kind: BenchmarkKind = .cpu, at time: Double, value: Double = 100,
                     unit: BenchmarkUnit = .megabytesPerSecond, context: BenchmarkContext? = nil,
                     repeats: Bool = true) -> BenchmarkRun {
        BenchmarkRun(id: "\(kind.rawValue)-\(time)", kind: kind, date: Date(timeIntervalSince1970: time), workloadVersion: 1,
                     settings: [], build: nil, machine: nil, target: nil, osVersion: nil, conditions: [],
                     measurements: [BenchmarkMeasurement(id: "speed", name: "Speed", value: value, unit: unit,
                                                         low: repeats ? value - 1 : nil, high: repeats ? value + 1 : nil)],
                     context: context)
    }

    private func state(power: BenchmarkPowerSource = .ac, busy: Double = 0.03,
                       thermal: ThermalState = .nominal, memory: UInt64 = 20 << 30) -> BenchmarkContext {
        BenchmarkContext(power: power, hasBattery: true, lowPowerMode: false, thermalAtStart: thermal,
                         cpuLoad: BenchmarkCPULoad(busy: busy, seconds: 5, source: .sampler), availableMemoryBytes: memory)
    }

    @Test(arguments: BenchmarkKind.allCases)
    func aWarnedStartQualifiesEveryFamily(_ kind: BenchmarkKind) throws {
        let earlier = run(kind, at: 1, context: state())
        // Disk and Internet runs measure once: no spread, so never a Better or Worse to qualify.
        let repeats = kind != .network && kind != .disk
        let later = run(kind, at: 2, value: 70, context: state(power: .battery, busy: 0.38), repeats: repeats)
        guard case let .compared(comparison) = BenchmarkComparison.compare(later, earlier) else {
            Issue.record("Different conditions still allow a comparison")
            return
        }
        let change = try #require(comparison.changes.first)
        #expect(change.verdictTitle == (repeats ? "Lower · conditions differ" : "Measured once"))
        #expect(change.conditionSummary == "Later run on battery, 38% CPU busy at start")
        #expect(comparison.contextWarnings.map(\.topic) == [.power, .cpuLoad])
        #expect(!comparison.verdictSummary.contains("worse"))
        let trend = BenchmarkTrend(runs: [later, earlier], baseline: earlier.id)
        #expect(trend.figures.first?.latestCompared?.fromBaseline?.verdictWord == (repeats ? "lower · conditions differ" : "measured once"))
    }

    @Test func aMoveWithinSpreadKeepsItsVerdictWhenConditionsDiffer() throws {
        let earlier = run(at: 1, context: state())
        let later = run(at: 2, value: 100.5, context: state(power: .battery, busy: 0.38))
        guard case let .compared(comparison) = BenchmarkComparison.compare(earlier, later) else {
            Issue.record("Different conditions still allow a comparison")
            return
        }
        let change = try #require(comparison.changes.first)
        #expect(change.verdict == .withinSpread)
        #expect(!change.isQualified)
        #expect(change.verdictTitle == BenchmarkChange.Verdict.withinSpread.title)
        #expect(change.verdictExplanation == BenchmarkChange.Verdict.withinSpread.explanation)
        #expect(change.conditionSummary == "Later run on battery, 38% CPU busy at start")
    }

    @Test func comparableStartsKeepBetterAndWorse() throws {
        let earlier = run(at: 1, context: state())
        let higher = run(at: 2, value: 130, context: state(busy: 0.07))
        let lower = run(at: 3, value: 70, context: state())
        for (later, expected) in [(higher, "Better"), (lower, "Worse")] {
            guard case let .compared(comparison) = BenchmarkComparison.compare(earlier, later) else {
                Issue.record("Comparable runs must compare")
                return
            }
            #expect(comparison.changes.first?.verdictTitle == expected)
            #expect(comparison.changes.first?.conditionSummary == nil)
        }
    }

    @Test func equalAdverseConditionsRemainComparable() {
        let hot = state(busy: 0.4, thermal: .fair)
        let earlier = run(at: 1, context: hot)
        let later = run(at: 2, value: 130, context: hot)
        #expect(BenchmarkComparison.contextWarnings(earlier, later).map(\.topic) == [.thermal, .cpuLoad])
        #expect(BenchmarkComparison.conditionSummary(earlier, later) == nil)
    }

    @Test func eachWarnedDifferenceHasACompactAccount() {
        let earlier = run(at: 1, context: state())
        #expect(BenchmarkComparison.conditionSummary(earlier, run(at: 2, context: state(thermal: .serious)))
            == "Later run thermal serious at start")
        #expect(BenchmarkComparison.conditionSummary(earlier, run(at: 2, context: state(memory: 2 << 30)))
            == "Later run 2.00 GB memory available")
        var lowPower = state()
        lowPower.lowPowerMode = true
        let later = run(at: 2, context: lowPower)
        #expect(BenchmarkComparison.contextWarnings(earlier, later).map(\.topic) == [.power])
        #expect(BenchmarkComparison.conditionSummary(earlier, later) == "Later run Low Power Mode on")
        #expect(BenchmarkComparison.conditionSummary(run(at: 1), later) == "Earlier run context not recorded")
    }

    @Test func directionDoesNotJudgeLatencyOrHideSpread() throws {
        let earlier = run(.network, at: 1, value: 100, unit: .milliseconds, context: state())
        let later = run(.network, at: 2, value: 130, unit: .milliseconds, context: state(power: .battery))
        guard case let .compared(comparison) = BenchmarkComparison.compare(earlier, later) else {
            Issue.record("Latency runs must compare")
            return
        }
        let change = try #require(comparison.changes.first)
        #expect(change.verdict == .worse)
        #expect(change.verdictTitle == "Higher · conditions differ")
        #expect(change.baselineSpread != nil)
        let export = BenchmarkExport(exported: .now, app: "Test", runs: [earlier, later], comparisons: [(earlier, later)])
        #expect(export.markdown().contains("higher · conditions differ"))
        #expect(try JSONDecoder().decode(BenchmarkChange.self, from: JSONEncoder().encode(change)) == change)
    }

    @Test func oldChangesDecodeWithoutAConditionSummary() throws {
        let change = BenchmarkChange(baseline: run(at: 1).measurements[0], compared: run(at: 2, value: 130).measurements[0])
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(change)) as? [String: Any])
        object.removeValue(forKey: "conditionSummary")
        let decoded = try JSONDecoder().decode(BenchmarkChange.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.conditionSummary == nil)
        #expect(decoded.verdictTitle == "Better")
    }
}
