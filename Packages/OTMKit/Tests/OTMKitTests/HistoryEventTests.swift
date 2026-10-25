import Foundation
@testable import OTMKit
import SQLite3
import Testing

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("otm-events-\(UUID().uuidString)")
        .appendingPathComponent("history.sqlite")
}

private func values(cpu: Double, peak: Double? = nil, memory: Double = 0.5, gpu: Double? = nil, watts: Double? = nil,
                    diskRead: Double = 0, networkIn: Double = 0) -> HistoryValues {
    var values = HistoryValues()
    values.cpu = cpu
    values.cpuPeak = peak ?? cpu
    values.memory = memory
    values.gpu = gpu
    values.systemWatts = watts
    values.diskRead = diskRead
    values.networkIn = networkIn
    return values
}

private func record(at seconds: Double, _ values: HistoryValues, apps: [HistoryApp] = []) -> HistoryRecord {
    HistoryRecord(time: date(seconds), values: values, topCPU: apps)
}

// MARK: - Schema

struct FlightRecorderMigrationTests {
    /// A database as the first History build left it: records and sessions,
    /// `user_version` 0, no events table.
    private func makeVersionZero(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE records (time REAL PRIMARY KEY, cpu REAL, cpu_peak REAL, memory REAL, pressure REAL, swap REAL,
                gpu REAL, system_watts REAL, cpu_watts REAL, gpu_watts REAL, disk_read REAL, disk_write REAL, net_in REAL,
                net_out REAL, chip_celsius REAL, top_cpu TEXT, top_memory TEXT) WITHOUT ROWID;
            CREATE TABLE sessions (id INTEGER PRIMARY KEY, start_time REAL NOT NULL, end_time REAL NOT NULL, note TEXT NOT NULL);
            INSERT INTO records VALUES (1000, 0.25, 0.5, 0.6, 0.2, 0, NULL, NULL, NULL, NULL, 100, 200, 300, 400, NULL,
                '[{"n":"Safari","v":25}]', '[{"n":"Safari","v":1000}]');
            INSERT INTO records VALUES (1010, 0.75, 0.9, 0.6, 0.2, 0, NULL, NULL, NULL, NULL, 100, 200, 300, 400, NULL, '[]', '[]');
            INSERT INTO sessions (start_time, end_time, note) VALUES (990, 1010, 'Before events');
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func bringsAVersionZeroDatabaseUpToDateKeepingItsRecords() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try makeVersionZero(at: url)

        let recorder = try FlightRecorder(url: url)
        #expect(try await recorder.schemaVersionOnDisk() == FlightRecorder.schemaVersion)
        let records = try await recorder.records(from: date(0), to: date(2_000))
        #expect(records.map(\.time) == [date(1_000), date(1_010)])
        #expect(records[0].topCPU == [HistoryApp(name: "Safari", value: 25)])
        #expect(try await recorder.sessions().map(\.note) == ["Before events"])
        // It had none, and now keeps them.
        #expect(try await recorder.events(from: date(0), to: date(2_000)).isEmpty)
        try await recorder.append([HistoryEvent(time: date(1_005), kind: .appLaunched, name: "Xcode")])
        #expect(try await recorder.events(from: date(0), to: date(2_000)).map(\.name) == ["Xcode"])
    }

    @Test func opensAnUpToDateDatabaseAsItIs() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append([HistoryEvent(time: date(500), kind: .wake, name: "")])
        }
        let reopened = try FlightRecorder(url: url)
        #expect(try await reopened.schemaVersionOnDisk() == FlightRecorder.schemaVersion)
        #expect(try await reopened.events(from: date(0), to: date(1_000)).map(\.kind) == [.wake])
    }
}

// MARK: - Events in the recorder and in files

struct FlightRecorderEventTests {
    @Test func savesEventsOnceAndReadsThemInOrder() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let launch = HistoryEvent(time: date(100.25), kind: .appLaunched, name: "Xcode", detail: "com.apple.dt.Xcode")
        let build = HistoryEvent(time: date(90), kind: .processStarted, name: "clang", count: 12, isApproximate: true)
        try await recorder.append([launch, build])
        // Another copy of the app saw the same launch within the same second: it counts once.
        try await recorder.append([HistoryEvent(time: date(100.75), kind: .appLaunched, name: "Xcode")])
        let events = try await recorder.events(from: date(0), to: date(200))
        #expect(events == [build, launch])
        #expect(events[0].count == 12)
        #expect(events[0].isApproximate)
        // Both ends are included.
        #expect(try await recorder.events(from: date(90), to: date(100.25)).count == 2)
        #expect(try await recorder.events(from: date(91), to: date(100)).isEmpty)
    }

    @Test func prunesOldEventsWithTheRecords() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        try await recorder.append([HistoryEvent(time: date(100), kind: .sleep, name: ""),
                                   HistoryEvent(time: date(900), kind: .wake, name: "")])
        try await recorder.prune(before: date(500))
        #expect(try await recorder.events(from: date(0), to: date(1_000)).map(\.kind) == [.wake])
    }

    @Test func exportsAndReplaysTheSessionsEvents() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        for seconds in [10.0, 20, 30, 40] {
            try await recorder.append(record(at: 5_000 + seconds, values(cpu: 0.2)))
        }
        try await recorder.append([HistoryEvent(time: date(5_005), kind: .appLaunched, name: "Before"),
                                   HistoryEvent(time: date(5_025), kind: .networkChanged, name: "Wi-Fi (en0)", detail: "10.0.0.2"),
                                   HistoryEvent(time: date(5_045), kind: .appQuit, name: "After")])
        let session = try await recorder.addSession(from: date(5_010), to: date(5_040))
        let machine = RecordingMachine(modelIdentifier: "Mac", modelName: "Mac", chip: "M", memory: 1, macOSVersion: "27", macOSBuild: "1")
        let file = try await recorder.recording(of: session, machine: machine, generator: "test", exported: .distantPast)
        #expect(file.events.map(\.name) == ["Wi-Fi (en0)"])

        let decoded = try RecordingFile.decode(try file.encoded())
        // The file doesn't keep the session's row ID, only what it covers.
        #expect(decoded.events == file.events)
        #expect(decoded.records == file.records)
        let replay = try FlightRecorder(replaying: decoded, from: URL(fileURLWithPath: "/tmp/never-written.otmrecording"))
        let events = try await replay.events(from: session.start, to: session.end)
        #expect(events.map(\.detail) == ["10.0.0.2"])
    }
}

