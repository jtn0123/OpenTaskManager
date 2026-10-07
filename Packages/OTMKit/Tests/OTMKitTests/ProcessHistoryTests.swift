import Foundation
@testable import OTMKit
import SQLite3
import Testing

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("otm-processes-\(UUID().uuidString)")
        .appendingPathComponent("history.sqlite")
}

private func identity(_ pid: Int32, _ start: Double?) -> ProcessIdentity {
    ProcessIdentity(pid: pid, startTime: start.map(date))
}

/// A process at one tick, with cumulative counters and the tick's rates.
private func process(_ pid: Int32, start: Double? = 500, name: String? = nil, cpuTime: Double = 0, cpuPercent: Double = 0,
                     memory: UInt64 = 1 << 20, read: UInt64 = 0, readRate: Double = 0, restricted: Bool = false) -> ProcessSample {
    ProcessSample(
        pid: pid, parentPID: 1, responsiblePID: pid, uid: restricted ? 0 : 501, userName: restricted ? "root" : "me",
        name: name ?? "p\(pid)", executablePath: "/usr/bin/p\(pid)", state: .running, nice: 0, startTime: start.map(date),
        isTranslated: false, isRestricted: restricted, cpuPercent: cpuPercent, cpuTime: cpuTime, memory: memory,
        residentMemory: memory, threadCount: 1, diskReadRate: restricted ? 0 : readRate, diskWriteRate: 0,
        diskReadTotal: restricted ? 0 : read, diskWriteTotal: 0
    )
}

private func sample(_ pid: Int32, cpu: Double = 0, memory: UInt64 = 0, disk: Double? = 0) -> ProcessHistorySample {
    ProcessHistorySample(identity: identity(pid, 500), cpuPercent: cpu, memory: memory, diskRead: disk, diskWrite: disk.map { _ in 0 })
}

private func record(at seconds: Double) -> HistoryRecord {
    var values = HistoryValues()
    values.cpu = 0.1
    return HistoryRecord(time: date(seconds), values: values)
}

private func start(_ pid: Int32, _ startTime: Double?, name: String, path: String? = nil, at seen: Double,
                   restricted: Bool = false) -> ProcessHistoryBatch.Start {
    ProcessHistoryBatch.Start(identity: identity(pid, startTime), name: name, path: path, user: restricted ? "root" : "me",
                              isRestricted: restricted, firstSeen: date(seen))
}

private func kept(_ pid: Int32, _ startTime: Double?, cpu: Double, memory: UInt64 = 1 << 20,
                  disk: Double? = 0) -> ProcessHistorySample {
    ProcessHistorySample(identity: identity(pid, startTime), cpuPercent: cpu, memory: memory, diskRead: disk, diskWrite: disk)
}

// MARK: - Which processes a record keeps

struct ProcessHistoryKeepTests {
    @Test func keepsTheLargestTheBusyAndTheDiskUsersAndLeavesTheIdleOut() {
        var samples = (1...6).map { sample(Int32($0), memory: UInt64($0) << 30) }
        samples.append(sample(20, cpu: 0.4, memory: 1 << 20))
        samples.append(sample(21, cpu: 0.5, memory: 1 << 20))
        samples.append(sample(22, cpu: 12, memory: 1 << 20))
        samples.append(sample(23, cpu: 0, memory: 1 << 20, disk: 70_000))
        samples.append(sample(24, cpu: 0, memory: 1 << 20, disk: 60_000))
        let picked = ProcessHistoryKeep.select(samples).map(\.identity.pid)
        // The five largest (whatever their CPU), the disk user, then CPU at or over half a percent of a core, busiest first.
        #expect(picked == [6, 5, 4, 3, 2, 23, 22, 21])
        #expect(!picked.contains(1), "the sixth largest is idle")
        #expect(!picked.contains(20) && !picked.contains(24), "under both floors")
    }

