import Foundation
import Testing
@testable import OTMKit

struct BenchmarkSessionTests {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    private func reading(_ seconds: Double, busy: Double = 0.03, power: BenchmarkPowerSource = .ac,
                         thermal: ThermalState = .nominal, pressure: MemoryPressure = .normal) -> BenchmarkPreflightReading {
        BenchmarkPreflightReading(date: epoch.addingTimeInterval(seconds), interval: 1, cpuBusy: busy,
                                  memoryPressure: pressure, thermal: thermal, power: power, lowPowerMode: false)
    }

    private func quietPreflight() -> BenchmarkPreflight {
        var watch = BenchmarkSettling(started: epoch)
        for second in 1...30 { watch.append(reading(Double(second))) }
        return watch.snapshot(now: epoch.addingTimeInterval(30))
    }

    private func run(_ index: Int, group: String = "one", value: Double = 100) -> BenchmarkRun {
        var run = BenchmarkRun(id: "\(group)-\(index)", kind: .cpu, date: epoch.addingTimeInterval(Double(index)), workloadVersion: 1,
            settings: [], build: nil, machine: nil, target: nil, osVersion: nil, conditions: [],
            measurements: [BenchmarkMeasurement(id: "speed", name: "Speed", value: value, unit: .bytesPerSecond,
                                                low: value - 1, high: value + 1, repeats: 3)])
        run.session = BenchmarkSession(id: group, preflight: quietPreflight(), repeatIndex: index)
        return run
    }

    @Test func requiresTheWholeQuietWindow() {
        var watch = BenchmarkSettling(started: epoch)
        for second in 1...29 { watch.append(reading(Double(second))) }
        #expect(!watch.snapshot(now: epoch.addingTimeInterval(29)).settled)
        watch.append(reading(30))
        let preflight = watch.snapshot(now: epoch.addingTimeInterval(30))
        #expect(preflight.settled)
        #expect(preflight.verdict == "Quiet window reached")
        #expect(preflight.rows.first?.text == "CPU load 3% over the last 30 s · quiet")
    }

    @Test func busyHeatAndMemoryEachPreventSettling() {
        for bad in [reading(15, busy: 0.4), reading(15, thermal: .fair), reading(15, pressure: .warning)] {
            var watch = BenchmarkSettling(started: epoch)
            for second in 1...30 { watch.append(second == 15 ? bad : reading(Double(second))) }
            #expect(!watch.snapshot(now: epoch.addingTimeInterval(30)).settled)
            for second in 31...45 { watch.append(reading(Double(second))) }
            #expect(watch.snapshot(now: epoch.addingTimeInterval(45)).settled)
        }
    }

    @Test func staleDuplicateMissingAndPausedReadingsNeverInventQuietTime() {
        var watch = BenchmarkSettling(started: epoch)
        for second in 1...30 where second != 15 { watch.append(reading(Double(second))) }
        for _ in 0..<50 { watch.append(reading(30)) }
        #expect(watch.readings.count == 29)
        #expect(!watch.snapshot(now: epoch.addingTimeInterval(30)).settled)
        #expect(!watch.snapshot(now: epoch.addingTimeInterval(60)).settled)
        var unknown = reading(31)
        unknown.cpuBusy = nil
        watch.append(unknown)
        #expect(!watch.snapshot(now: epoch.addingTimeInterval(31)).settled)
        #expect(!BenchmarkSettling(started: epoch).snapshot(now: epoch.addingTimeInterval(120)).settled)
    }

    @Test func powerChangesRestartTheWindowButBatteryIsAnAdvisory() {
        var watch = BenchmarkSettling(started: epoch)
        for second in 1...30 { watch.append(reading(Double(second), power: .battery)) }
        let battery = watch.snapshot(now: epoch.addingTimeInterval(30))
        #expect(battery.settled)
        #expect(battery.rows.contains { $0.text == "On battery · results may be lower than on power" })
        #expect(battery.verdict.contains("review"))
        watch.append(reading(31))
        #expect(!watch.snapshot(now: epoch.addingTimeInterval(31)).settled)
    }