struct RecordingFileEventTests {
    private let file = RecordingFile(
        session: RecordingSession(start: date(1_000), end: date(1_100)),
        machine: RecordingMachine(modelIdentifier: "Mac", modelName: "Mac", chip: "M", memory: 1, macOSVersion: "27", macOSBuild: "1"),
        generator: "test", exported: date(2_000),
        records: [record(at: 1_010, values(cpu: 0.1)), record(at: 1_020, values(cpu: 0.2))],
        events: [HistoryEvent(time: date(1_015), kind: .processExited, name: "yes", isApproximate: true),
                 HistoryEvent(time: date(1_012), kind: .appLaunched, name: "TextEdit", detail: "com.apple.TextEdit")]
    )

    @Test func roundTripsEventsOldestFirst() throws {
        #expect(file.events.map(\.name) == ["TextEdit", "yes"])
        let decoded = try RecordingFile.decode(try file.encoded())
        #expect(decoded.events == file.events)
        #expect(decoded.events[1].isApproximate)
    }

    @Test func aFileFromBeforeEventsOpensWithNone() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        object.removeValue(forKey: "events")
        let decoded = try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.events.isEmpty)
        #expect(decoded.records == file.records)
    }

    @Test func leavesOutEventsOfKindsItDoesntKnow() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        var events = try #require(object["events"] as? [[String: Any]])
        events[0]["kind"] = "thermalThrottle"
        object["events"] = events
        let decoded = try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.events.map(\.name) == ["yes"])
    }
}

// MARK: - Interval figures and comparison

struct HistoryIntervalStatsTests {
    @Test func leavesGapsOutOfAveragesAndTotals() throws {
        // Three records, then nothing for ten minutes, then one more.
        let records = [
            record(at: 10, values(cpu: 0.2, peak: 0.5, diskRead: 1_000)),
            record(at: 20, values(cpu: 0.4, peak: 0.9, diskRead: 3_000)),
            record(at: 30, values(cpu: 0.6, peak: 0.7, diskRead: 2_000)),
            record(at: 640, values(cpu: 0.8, peak: 0.8, diskRead: 0)),
        ]
        let stats = HistoryIntervalStats(records: records, from: date(0), to: date(660))
        #expect(stats.duration == 660)
        #expect(stats.sampledSeconds == 40)
        #expect(stats.unrecordedSeconds == 620)
        let cpu = try #require(stats.figures[.cpu])
        #expect(abs(cpu.average - 0.5) < 1e-9)
        // CPU's peak is the busiest update; a share has no total.
        #expect(cpu.peak == 0.9)
        #expect(cpu.total == nil)
        let disk = stats.figures[.diskRead]
        // Average over recorded time alone, total over it alone: the gap counts as nothing, not as zero.
        #expect(disk?.average == 1_500)
        #expect(disk?.total == 60_000)
        #expect(disk?.peak == 3_000)
    }

    @Test func countsAStretchTwoCopiesWroteOnce() {
        let records = [
            record(at: 10, values(cpu: 0.2, diskRead: 1_000)),
            record(at: 10.4, values(cpu: 0.4, diskRead: 3_000)),
            record(at: 20, values(cpu: 0.6, diskRead: 2_000)),
        ]
        let stats = HistoryIntervalStats(records: records, from: date(0), to: date(20))
        #expect(stats.sampledSeconds == 20)
        #expect(abs((stats.figures[.cpu]?.average ?? 0) - 0.45) < 1e-9)
        #expect(stats.figures[.diskRead]?.total == 40_000)
    }

    @Test func keepsToTheIntervalAndLeavesOutWhatWasntReported() {
        let records = [
            record(at: 0, values(cpu: 1)),
            record(at: 10, values(cpu: 0.2, watts: 10)),
            record(at: 20, values(cpu: 0.4)),
            record(at: 30, values(cpu: 1)),
        ]
        // The interval holds the records ending after its start, up to its end.
        let stats = HistoryIntervalStats(records: records, from: date(0), to: date(20))
        #expect(abs((stats.figures[.cpu]?.average ?? 0) - 0.3) < 1e-9)
        // Power was reported in one record: averaged over it alone, its energy over its 10 s.
        #expect(stats.figures[.power]?.average == 10)
        #expect(stats.figures[.power]?.total == 100)
        #expect(stats.figures[.gpu] == nil)
        // An interval with nothing recorded has no figures.
        let empty = HistoryIntervalStats(records: records, from: date(100), to: date(200))
        #expect(empty.figures.isEmpty)
        #expect(empty.sampledSeconds == 0)
        #expect(empty.unrecordedSeconds == 100)
    }