    @Test func capsARecordAndRanksTheBusiestFirst() {
        var samples = (1...5).map { sample(Int32($0), memory: 8 << 30) }
        samples += (100..<160).map { sample(Int32($0), cpu: Double($0), memory: 1 << 20) }
        samples += (200..<215).map { sample(Int32($0), memory: 1 << 20, disk: Double($0) * 1_000) }
        let picked = ProcessHistoryKeep.select(samples)
        #expect(picked.count == ProcessHistoryKeep.cap)
        #expect(picked.prefix(5).map(\.identity.pid) == [1, 2, 3, 4, 5])
        // Ten disk users, busiest first, then the busiest CPU users fill the rest.
        #expect(picked.dropFirst(5).prefix(10).map(\.identity.pid) == Array((205..<215).reversed()))
        #expect(picked.suffix(25).map(\.identity.pid) == Array((135..<160).reversed()))
    }

    @Test func picksTheSameWhateverTheOrder() {
        let samples = (1...30).map { sample(Int32($0), cpu: Double($0 % 4), memory: UInt64($0 % 3) << 20) }
        #expect(ProcessHistoryKeep.select(samples) == ProcessHistoryKeep.select(samples.reversed()))
    }
}

// MARK: - Following processes between records

struct ProcessHistoryTrackerTests {
    /// A at 50% of a core reading 100 KB/s; five large idle processes; B small and idle.
    private func processes(at tick: Double, extra: [ProcessSample] = []) -> [ProcessSample] {
        var list = [process(10, cpuTime: 100 + 0.5 * tick, cpuPercent: 50, read: 1_000_000 + UInt64(102_400 * tick), readRate: 102_400)]
        list += (30..<35).map { process(Int32($0), cpuTime: 5, memory: 1 << 30) }
        list.append(process(11, cpuTime: 2, memory: 1 << 10))
        return list + extra
    }

    @Test func averagesCPUAndDiskOverTheRecordFromTheCounters() throws {
        var tracker = ProcessHistoryTracker(span: 10)
        var previous: [ProcessSample] = []
        for tick in 1...10 {
            let now = processes(at: Double(tick))
            let appeared = now.filter { process in !previous.contains { $0.identity == process.identity } }
            tracker.add(now, appeared: appeared, disappeared: [], watchesRestricted: true, interval: 1, at: date(1_000 + Double(tick)))
            previous = now
        }
        let batch = tracker.close(at: date(1_010), samples: previous)
        #expect(batch.started.count == 7, "every process seen gets a lifetime")
        #expect(batch.started.allSatisfy { $0.firstSeen == date(1_001) })
        let busy = try #require(batch.samples.first { $0.identity.pid == 10 })
        #expect(abs(busy.cpuPercent - 50) < 1e-9)
        #expect(abs((busy.diskRead ?? 0) - 102_400) < 1e-6)
        #expect(!batch.samples.contains { $0.identity.pid == 11 }, "small and idle: not stored")
    }

    @Test func countsAProcessThatStartsOrEndsWithinTheRecord() {
        var tracker = ProcessHistoryTracker(span: 10)
        // D runs at 20% until it ends after tick 6; C starts half a second before tick 5 at 30%, then 10%.
        func dying(_ tick: Double) -> ProcessSample { process(12, cpuTime: 10 + 0.2 * tick, cpuPercent: 20) }
        func newborn(_ tick: Double) -> ProcessSample {
            process(13, start: 1_004.5, cpuTime: 0.3 + 0.1 * (tick - 5), cpuPercent: tick > 5 ? 10 : 0)
        }
        var previous: [ProcessSample] = []
        for tick in 1...10 {
            let value = Double(tick)
            var extra: [ProcessSample] = []
            if tick <= 6 { extra.append(dying(value)) }
            if tick >= 5 { extra.append(newborn(value)) }
            let now = processes(at: value, extra: extra)
            let appeared = now.filter { process in !previous.contains { $0.identity == process.identity } }
            let gone = previous.filter { process in !now.contains { $0.identity == process.identity } }
            tracker.add(now, appeared: appeared, disappeared: gone, watchesRestricted: true, interval: 1, at: date(1_000 + value))
            previous = now
        }
        let batch = tracker.close(at: date(1_010), samples: previous)
        #expect(batch.ended == [ProcessHistoryBatch.End(identity: identity(12, 500), time: date(1_007), isEnded: true)])
        #expect(batch.started.first { $0.identity.pid == 13 }?.firstSeen == date(1_005))
        let ended = batch.samples.first { $0.identity.pid == 12 }
        let born = batch.samples.first { $0.identity.pid == 13 }
        // 1.2 s of CPU over the 10-s record, and all 0.8 s of the newborn's.
        #expect(abs((ended?.cpuPercent ?? 0) - 12) < 1e-9)
        #expect(abs((born?.cpuPercent ?? 0) - 8) < 1e-9)
    }