    @Test func windowsAndWaitsAreBounded() {
        #expect(BenchmarkSettling(started: epoch, window: 999).window == 120)
        #expect(BenchmarkSettling(started: epoch, window: .nan).window == 30)
        let snapshot = BenchmarkSettling(started: epoch).snapshot(now: epoch.addingTimeInterval(999))
        #expect(snapshot.elapsed == 120)
        #expect(snapshot.verdict.hasPrefix("Wait limit reached"))
        #expect(!reading(1, busy: .nan).quiet)
        #expect(!reading(1, busy: -1).quiet)
        var afterSleep = reading(60)
        afterSleep.interval = 60
        var watch = BenchmarkSettling(started: epoch)
        watch.append(afterSleep)
        #expect(!watch.snapshot(now: afterSleep.date).settled)
        #expect(!afterSleep.quiet)
    }

    @Test func groupingUsesMediansAndBothLevelsOfSpread() throws {
        let repeats = [run(1, value: 100), run(2, value: 110), run(3, value: 105)]
        let grouped = BenchmarkRun.groupedSessions(repeats)
        let entry = try #require(grouped.first)
        #expect(grouped.count == 1)
        #expect(entry.session?.recordedRepeats == 3)
        #expect(entry.measurements.first?.value == 105)
        #expect(entry.measurements.first?.low == 99)
        #expect(entry.measurements.first?.high == 111)
        #expect(entry.measurements.first?.repeats == 3)
        #expect(BenchmarkRun.groupedSessions(grouped) == grouped)
        #expect(BenchmarkTrend(runs: repeats).dates.count == 1)
        let other = try #require(BenchmarkRun.groupedSessions([run(1, group: "two", value: 130), run(2, group: "two", value: 135),
                                                             run(3, group: "two", value: 132)]).first)
        if case let .compared(comparison) = BenchmarkComparison.compare(entry, other) {
            #expect(comparison.changes.first?.verdict == .better)
            #expect(comparison.changes.first?.baselineSpread == (111.0 - 99) / 105)
        } else { Issue.record("Complete sessions should compare") }
    }

    @Test func protocolVersionsAndOrdinaryRunsDoNotMix() {
        let one = run(1)
        var future = run(1, group: "future")
        future.session?.protocolVersion += 1
        #expect(BenchmarkComparison.refusal(one, future) == .differentSessions)
        var ordinary = run(2)
        ordinary.session = nil
        #expect(BenchmarkComparison.refusal(one, ordinary) == .differentSessions)
        #expect(BenchmarkSessionProtocol.kinds("all") == [.cpu, .gpu])
        #expect(BenchmarkSessionProtocol.kinds("disk") == nil)
        #expect(BenchmarkSessionProtocol.repeats == 3)
    }

    @Test func partialSessionsAndIncompatibleRepeatsAreVisible() throws {
        let partial = try #require(BenchmarkRun.groupedSessions([run(1)]).first)
        #expect(partial.conditions.contains { $0.contains("incomplete") })
        #expect(partial.sessionSummary.contains("1 of 3 measured repeats"))
        #expect(partial.measurements.first?.repeats == nil)
        var other = run(2)
        other.settings = [BenchmarkSetting(name: "Workers", value: "2")]
        #expect(BenchmarkRun.groupedSessions([run(1), other]).count == 2)
    }

    @Test func olderRunsDecodeWithNoSessionAndFutureBlocksKeepTheRun() throws {
        let encoder = JSONEncoder()
        var old = run(1)
        old.session = nil
        let data = try encoder.encode(old)
        let decoded = try JSONDecoder().decode(BenchmarkRun.self, from: data)
        #expect(decoded.session == nil)
        #expect(decoded.sessionSummary == "Not part of a session")
        let block = try JSONDecoder().decode(BenchmarkSession.self, from: Data(#"{"version":99,"id":"future"}"#.utf8))
        #expect(!block.supported)
        #expect(block.id == "future")
        let damaged = try JSONDecoder().decode(BenchmarkSession.self, from: Data(#""bad block""#.utf8))
        #expect(!damaged.supported)
        var recorded = run(1)
        recorded.session = block
        #expect(try JSONDecoder().decode(BenchmarkRun.self, from: encoder.encode(recorded)).session == block)
    }

    @Test func preflightDifferencesArePlainWarnings() {
        let one = run(1)
        var other = run(2, group: "two")
        other.session?.preflight?.readings[29].power = .battery
        let warnings = BenchmarkComparison.sessionWarnings(one, other)
        #expect(warnings.contains { $0.text == "Session A started on power; B on battery." })
        #expect(BenchmarkComparison.conditionSummary(one, other)?.contains("on battery") == true)
    }
}

struct BenchmarkSessionHistoryTests {
    private func result(_ index: Int, session: String? = nil) -> NetworkQualityResult {
        var result = NetworkQualityResult(date: Date(timeIntervalSince1970: Double(index)), requestedInterface: "en0", interface: "en0",
            downloadBitsPerSecond: 100, uploadBitsPerSecond: 50, responsiveness: 200)
        if let session {
            result.session = BenchmarkSession(id: session, preflight: nil, repeatIndex: (index - 1) % 3 + 1)
        }
        return result
    }

    @Test func historyKeepsWholeSessionsWithinItsEntryLimit() {
        let records = (1...9).map { result($0, session: "group-\(($0 - 1) / 3)") }
        let kept = SpeedTestHistory<NetworkQualityResult>.pruned(records, perKey: 2, keys: 1)
        #expect(kept.count == 6)
        #expect(Set(kept.compactMap { $0.session?.id }) == ["group-1", "group-2"])
        #expect(BenchmarkRun.groupedSessions(kept.map(BenchmarkRun.init)).count == 2)
        #expect(SpeedTestHistory<NetworkQualityResult>.pruned(records + [records[8]], perKey: 2, keys: 1).count == 6)
        let mixed = SpeedTestHistory<NetworkQualityResult>.pruned([result(10)] + records, perKey: 2, keys: 1)
        #expect(mixed.count == 4)
        #expect(mixed.first?.session == nil)
    }

    @Test func oldHistoryReadsWithoutRewritingAndSessionBlocksRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-guided-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("network-quality.json")
        let oldEntry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result(1)))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "results": [oldEntry]])
        try data.write(to: file)
        let history = SpeedTestHistory<NetworkQualityResult>(file: file)
        #expect(history.load().first?.session == nil)
        #expect(try Data(contentsOf: file) == data)
        var measured = result(2, session: "new")
        measured.session?.preflight = BenchmarkSettling(started: measured.date).snapshot(now: measured.date)
        let decoded = try JSONDecoder().decode(NetworkQualityResult.self, from: JSONEncoder().encode(measured))
        #expect(decoded.session == measured.session)
        #expect(BenchmarkRun(decoded).session == measured.session)
    }

    @Test func configurableRepeatsKeepOneDiscardedWarmupAndMatchForComparison() {
        #expect(Array(BenchmarkSessionProtocol.passes()) == [0, 1, 2, 3])
        #expect(Array(BenchmarkSessionProtocol.passes(repeatCount: 1)) == [0, 1])
        #expect(BenchmarkSessionProtocol.passes(repeatCount: 999).upperBound == 10)
        var one = BenchmarkRun(result(1, session: "one"))
        let other = BenchmarkRun(result(2, session: "two"))
        one.session?.repeatCount = 2
        #expect(one.session?.supported == true)
        #expect(BenchmarkComparison.refusal(one, other) == .differentSessions)
    }

    @Test func slowAndFastCadencesUseCoveredTimeAndTolerateDeliveryDelay() {
        let start = Date(timeIntervalSince1970: 0)
        for interval in [0.25, 1, 5] {
            var watch = BenchmarkSettling(started: start)
            for index in 1...Int(30 / interval) {
                watch.append(BenchmarkPreflightReading(date: start.addingTimeInterval(Double(index) * interval), interval: interval,
                    cpuBusy: 0.03, memoryPressure: .normal, thermal: .nominal, power: .ac, lowPowerMode: false))
            }
            #expect(watch.snapshot(now: start.addingTimeInterval(30.1)).settled)
            #expect(!watch.snapshot(now: start.addingTimeInterval(60)).settled)
        }
    }
}