    @Test func sampledTimeNeverExceedsTheInterval() {
        let stats = HistoryIntervalStats(records: [record(at: 15, values(cpu: 0.1))], from: date(12), to: date(15))
        #expect(stats.sampledSeconds == 3)
        // Ends given backwards are put in order.
        #expect(HistoryIntervalStats(records: [], from: date(20), to: date(10)).duration == 10)
    }

    @Test func readsTheSameFromTheRecorder() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let records = [10.0, 20, 30, 600].map { record(at: $0, values(cpu: $0 / 1_000, gpu: 0.5, networkIn: $0)) }
        for record in records { try await recorder.append(record) }
        let stats = try await recorder.stats(from: date(0), to: date(700))
        #expect(stats == HistoryIntervalStats(records: records, from: date(0), to: date(700)))
        #expect(stats.sampledSeconds == 40)
    }

    @Test func sumsTheBusiestAppsAsTopAppsDoes() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let records = [
            record(at: 10, values(cpu: 0.5), apps: [HistoryApp(name: "Xcode", value: 80), HistoryApp(name: "Safari", value: 20)]),
            record(at: 20, values(cpu: 0.5), apps: [HistoryApp(name: "Xcode", value: 40)]),
            record(at: 30, values(cpu: 0.5)),
            record(at: 40, values(cpu: 0.5), apps: [HistoryApp(name: "Mail", value: 30)]),
        ]
        for record in records { try await recorder.append(record) }
        let top = try await recorder.topCPU(from: date(0), to: date(30), count: 5)
        let expected = HistoryRecord.topApps(in: Array(records.prefix(3)), count: 5).cpu
        #expect(top.map(\.name) == ["Xcode", "Safari"])
        #expect(top.map(\.name) == expected.map(\.name))
        for (app, reference) in zip(top, expected) {
            #expect(abs(app.value - reference.value) < 1e-9)
        }
        #expect(abs((top.first?.value ?? 0) - 40) < 1e-9)
        #expect(try await recorder.topCPU(from: date(500), to: date(600), count: 5).isEmpty)
    }
}

struct HistoryComparisonTests {
    private func stats(_ records: [HistoryRecord], _ start: Double, _ end: Double) -> HistoryIntervalStats {
        HistoryIntervalStats(records: records, from: date(start), to: date(end))
    }

    @Test func comparesEachFigureSideBySide() throws {
        let a = stats([record(at: 110, values(cpu: 0.6, peak: 0.9, diskRead: 2_000)),
                       record(at: 120, values(cpu: 0.4, peak: 0.5, diskRead: 4_000))], 100, 120)
        let b = stats([record(at: 90, values(cpu: 0.1, peak: 0.2, diskRead: 1_000))], 80, 100)
        let comparison = HistoryComparison(a: a, b: b)
        let cpu = try #require(comparison.rows.first { $0.metric == .cpu && $0.statistic == .average })
        #expect(cpu.a == 0.5)
        #expect(cpu.b == 0.1)
        #expect(abs((cpu.change?.difference ?? 0) - 0.4) < 1e-9)
        #expect(cpu.change?.label(isFraction: true) == "+40 pts")
        let read = try #require(comparison.rows.first { $0.metric == .diskRead && $0.statistic == .total })
        // A moved 60 KB in its 20 s; B 10 KB in the 10 s it recorded.
        #expect(read.a == 60_000)
        #expect(read.b == 10_000)
        #expect(read.change?.ratio == 6)
        // Metrics neither interval has are left out; those one has show nil for the other.
        #expect(!comparison.rows.contains { $0.metric == .gpu })
        #expect(comparison.rows.map(\.id).count == Set(comparison.rows.map(\.id)).count)
        let missing = HistoryComparison(a: a, b: stats([], 0, 10))
        #expect(missing.rows.first { $0.metric == .cpu }?.b == nil)
        #expect(missing.rows.first { $0.metric == .cpu }?.change == nil)
    }

    @Test func pairsAnIntervalWithTheSameLengthBefore() {
        let interval = date(1_000)...date(1_600)
        #expect(HistoryComparison.before(interval) == date(400)...date(1_000))
    }

    @Test func labelsChangesBriefly() {
        typealias Change = HistoryComparison.Change
        #expect(Change(a: 0.25, b: 0.20).label(isFraction: true) == "+5.0 pts")
        #expect(Change(a: 0.10, b: 0.45).label(isFraction: true) == "\u{2212}35 pts")
        #expect(Change(a: 0.5, b: 0.5002).label(isFraction: true) == "no change")
        #expect(Change(a: 2_400, b: 1_000).label(isFraction: false) == "+140%")
        #expect(Change(a: 650, b: 1_000).label(isFraction: false) == "\u{2212}35%")
        #expect(Change(a: 1_050, b: 1_000).label(isFraction: false) == "+5.0%")
        #expect(Change(a: 12_000, b: 1_000).label(isFraction: false) == "×12")
        #expect(Change(a: 5, b: 0).label(isFraction: false) == "from none")
        #expect(Change(a: 0, b: 0).label(isFraction: false) == "no change")
        #expect(Change(a: 0, b: 0).ratio == nil)
    }