    @Test func startsAfreshAfterAGapRatherThanAveragingIt() {
        var tracker = ProcessHistoryTracker(span: 10)
        func cpu(_ time: Double) -> ProcessSample { process(10, cpuTime: 0.5 * (time - 1_000), cpuPercent: 50) }
        for tick in 1...10 {
            tracker.add([cpu(1_000 + Double(tick))], appeared: tick == 1 ? [cpu(1_001)] : [], disappeared: [], watchesRestricted: true,
                        interval: 1, at: date(1_000 + Double(tick)))
        }
        _ = tracker.close(at: date(1_010), samples: [cpu(1_010)])
        // The app slept for 90 s; the process kept running.
        for tick in 0..<10 {
            let time = 1_100 + Double(tick)
            tracker.add([cpu(time)], appeared: [], disappeared: [], watchesRestricted: true, interval: 1, at: date(time))
        }
        let batch = tracker.close(at: date(1_109), samples: [cpu(1_109)])
        #expect(abs((batch.samples.first?.cpuPercent ?? 0) - 50) < 1e-9)
    }

    @Test func aRestrictedProcessNoLongerSampledIsntCalledEnded() {
        var tracker = ProcessHistoryTracker(span: 10)
        let root = process(1, start: 100, name: "launchd", restricted: true)
        let mine = process(20)
        tracker.add([root, mine], appeared: [root, mine], disappeared: [], watchesRestricted: true, interval: 1, at: date(1_001))
        tracker.add([], appeared: [], disappeared: [root, mine], watchesRestricted: false, interval: 1, at: date(1_002))
        let batch = tracker.close(at: date(1_002), samples: [])
        #expect(batch.ended.map(\.isEnded) == [false, true])
        #expect(batch.samples.first { $0.identity.pid == 1 }?.diskRead == nil, "macOS gives no disk figures for it")
    }

    @Test func handsOnEachLaunchdLabelOnce() {
        var tracker = ProcessHistoryTracker(span: 10)
        let job = process(40)
        tracker.add([job], appeared: [job], disappeared: [], watchesRestricted: true, interval: 1, at: date(1_001))
        let labels = [job.identity: "com.example.agent"]
        #expect(tracker.close(at: date(1_001), samples: [job], labels: labels).labels == labels)
        tracker.add([job], appeared: [], disappeared: [], watchesRestricted: true, interval: 1, at: date(1_002))
        #expect(tracker.close(at: date(1_002), samples: [job], labels: labels).labels.isEmpty)
    }
}

// MARK: - The recorder's storage

struct FlightRecorderProcessTests {
    @Test func aReusedPIDIsAnotherLifetime() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        for time in [1_010.0, 1_020, 1_030] { try await recorder.append(record(at: time)) }
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [start(42, 900, name: "worker", at: 1_001)],
                                                      samples: [kept(42, 900, cpu: 50)]))
        try await recorder.append(ProcessHistoryBatch(
            time: date(1_020), started: [start(42, 1_016, name: "worker", at: 1_017)], samples: [kept(42, 1_016, cpu: 20)],
            ended: [ProcessHistoryBatch.End(identity: identity(42, 900), time: date(1_015), isEnded: true)]
        ))
        try await recorder.append(ProcessHistoryBatch(time: date(1_030), samples: [kept(42, 1_016, cpu: 40)]))

        let matches = try await recorder.processLifetimes(matching: "worker", from: date(1_000), to: date(1_100))
        #expect(matches.map(\.lifetime.identity) == [identity(42, 1_016), identity(42, 900)], "the running one first")
        let (later, earlier) = (matches[0], matches[1])
        #expect(earlier.lifetime.ended == date(1_015))
        #expect(later.lifetime.ended == nil)
        #expect(later.lifetime.lastSeen == date(1_030), "its run's last record")
        // The earlier one's figures stay its own: one record of 50%, and the record after it ended, which left it out.
        #expect(earlier.summary.records == 2)
        #expect(earlier.summary.peakCPU == 50)
        #expect(earlier.summary.averageCPU == 25)
        #expect(later.summary.records == 2)
        #expect(later.summary.averageCPU == 30)
        #expect(later.summary.peakCPU == 40)
    }

    @Test func searchesNamesPathsBundlesLabelsAndPIDs() async throws {
        let url = temporaryURL()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A fake app bundle, so its identifier is read from the Info.plist.
        let bundle = folder.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "org.example.Fake"]
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let executable = bundle.appendingPathComponent("Contents/MacOS/Fake").path

        let recorder = try FlightRecorder(url: url)
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [
            start(1, 100, name: "Fake", path: executable, at: 1_001),
            start(2, 100, name: "mdworker_shared", path: "/System/Library/mdworker_shared", at: 1_001),
            start(3, 100, name: "100%_done", at: 1_001),
            start(4, 100, name: "helper", at: 1_001),
            start(5, 100, name: "Retired", at: 1_001),
        ], labels: [identity(4, 100): "com.example.Sync"], ended: [
            ProcessHistoryBatch.End(identity: identity(5, 100), time: date(1_002), isEnded: true),
        ]))
        func found(_ query: String, from: Double = 1_000) async throws -> [Int32] {
            try await recorder.processLifetimes(matching: query, from: date(from), to: date(1_100)).map(\.lifetime.identity.pid).sorted()
        }
        #expect(try await found("fake") == [1], "names, any case")
        #expect(try await found("ORG.EXAMPLE") == [1], "bundle identifiers")
        #expect(try await recorder.processLifetimes(matching: "Fake", from: date(1_000), to: date(1_100)).first?.lifetime.bundleID
            == "org.example.Fake")
        #expect(try await found("/System/Library") == [2], "executable paths")
        #expect(try await found("sync") == [4], "launchd labels")
        #expect(try await found("0%_") == [3], "% and _ taken literally")
        #expect(try await found("_shared") == [2])
        #expect(try await found("  4 ").contains(4), "a PID")
        #expect(try await found("") == [])
        #expect(try await found("retired") == [5])
        #expect(try await found("retired", from: 1_005) == [], "ended before the range")
    }

    @Test func tellsIdleFromUnrecordedFromZero() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        // Recorded 1,010-1,050 and 1,090-1,100; nothing 1,060-1,080 (the Mac slept).
        for time in [1_010.0, 1_020, 1_030, 1_040, 1_050, 1_090, 1_100] { try await recorder.append(record(at: time)) }
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [start(7, 900, name: "big", at: 1_001)],
                                                      samples: [kept(7, 900, cpu: 0, memory: 4 << 30)]))
        try await recorder.append(ProcessHistoryBatch(time: date(1_020), samples: [kept(7, 900, cpu: 30, memory: 4 << 30, disk: 2_000)]))
        for time in [1_030.0, 1_040, 1_050] { try await recorder.append(ProcessHistoryBatch(time: date(time))) }
        try await recorder.append(ProcessHistoryBatch(time: date(1_090), samples: [kept(7, 900, cpu: 10, memory: 5 << 30)]))
        try await recorder.append(ProcessHistoryBatch(time: date(1_100), samples: [kept(7, 900, cpu: 10, memory: 5 << 30)]))

        let lifetime = try #require(try await recorder.processLifetime(identity(7, 900)))
        let points = try await recorder.processPoints(lifetime, from: date(1_000), to: date(1_100), bucket: 10)
        #expect(points.map(\.time) == [1_010, 1_020, 1_030, 1_040, 1_050, 1_090, 1_100].map(date), "no points where nothing was recorded")
        #expect(points.map(\.segment) == [0, 0, 0, 0, 0, 1, 1])
        #expect(points[0].cpu == 0, "a stored zero is a zero")
        #expect(points[0].state == .stored)
        #expect(points[1].cpu == 30)
        #expect(points[1].diskRead == 2_000)
        #expect(points[2...4].allSatisfy { $0.state == .idle && $0.cpu == nil && $0.memory == nil && $0.diskRead == nil },
                "idle, not stored: no figures, never zeros")
        #expect(ProcessHistoryPoint.idleStretches(points, bucket: 10) == [date(1_020)...date(1_050)])
        #expect(ProcessHistoryPoint.at(date(1_036), in: points, bucket: 10)?.state == .idle)
        #expect(ProcessHistoryPoint.at(date(1_070), in: points, bucket: 10) == nil, "unrecorded")

        // Buckets of 20 s: one record kept and one idle averages as half.
        let wide = try await recorder.processPoints(lifetime, from: date(1_000), to: date(1_100), bucket: 20)
        let mixed = try #require(wide.first { $0.time == date(1_030) })
        #expect(mixed.state == .partlyIdle)
        #expect(mixed.cpu == 15)
        #expect(mixed.memory == Double(4 << 30))

        let summary = try await recorder.processSummary(lifetime, from: date(1_000), to: date(1_100))
        #expect(summary.records == 7)
        #expect(summary.stored == 4)
        #expect(summary.averageCPU == 50.0 / 7)
        #expect(summary.peakMemory == 5 << 30)
    }

    @Test func aProcessIdleThroughoutHasNoFigures() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        for time in [1_010.0, 1_020] { try await recorder.append(record(at: time)) }
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [start(8, 900, name: "quiet", at: 1_001)]))
        try await recorder.append(ProcessHistoryBatch(time: date(1_020)))
        let match = try #require(try await recorder.processLifetimes(matching: "quiet", from: date(1_000), to: date(1_100)).first)
        #expect(match.summary.isIdle)
        #expect(match.summary.averageCPU == nil && match.summary.peakMemory == nil, "idle, not zero")
    }

    @Test func aRestrictedProcessHasNoDiskFigures() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        try await recorder.append(record(at: 1_010))
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [start(9, 900, name: "root", at: 1_001, restricted: true)],
                                                      samples: [kept(9, 900, cpu: 5, disk: nil)]))
        let lifetime = try #require(try await recorder.processLifetime(identity(9, 900)))
        #expect(lifetime.isRestricted)
        let points = try await recorder.processPoints(lifetime, from: date(1_000), to: date(1_100), bucket: 10)
        #expect(points.first?.cpu == 5)
        #expect(points.first?.diskRead == nil)
        #expect(try await recorder.processSummary(lifetime, from: date(1_000), to: date(1_100)).averageDiskRead == nil)
    }

    @Test func aLaterRunTakesOverALifetimeStillRunning() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let first = try FlightRecorder(url: url)
            try await first.append(ProcessHistoryBatch(time: date(1_010), started: [start(50, 900, name: "daemon", at: 1_001),
                                                                                   start(51, 900, name: "gone", at: 1_001)]))
            try await first.append(ProcessHistoryBatch(time: date(1_020)))
        }
        let second = try FlightRecorder(url: url)
        try await second.append(ProcessHistoryBatch(time: date(2_000), started: [start(50, 900, name: "daemon", at: 1_991)]))
        try await second.append(ProcessHistoryBatch(time: date(2_010)))
        let daemon = try #require(try await second.processLifetime(identity(50, 900)))
        #expect(daemon.firstSeen == date(1_001))
        #expect(daemon.lastSeen == date(2_010))
        // Not seen again: last seen at the first run's last record, its end unknown.
        let gone = try #require(try await second.processLifetime(identity(51, 900)))
        #expect(gone.lastSeen == date(1_020))
        #expect(gone.ended == nil)
    }

    @Test func prunesWithTheRecordsRetention() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let week = FlightRecorder.retention
        try await recorder.append(record(at: 1_010))
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [start(60, 900, name: "short", at: 1_001),
                                                                                  start(61, 900, name: "long", at: 1_001)],
                                                      samples: [kept(60, 900, cpu: 5), kept(61, 900, cpu: 5)]))
        try await recorder.append(ProcessHistoryBatch(time: date(2_000), ended: [
            ProcessHistoryBatch.End(identity: identity(60, 900), time: date(1_990), isEnded: true),
        ]))
        try await recorder.append(ProcessHistoryBatch(time: date(1_000 + week + 100), samples: [kept(61, 900, cpu: 7)]))
        try await recorder.append(record(at: 1_000 + week + 100))
        try await recorder.prune(before: date(1_000 + week))

        #expect(try await recorder.processLifetime(identity(60, 900)) == nil, "ended over a week ago")
        let long = try #require(try await recorder.processLifetime(identity(61, 900)))
        let points = try await recorder.processPoints(long, from: date(0), to: date(1_000 + week + 200), bucket: 10)
        #expect(points.compactMap(\.cpu).isEmpty == false)
        let summary = try await recorder.processSummary(long, from: date(0), to: date(1_000 + week + 200))
        #expect(summary.stored == 1, "its old figures went, the recent stayed")
        #expect(summary.peakCPU == 7)
    }

    @Test func readsWithoutWritingOrCreating() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: FlightRecorderError.self) { try FlightRecorder(reading: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [start(70, 900, name: "seen", at: 1_001)]))
        }
        let reader = try FlightRecorder(reading: url)
        #expect(try await reader.keepsProcessHistory())
        #expect(try await reader.processLifetimes(matching: "seen", from: date(1_000), to: date(1_100)).count == 1)
        await #expect(throws: FlightRecorderError.self) { try await reader.append(record(at: 1_020)) }
    }
}