    @Test func namesAndFormatsEachFigure() {
        #expect(HistoryMetric.cpu.title(.average) == "CPU average")
        #expect(HistoryMetric.diskRead.title(.total) == "Disk read total")
        #expect(HistoryMetric.power.title(.total) == "Energy")
        #expect(HistoryMetric.networkIn.format(1_000, .peak) == Format.bitsPerSecond(1_000))
        #expect(HistoryMetric.networkIn.format(2_048, .total) == "2.00 KB")
        #expect(HistoryMetric.cpu.format(0.05, .average) == "5.0%")
        #expect(HistoryMetric.cpu.format(0.5, .peak) == "50%")
        #expect(HistoryMetric.power.format(36_000, .total) == "10.0 Wh")
        #expect(HistoryMetric.power.format(1_800, .total) == "500 mWh")
        #expect(HistoryMetric.power.format(7_200_000, .total) == "2.00 kWh")
        #expect(HistoryMetric.memory.statistics == [.average, .peak])
        #expect(HistoryMetric.networkOut.statistics == [.total, .peak])
    }

    @Test func findsTheAppsBusierInA() {
        let a = [HistoryApp(name: "Xcode", value: 80), HistoryApp(name: "Safari", value: 10), HistoryApp(name: "Mail", value: 2.5)]
        let b = [HistoryApp(name: "Safari", value: 30), HistoryApp(name: "Mail", value: 2)]
        let busier = HistoryComparison.busier(a: a, b: b, count: 3)
        // Safari went down and Mail rose by less than a point: only Xcode.
        #expect(busier == [HistoryComparison.AppChange(name: "Xcode", a: 80, b: 0)])
        #expect(HistoryComparison.busier(a: a, b: b, count: 3, threshold: 0.1).map(\.name) == ["Xcode", "Mail"])
        #expect(HistoryComparison.busier(a: a, b: [], count: 1).map(\.name) == ["Xcode"])
    }

    @Test func leadsWithCPUMemoryDiskAndNetwork() throws {
        /// `disk` is read and write, `network` received and sent.
        func sample(_ cpu: Double, _ peak: Double, disk: (Double, Double), network: (Double, Double)) -> HistoryValues {
            var result = values(cpu: cpu, peak: peak, memory: cpu + 0.3, diskRead: disk.0, networkIn: network.0)
            result.diskWrite = disk.1
            result.networkOut = network.1
            return result
        }
        let a = stats([record(at: 110, sample(0.2, 0.6, disk: (1_000, 9_000), network: (100, 0))),
                       record(at: 120, sample(0.4, 0.5, disk: (5_000, 1_000), network: (300, 200)))], 100, 120)
        let b = stats([record(at: 90, sample(0.1, 0.2, disk: (2_000, 2_000), network: (0, 0)))], 80, 100)
        let comparison = HistoryComparison(a: a, b: b)
        #expect(comparison.headlines.map(\.headline) == [.cpu, .memory, .disk, .network])
        let cpu = try #require(comparison.headlines.first)
        #expect(abs((cpu.a?.average ?? 0) - 0.3) < 1e-9)
        #expect(cpu.a?.peak == 0.6)
        #expect(cpu.changeText(.average) == "+20 pts")
        #expect(cpu.changeText(.peak) == "+40 pts")
        #expect(cpu.text(cpu.b, .peak) == "20%")
        // Disk adds read and write in each stretch: 10 KB/s then 6 KB/s, so its
        // peak is the busier stretch's sum, not the two peaks (5 + 9 KB/s) added.
        let disk = try #require(comparison.headlines.first { $0.headline == .disk })
        #expect(disk.a?.average == 8_000)
        #expect(disk.a?.peak == 10_000)
        #expect(disk.b?.average == 4_000)
        #expect(disk.changeText(.average) == "+100%")
        #expect(disk.text(disk.a, .peak) == Format.bytesPerSecond(10_000))
        let network = try #require(comparison.headlines.first { $0.headline == .network })
        #expect(network.a?.peak == 500)
        #expect(network.changeText(.average) == "from none")
        #expect(network.text(network.a, .average) == Format.bitsPerSecond(300))
        // An interval with nothing recorded has no figures to set against.
        let empty = HistoryComparison(a: a, b: stats([], 0, 10))
        #expect(empty.headlines.first?.b == nil)
        #expect(empty.headlines.first?.changeText(.average) == "—")
        #expect(empty.headlines.first.map { $0.text($0.b, .average) } == "—")
        #expect(HistoryHeadline.disk.parts == "read and write")
        #expect(HistoryHeadline.cpu.parts == nil)
        #expect(HistoryHeadline.memory.isFraction)
        #expect(!HistoryHeadline.network.isFraction)
    }

    /// A record every 10 s at these offsets (seconds) after `start`.
    private func recorded(from start: Double, at offsets: some Sequence<Double>) -> [HistoryRecord] {
        offsets.map { record(at: start + $0, values(cpu: 0.2)) }
    }

    /// `minutes` of records every 10 s from `start`, the first 10 s in.
    private func recorded(from start: Double, minutes: Int) -> [HistoryRecord] {
        recorded(from: start, at: stride(from: 10.0, through: Double(minutes * 60), by: 10))
    }

    @Test func notesStepsAndCoverageByOffset() {
        let interval = stats(recorded(from: 1_000, at: [10, 20, 30, 640]), 1_000, 1_660)
        #expect(Array(interval.recordedSteps) == [0, 1, 2, 63])
        #expect(abs(interval.coverage - 40.0 / 660) < 1e-9)
        #expect(stats([], 0, 0).coverage == 0)
        // A record just after the start is in step 0, one at the end in the last step.
        #expect(Array(stats(recorded(from: 0, at: [0.5, 900]), 0, 900).recordedSteps) == [0, 89])
    }

    @Test func saysWhenAComparisonIsLimited() throws {
        // A holds 11 of its 15 minutes, B only 2.
        let a = stats(recorded(from: 900, minutes: 11), 900, 1_800)
        let b = stats(recorded(from: 0, minutes: 2), 0, 900)
        let limited = try #require(HistoryComparison(a: a, b: b).limitation)
        #expect(limited.kind == .low)
        #expect(limited.sides == [.b])
        #expect(limited.title == "Limited comparison")
        #expect(limited.message == "B holds only 2 of its 15 minutes.")
        #expect(HistoryInterval.recorded(a.coverage) == "73% recorded")
        #expect(HistoryInterval.recorded(b.coverage) == "13% recorded")
        // Both thin, one with nothing at all.
        let empty = stats([], 0, 900)
        let both = try #require(HistoryComparison(a: stats(recorded(from: 900, minutes: 3), 900, 1_800), b: empty).limitation)
        #expect(both.sides == [.a, .b])
        #expect(both.message == "A holds only 3 of its 15 minutes, and nothing was recorded in B.")
        #expect(HistoryComparison(a: empty, b: a).limitation?.message == "Nothing was recorded in A.")
    }

    @Test func saysWhenAComparisonIsUneven() throws {
        let whole = stats(recorded(from: 900, minutes: 15), 900, 1_800)
        // 9 of 15 minutes is over half, but under two thirds of A's whole 15.
        let uneven = try #require(HistoryComparison(a: whole, b: stats(recorded(from: 0, minutes: 9), 0, 900)).limitation)
        #expect(uneven.kind == .uneven)
        #expect(uneven.title == "Uneven comparison")
        #expect(uneven.sides == [.b])
        #expect(uneven.message == "B holds 9 of its 15 minutes; A holds 15 of its 15 minutes.")
        let thinA = HistoryComparison(a: stats(recorded(from: 900, minutes: 9), 900, 1_800), b: stats(recorded(from: 0, minutes: 15), 0, 900))
        #expect(thinA.limitation?.sides == [.a])
        // 12 of 15 against 15 of 15 is even enough to stand.
        #expect(HistoryComparison(a: whole, b: stats(recorded(from: 0, minutes: 12), 0, 900)).limitation == nil)
        #expect(HistoryComparison(a: whole, b: whole).limitation == nil)
    }

    @Test func narrowsBothToTheirRecordedOverlap() throws {
        // A holds its first 11 minutes; B only the 2 minutes from 5 min in.
        let a = stats(recorded(from: 1_000, minutes: 11), 1_000, 1_900)
        let b = stats(recorded(from: 100, at: stride(from: 300.0, through: 420, by: 10)), 100, 1_000)
        let overlap = try #require(HistoryComparison(a: a, b: b).recordedOverlap())
        // Steps 29 to 41: from 290 s to 420 s after each start.
        #expect(overlap.a == date(1_290)...date(1_420))
        #expect(overlap.b == date(390)...date(520))
        #expect(overlap.duration == 130)
        // Narrowed, each holds the same 13 records' worth: fully recorded, like for like.
        let narrowedA = stats(recorded(from: 1_000, minutes: 11), 1_290, 1_420)
        let narrowedB = stats(recorded(from: 100, at: stride(from: 300.0, through: 420, by: 10)), 390, 520)
        #expect(narrowedA.coverage == 1)
        #expect(narrowedB.coverage == 1)
        #expect(HistoryComparison(a: narrowedA, b: narrowedB).limitation == nil)
    }

    @Test func aRecordsTimingDoesntBreakTheOverlap() throws {
        // A misses the record at 50 s and B the one at 60 s: neither is a gap.
        let a = stats(recorded(from: 1_000, at: stride(from: 10.0, through: 200, by: 10).filter { $0 != 50 }), 1_000, 1_900)
        let b = stats(recorded(from: 100, at: stride(from: 10.0, through: 200, by: 10).filter { $0 != 60 }), 100, 1_000)
        let overlap = try #require(HistoryComparison(a: a, b: b).recordedOverlap())
        #expect(overlap.a == date(1_000)...date(1_200))
        #expect(HistoryComparison.bridged(IndexSet([0, 1, 2, 4, 5, 8])) == IndexSet([0, 1, 2, 3, 4, 5, 8]))
    }

    @Test func offersNoOverlapTooShortOrNoNarrower() {
        let a = stats(recorded(from: 1_000, minutes: 15), 1_000, 1_900)
        // Under a minute in common.
        let brief = stats(recorded(from: 100, at: stride(from: 10.0, through: 50, by: 10)), 100, 1_000)
        #expect(HistoryComparison(a: a, b: brief).recordedOverlap() == nil)
        // Both whole: narrowing changes nothing.
        #expect(HistoryComparison(a: a, b: stats(recorded(from: 100, minutes: 15), 100, 1_000)).recordedOverlap() == nil)
        // Nothing in common at all.
        let late = stats(recorded(from: 100, at: stride(from: 600.0, through: 900, by: 10)), 100, 1_000)
        let early = stats(recorded(from: 1_000, minutes: 5), 1_000, 1_900)
        #expect(HistoryComparison(a: early, b: late).recordedOverlap() == nil)
    }

    @Test func countsEventsByKind() {
        let a = [HistoryEvent(time: date(1), kind: .appLaunched, name: "X"),
                 HistoryEvent(time: date(2), kind: .processStarted, name: "clang", count: 4)]
        let b = [HistoryEvent(time: date(0), kind: .appLaunched, name: "Y"), HistoryEvent(time: date(0), kind: .wake, name: "")]
        let counts = HistoryComparison.eventCounts(a: a, b: b)
        #expect(counts.map(\.kind) == [.appLaunched, .processStarted, .wake])
        #expect(counts.map(\.a) == [1, 4, 0])
        #expect(counts.map(\.b) == [1, 0, 1])
    }
}