// MARK: - Schema 3

struct FlightRecorderSchemaThreeTests {
    /// A database as the hardware build (schema 2) left it.
    private func makeVersionTwo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE records (time REAL PRIMARY KEY, cpu REAL, cpu_peak REAL, memory REAL, pressure REAL, swap REAL,
                gpu REAL, system_watts REAL, cpu_watts REAL, gpu_watts REAL, disk_read REAL, disk_write REAL, net_in REAL,
                net_out REAL, chip_celsius REAL, top_cpu TEXT, top_memory TEXT, hardware BLOB) WITHOUT ROWID;
            CREATE TABLE sessions (id INTEGER PRIMARY KEY, start_time REAL NOT NULL, end_time REAL NOT NULL, note TEXT NOT NULL);
            CREATE TABLE events (time REAL NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT '', count INTEGER NOT NULL DEFAULT 1, approximate INTEGER NOT NULL DEFAULT 0);
            CREATE UNIQUE INDEX events_once ON events (kind, name, CAST(time AS INTEGER));
            CREATE INDEX events_time ON events (time);
            CREATE TABLE hardware_series (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                unit TEXT NOT NULL, label TEXT NOT NULL, source TEXT NOT NULL, rank INTEGER NOT NULL DEFAULT 0);
            INSERT INTO records VALUES (1000, 0.25, 0.5, 0.6, 0.2, 0, 0.1, 12, 4, 1, 100, 200, 300, 400, 51.5,
                '[{"n":"Safari","v":25}]', '[{"n":"Safari","v":1000}]', NULL);
            INSERT INTO sessions (start_time, end_time, note) VALUES (990, 1000, 'Before processes');
            PRAGMA user_version = 2;
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func bringsAVersionTwoDatabaseUpToDateKeepingEverything() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try makeVersionTwo(at: url)
        // Read before it's migrated: no process history yet.
        #expect(try await FlightRecorder(reading: url).keepsProcessHistory() == false)

        let recorder = try FlightRecorder(url: url)
        #expect(try await recorder.schemaVersionOnDisk() == 3)
        #expect(try await recorder.keepsProcessHistory())
        let old = try #require(try await recorder.records(from: date(0), to: date(2_000)).first)
        #expect(old.values.chipCelsius == 51.5)
        #expect(old.topCPU == [HistoryApp(name: "Safari", value: 25)])
        #expect(try await recorder.sessions().map(\.note) == ["Before processes"])
        // Its records from before have no process history: a search finds nothing rather than failing.
        #expect(try await recorder.processLifetimes(matching: "Safari", from: date(0), to: date(2_000)).isEmpty)
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [start(1, 900, name: "Safari", at: 1_001)]))
        #expect(try await recorder.processLifetimes(matching: "Safari", from: date(0), to: date(2_000)).count == 1)
    }

    @Test func anOlderBuildStillWritesItsRecordsBesideTheProcessTables() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append(record(at: 1_010))
            try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [start(1, 900, name: "kept", at: 1_001)]))
        }
        // What a schema-2 build does: its user_version is behind, so it leaves the tables as they are.
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let older = """
            INSERT OR REPLACE INTO records (time, cpu, cpu_peak, memory, pressure, swap, gpu, system_watts, cpu_watts, gpu_watts,
                disk_read, disk_write, net_in, net_out, chip_celsius, top_cpu, top_memory, hardware)
                VALUES (1020, 0.5, 0.5, 0.5, 0.1, 0, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 40, '[]', '[]', NULL);
            DELETE FROM records WHERE time < 0;
            """
        #expect(sqlite3_exec(handle, older, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let reopened = try FlightRecorder(url: url)
        #expect(try await reopened.schemaVersionOnDisk() == FlightRecorder.schemaVersion)
        #expect(try await reopened.records(from: date(1_000), to: date(1_100)).map(\.time) == [date(1_010), date(1_020)])
        #expect(try await reopened.processLifetime(identity(1, 900))?.name == "kept")
    }
}

// MARK: - Search queries

struct ProcessHistorySearchTests {
    @Test func escapesLikeWildcardsAndFindsPIDs() {
        #expect(ProcessHistorySearch.likePattern("50%_a\\b") == "%50\\%\\_a\\\\b%")
        #expect(ProcessHistorySearch.normalized("  safari \n") == "safari")
        #expect(ProcessHistorySearch.normalized("   ") == nil)
        #expect(ProcessHistorySearch.pid("123") == 123)
        #expect(ProcessHistorySearch.pid("12a") == nil)
        #expect(ProcessHistorySearch.pid("٣") == nil, "ASCII digits only")
    }

    @Test func aLifetimesSpanWithinARange() {
        let lifetime = ProcessLifetime(id: 1, identity: identity(1, 950), name: "p", firstSeen: date(1_000), lastSeen: date(1_200))
        #expect(lifetime.started == date(950))
        #expect(lifetime.span(within: date(900)...date(2_000), isRunning: false) == date(950)...date(1_200))
        #expect(lifetime.span(within: date(1_100)...date(2_000), isRunning: true, now: date(1_500)) == date(1_100)...date(1_500))
        #expect(lifetime.span(within: date(1_300)...date(2_000), isRunning: false) == nil)
    }
}