struct HistoryIntervalTests {
    @Test func namesTheStretchAFigureAverages() {
        #expect(HistoryInterval.adjective(10) == "10-second")
        #expect(HistoryInterval.adjective(60) == "1-minute")
        #expect(HistoryInterval.adjective(90) == "90-second")
        #expect(HistoryInterval.adjective(150) == "2.5-minute")
        #expect(HistoryInterval.adjective(240) == "4-minute")
        #expect(HistoryInterval.adjective(1_680) == "28-minute")
        #expect(HistoryInterval.adjective(3_600) == "1-hour")
        #expect(HistoryInterval.adjective(3_610) == "60-minute")
        #expect(HistoryInterval.adjective(0.2) == "1-second")
        #expect(HistoryInterval.adjective(0) == "—")
    }

    @Test func saysHowMuchOfASpanWasSampled() {
        #expect(HistoryInterval.coverage(span: 1_200, sampled: 660) == "20 min span · 11 min sampled")
        #expect(HistoryInterval.coverage(span: 600, sampled: 900) == "10 min span · 10 min sampled")
    }

    @Test func saysHowMuchOfAnIntervalWasRecorded() {
        #expect(HistoryInterval.recorded(0.7333) == "73% recorded")
        #expect(HistoryInterval.recorded(1) == "100% recorded")
        #expect(HistoryInterval.recorded(0.003) == "under 1% recorded")
        #expect(HistoryInterval.recorded(0) == "nothing recorded")
        #expect(HistoryInterval.recorded(.nan) == "nothing recorded")
    }

    @Test func givesTheRecordedPartInTheIntervalsUnit() {
        #expect(HistoryInterval.share(sampled: 120, span: 900) == "2 of its 15 minutes")
        #expect(HistoryInterval.share(sampled: 660, span: 900) == "11 of its 15 minutes")
        #expect(HistoryInterval.share(sampled: 0, span: 900) == "0 of its 15 minutes")
        // Under one of the interval's unit, in the next one down.
        #expect(HistoryInterval.share(sampled: 20, span: 900) == "20 seconds of its 15 minutes")
        #expect(HistoryInterval.share(sampled: 60, span: 7_200) == "1 minute of its 2 hours")
        #expect(HistoryInterval.share(sampled: 1_200, span: 21_600) == "20 minutes of its 6 hours")
        #expect(HistoryInterval.share(sampled: 10_800, span: 21_600) == "3 of its 6 hours")
        // The largest unit the interval holds two of: 90 minutes stay minutes, a minute is seconds.
        #expect(HistoryInterval.share(sampled: 5_400, span: 5_400) == "90 of its 90 minutes")
        #expect(HistoryInterval.share(sampled: 40, span: 60) == "40 of its 60 seconds")
        #expect(HistoryInterval.share(sampled: 172_800, span: 604_800) == "2 of its 7 days")
        // Never more than the whole.
        #expect(HistoryInterval.share(sampled: 1_000, span: 900) == "15 of its 15 minutes")
    }

    @Test func saysWhatAnIntervalLeavesOut() {
        #expect(HistoryInterval.leftOut(span: 1_200, sampled: 660) == "9 min of gaps left out")
        #expect(HistoryInterval.leftOut(span: 1_200, sampled: 20) == "20 min of gaps left out")
        // A record's timing isn't a gap: the graphs don't break under 2.5 records either.
        #expect(HistoryInterval.leftOut(span: 900, sampled: 880) == "no gaps")
        #expect(HistoryInterval.leftOut(span: 900, sampled: 870) == "30 s of gaps left out")
        #expect(HistoryInterval.leftOut(span: 600, sampled: 900) == "no gaps")
        #expect(HistoryInterval.leftOut(span: 600, sampled: 0) == "nothing recorded")
    }
}

struct HistoryCompareRequestTests {
    @Test func readsAAndOptionallyB() throws {
        let end = date(10_000)
        let request = try #require(HistoryCompareRequest("15,15"))
        #expect(request.a.range(before: end) == date(9_100)...end)
        #expect(request.b == nil)
        let both = try #require(HistoryCompareRequest(" 30, 10 ,60,20"))
        #expect(both.a.range(before: end) == date(8_200)...date(8_800))
        #expect(both.b?.range(before: end) == date(6_400)...date(7_600))
        // A length past the end is cut off there.
        #expect(HistoryCompareRequest("5,20")?.a.range(before: end) == date(9_700)...end)
        #expect(HistoryCompareRequest("0.5,0.5")?.a.range(before: end) == date(9_970)...end)
    }

    @Test func refusesAnythingElse() {
        for text in ["", "15", "15,15,30", "15,0", "-5,5", "a,b", "15,15,45,x", "15,15,45,15,1", "nan,5"] {
            #expect(HistoryCompareRequest(text) == nil, "\(text)")
        }
    }
}

// MARK: - Events

struct HistoryEventTests {
    private let events = [10.0, 12, 30, 31, 32, 90].map { HistoryEvent(time: date($0), kind: .appLaunched, name: "App \(Int($0))") }

    @Test func findsTheEventsNearAMoment() {
        #expect(HistoryEvent.near(date(30), in: events, before: 5, after: 2).map(\.time) == [date(30), date(31), date(32)])
        #expect(HistoryEvent.near(date(20), in: events, before: 10, after: 0).map(\.time) == [date(10), date(12)])
        #expect(HistoryEvent.near(date(60), in: events, before: 5, after: 5).isEmpty)
        #expect(HistoryEvent.near(date(60), in: [], before: 5, after: 5).isEmpty)
    }

    @Test func foldsRepeatsTogether() {
        let repeats = [
            HistoryEvent(time: date(0), kind: .processStarted, name: "clang"),
            HistoryEvent(time: date(3), kind: .processStarted, name: "ld", isApproximate: true),
            HistoryEvent(time: date(4), kind: .processStarted, name: "clang", count: 2, isApproximate: true),
            HistoryEvent(time: date(5), kind: .processExited, name: "clang"),
            HistoryEvent(time: date(12), kind: .processStarted, name: "clang"),
        ]
        let merged = HistoryEvent.merged(repeats, within: 10)
        #expect(merged.map(\.name) == ["clang", "ld", "clang", "clang"])
        #expect(merged[0].count == 3)
        #expect(merged[0].isApproximate)
        #expect(merged[0].time == date(0))
        // Past the window, a new group; another kind never folds in.
        #expect(merged[2].kind == .processExited)
        #expect(merged[3].time == date(12))
        #expect(HistoryEvent(time: date(0), kind: .wake, name: "", count: 0).count == 1)
    }

    @Test func clustersEventsTooCloseToDrawApart() {
        let clusters = HistoryEvent.clusters(events, spacing: 2)
        #expect(clusters.map(\.count) == [2, 3, 1])
        #expect(HistoryEvent.clusters([], spacing: 2).isEmpty)
    }

    @Test func findsThePointWhoseStretchHoldsAMoment() {
        let points = [10.0, 20, 30, 300].map { HistoryPoint(time: date($0), values: HistoryValues()) }
        #expect(HistoryPoint.covering(date(15), in: points, bucket: 10)?.time == date(20))
        #expect(HistoryPoint.covering(date(20), in: points, bucket: 10)?.time == date(20))
        // In a gap, the nearest point.
        #expect(HistoryPoint.covering(date(100), in: points, bucket: 10)?.time == date(30))
        #expect(HistoryPoint.covering(date(500), in: points, bucket: 10)?.time == date(300))
        #expect(HistoryPoint.covering(date(5), in: [], bucket: 10) == nil)
    }
}

struct ProcessEventTrackerTests {
    private func process(_ pid: Int32, _ name: String, cpu: Double, started: Double? = nil) -> ProcessSample {
        ProcessSample(
            pid: pid, parentPID: 1, responsiblePID: pid, uid: 501, userName: "me", name: name, executablePath: nil,
            state: .running, nice: 0, startTime: started.map(date), isTranslated: false, isRestricted: false,
            cpuPercent: cpu, cpuTime: 0, memory: 0, residentMemory: 0, threadCount: 1,
            diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0
        )
    }

    /// Feeds one update per second from `start`, returning every event that came due.
    private func run(_ tracker: inout ProcessEventTracker, from start: Double, _ updates: [[ProcessSample]]) -> [HistoryEvent] {
        updates.enumerated().flatMap { offset, processes in
            tracker.update(processes, skipping: [], at: date(start + Double(offset)))
        }
    }

    @Test func busyProcessesAlreadyRunningAreNotStarts() {
        var tracker = ProcessEventTracker()
        let busy = [process(10, "backupd", cpu: 90, started: 0)]
        #expect(run(&tracker, from: 100, Array(repeating: busy, count: 15)).isEmpty)
        #expect(tracker.flush().isEmpty)
    }

    @Test func aBusyNewProcessStartsAtItsOwnStartTime() {
        var tracker = ProcessEventTracker()
        let quiet = [process(10, "launchd-ish", cpu: 0)]
        let busy = quiet + [process(20, "yes", cpu: 100, started: 101.5)]
        // Seen at 102, busy straight away; held back until its window has passed.
        let events = run(&tracker, from: 100, [quiet, quiet] + Array(repeating: busy, count: 12))
        #expect(events == [HistoryEvent(time: date(101.5), kind: .processStarted, name: "yes")])
    }

    @Test func withoutAStartTimeItsStartIsApproximate() {
        var tracker = ProcessEventTracker()
        let idle = [process(30, "helper", cpu: 1)]
        let busy = [process(30, "helper", cpu: 60)]
        // New at 101, idle at first: it starts counting once busy, at when it was first seen.
        let events = run(&tracker, from: 100, [[], idle, idle, busy, busy] + Array(repeating: busy, count: 10))
        #expect(events == [HistoryEvent(time: date(101), kind: .processStarted, name: "helper", isApproximate: true)])
    }

    @Test func aBusyProcessThatGoesExitsBetweenUpdates() {
        var tracker = ProcessEventTracker()
        let busy = [process(10, "backupd", cpu: 90, started: 0)]
        var events = run(&tracker, from: 100, [busy, busy, []])
        #expect(events.isEmpty)
        events = tracker.flush()
        #expect(events == [HistoryEvent(time: date(101.5), kind: .processExited, name: "backupd", isApproximate: true)])
        // An idle one's exit isn't news.
        var quiet = ProcessEventTracker()
        _ = run(&quiet, from: 100, [[process(11, "idle", cpu: 1)], []])
        #expect(quiet.flush().isEmpty)
    }

    @Test func foldsAWaveOfOneNameIntoOneEvent() {
        var tracker = ProcessEventTracker()
        let wave = (0..<5).map { [process(Int32(40 + $0), "clang", cpu: 100, started: 100.5 + Double($0))] }
        let events = run(&tracker, from: 100, [[]] + wave + Array(repeating: [], count: 15))
        let starts = events.filter { $0.kind == .processStarted }
        #expect(starts.count == 1)
        #expect(starts.first?.count == 5)
        #expect(starts.first?.time == date(100.5))
        #expect(events.filter { $0.kind == .processExited }.first?.count == 5)
    }

    @Test func aRecycledPIDIsAnotherProcess() {
        var tracker = ProcessEventTracker()
        let first = [process(50, "old", cpu: 0, started: 10)]
        let second = [process(50, "new", cpu: 80, started: 100.5)]
        let events = run(&tracker, from: 100, [first, second] + Array(repeating: second, count: 11))
        #expect(events.map(\.name) == ["new"])
    }

    @Test func startsAfreshAfterAPause() {
        var tracker = ProcessEventTracker()
        let busy = [process(10, "backupd", cpu: 90, started: 0)]
        _ = run(&tracker, from: 100, [busy, busy])
        // Updates stopped for a minute (the Mac slept): what went meanwhile
        // can't be placed, and what was running is the new baseline, apart
        // from a process that says it started during the pause.
        let after = [process(11, "mds", cpu: 50, started: 50), process(12, "softwareupdated", cpu: 70, started: 130)]
        let events = run(&tracker, from: 161, Array(repeating: after, count: 12)) + tracker.flush()
        #expect(events == [HistoryEvent(time: date(130), kind: .processStarted, name: "softwareupdated")])
    }

    @Test func leavesOutApps() {
        var tracker = ProcessEventTracker()
        let app = [process(60, "Xcode", cpu: 300, started: 100.5)]
        var events: [HistoryEvent] = []
        for second in 0..<15 {
            events += tracker.update(second == 0 ? [] : app, skipping: [60], at: date(100 + Double(second)))
        }
        #expect(events.isEmpty)
        #expect(tracker.flush().isEmpty)
    }

    @Test func aProcessThatTurnsOutToBeAnAppDoesNotExit() {
        var tracker = ProcessEventTracker()
        let helper = [process(70, "Preview", cpu: 80, started: 0)]
        var events: [HistoryEvent] = []
        for second in 0..<15 {
            // Busy before NSWorkspace counts it as an app, then one from the third update on.
            events += tracker.update(helper, skipping: second < 2 ? [] : [70], at: date(100 + Double(second)))
        }
        #expect(events.isEmpty)
        #expect(tracker.flush().isEmpty)
    }
}

struct NetworkInUseTests {
    private let store: [String: Any] = [
        "State:/Network/Global/IPv4": ["PrimaryService": "ABC", "PrimaryInterface": "en0"],
        "Setup:/Network/Service/ABC": ["UserDefinedName": "Wi-Fi"],
        "State:/Network/Service/ABC/IPv4": ["Addresses": ["192.168.1.20"]],
        "State:/Network/Service/ABC/IPv6": ["Addresses": ["fe80::1"]],
    ]

    @Test func readsThePrimaryNetworkFromTheStore() {
        let network = NetworkInUse(store: store)
        #expect(network == NetworkInUse(interface: "en0", service: "Wi-Fi", address: "192.168.1.20"))
        #expect(network.label == "Wi-Fi (en0)")
    }

    @Test func fallsBackToIPv6AndTheInterfacesName() {
        let store: [String: Any] = [
            "State:/Network/Global/IPv6": ["PrimaryService": "DEF", "PrimaryInterface": "en7"],
            "Setup:/Network/Service/DEF/Interface": ["UserDefinedName": "USB 10/100/1000 LAN"],
            "State:/Network/Service/DEF/IPv6": ["Addresses": ["2001:db8::5"]],
        ]
        let network = NetworkInUse(store: store)
        #expect(network.label == "USB 10/100/1000 LAN (en7)")
        #expect(network.address == "2001:db8::5")
        #expect(NetworkInUse(interface: "en0", service: "en0", address: nil).label == "en0")
    }

    @Test func noPrimaryNetworkIsNone() {
        let none = NetworkInUse(store: [:])
        #expect(none == NetworkInUse(interface: nil, service: nil, address: nil))
        #expect(none.label.isEmpty)
    }

    @Test func aChangeIsAnEventAndNoChangeIsNone() {
        let wifi = NetworkInUse(store: store)
        let none = NetworkInUse(store: [:])
        #expect(wifi.event(from: wifi, at: date(5)) == nil)
        #expect(none.event(from: wifi, at: date(5)) == HistoryEvent(time: date(5), kind: .networkChanged, name: ""))
        #expect(wifi.event(from: none, at: date(9))
            == HistoryEvent(time: date(9), kind: .networkChanged, name: "Wi-Fi (en0)", detail: "192.168.1.20"))
    }
}

struct OpeningFocusTests {
    @Test func takesTheFocusOnlyFromAControlOnThePageBeforeTheUserActs() {
        #expect(OpeningFocus.clears(.control, onPage: true, userActed: false))
        #expect(!OpeningFocus.clears(.control, onPage: true, userActed: true))
        #expect(!OpeningFocus.clears(.control, onPage: false, userActed: false))
        #expect(!OpeningFocus.clears(.text, onPage: true, userActed: false))
        #expect(!OpeningFocus.clears(.other, onPage: true, userActed: false))
        #expect(!OpeningFocus.clears(.nothing, onPage: true, userActed: false))
    }

    @Test func keepsLookingWhileAControlMayStillGetTheFocus() {
        #expect(!OpeningFocus.isSettled(.nothing, userActed: false))
        #expect(!OpeningFocus.isSettled(.control, userActed: false))
        #expect(OpeningFocus.isSettled(.text, userActed: false))
        #expect(OpeningFocus.isSettled(.other, userActed: false))
        #expect(OpeningFocus.isSettled(.nothing, userActed: true))
    }
}
