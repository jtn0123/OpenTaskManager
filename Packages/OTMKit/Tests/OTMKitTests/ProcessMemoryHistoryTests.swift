import Foundation
@testable import OTMKit
import SQLite3
import Testing

private func memoryDate(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
private let memoryIdentity = ProcessIdentity(pid: 42, startTime: memoryDate(1))

private func memoryStep(_ megabytes: UInt64, at seconds: Double, measure: ProcessMemoryMeasure = .footprint,
                        edges: Int = 0) -> ProcessMemoryStep {
    ProcessMemoryStep(time: memoryDate(seconds), footprint: megabytes * 1_024 * 1_024, measure: measure, edges: edges)
}

private func memoryProcess(_ pid: Int32 = 42, megabytes: UInt64 = 40, restricted: Bool = false) -> ProcessSample {
    ProcessSample(pid: pid, parentPID: 1, responsiblePID: pid, uid: restricted ? 0 : 501, userName: "test",
                  name: "daemon", executablePath: nil, state: .running, nice: 0, startTime: memoryDate(1),
                  isTranslated: false, isRestricted: restricted, cpuPercent: 0, cpuTime: 0, memory: megabytes * 1_024 * 1_024,
                  residentMemory: megabytes * 1_024 * 1_024, threadCount: 1, diskReadRate: 0, diskWriteRate: 0,
                  diskReadTotal: 0, diskWriteTotal: 0)
}

struct ProcessMemoryKeepTests {
    @Test func thresholdsAreInclusiveAndMeasuredFromTheLastStoredStep() {
        #expect(!ProcessMemoryKeep.keeps(memoryStep(55, at: 10), after: memoryStep(40, at: 0)))
        #expect(ProcessMemoryKeep.keeps(memoryStep(56, at: 10), after: memoryStep(40, at: 0)))
        #expect(!ProcessMemoryKeep.keeps(memoryStep(439, at: 10), after: memoryStep(400, at: 0)))
        #expect(ProcessMemoryKeep.keeps(memoryStep(440, at: 10), after: memoryStep(400, at: 0)))
        #expect(ProcessMemoryKeep.keeps(memoryStep(360, at: 10), after: memoryStep(400, at: 0)))
        #expect(!ProcessMemoryKeep.keeps(memoryStep(41, at: 1_799), after: memoryStep(40, at: 0)))
        #expect(ProcessMemoryKeep.keeps(memoryStep(41, at: 1_800), after: memoryStep(40, at: 0)))
        #expect(!ProcessMemoryKeep.keeps(memoryStep(40, at: 86_400), after: memoryStep(40, at: 0)))
        #expect(ProcessMemoryKeep.keeps(memoryStep(40, at: 10, measure: .resident), after: memoryStep(40, at: 0)))
    }

    @Test func steadyProcessHasOnlyItsFirstAndFinalReadingOverADay() {
        let process = memoryProcess()
        var state = ProcessMemoryState(process, at: memoryDate(0))
        var updates: [ProcessMemoryUpdate] = []
        for time in stride(from: 10.0, through: 86_400, by: 10) {
            state.record(process, at: memoryDate(time), ending: time == 86_400, into: &updates)
        }
        #expect(updates.compactMap(\.step).map(\.time) == [memoryDate(0), memoryDate(86_400)])
        #expect(updates.last?.step?.edges == 2)
    }

    @Test func leakUsesCoarseStepsAndKeepsItsPeakEvenBelowAStepThreshold() {
        var state = ProcessMemoryState(memoryProcess(), at: memoryDate(0))
        var updates: [ProcessMemoryUpdate] = []
        for megabytes in 40...900 {
            state.record(memoryProcess(megabytes: UInt64(megabytes)), at: memoryDate(Double(megabytes)),
                         ending: megabytes == 900, into: &updates)
        }
        let steps = updates.compactMap(\.step)
        #expect(steps.first?.footprint == 40 * 1_024 * 1_024)
        #expect(steps.last?.footprint == 900 * 1_024 * 1_024)
        #expect(steps.count > 20 && steps.count < 32)
        #expect(updates.last?.peak?.footprint == 900 * 1_024 * 1_024)
    }

    @Test func spikeAndFallAreKeptAndResidentStartsAnotherStretch() {
        var state = ProcessMemoryState(memoryProcess(), at: memoryDate(0))
        var updates: [ProcessMemoryUpdate] = []
        for (time, megabytes) in [(10.0, UInt64(400)), (20, 40)] {
            state.record(memoryProcess(megabytes: megabytes), at: memoryDate(time), into: &updates)
        }
        #expect(updates.compactMap(\.step).map(\.footprint) == [40, 400, 40].map { $0 * 1_024 * 1_024 })
        #expect(state.peak.time == memoryDate(10))
        state.record(memoryProcess(restricted: true), at: memoryDate(30), into: &updates)
        #expect(updates.compactMap(\.step).suffix(2).map(\.edges) == [2, 1])
        #expect(updates.last?.step?.measure == .resident)
    }

    @Test func anInterruptedRunCannotLendItsHeldFigureToTheNextWatch() {
        let steps = [memoryStep(40, at: 1, edges: 1), memoryStep(100, at: 51, edges: 1)]
        let coverage = [memoryDate(1)...memoryDate(20), memoryDate(50)...memoryDate(60)]
        #expect(ProcessMemoryTrack.figure(at: memoryDate(50), steps: steps, coverage: coverage) == nil)
        let points = ProcessMemoryTrack.points(steps: steps, coverage: coverage)
        #expect(!points.contains { $0.time == memoryDate(50) })
        #expect(points.last?.footprint == 100 * 1_024 * 1_024)
    }

    @Test func heldFiguresAndChartsNeverBridgeGapsOrStoppedWatches() {
        let steps = [memoryStep(40, at: 10, edges: 1), memoryStep(80, at: 20), memoryStep(81, at: 30, edges: 2),
                     memoryStep(100, at: 60, measure: .resident, edges: 1)]
        let coverage = [memoryDate(10)...memoryDate(30), memoryDate(50)...memoryDate(70)]
        #expect(ProcessMemoryTrack.figure(at: memoryDate(25), steps: steps, coverage: coverage)?.footprint == 80 * 1_024 * 1_024)
        #expect(ProcessMemoryTrack.figure(at: memoryDate(40), steps: steps, coverage: coverage) == nil)
        #expect(ProcessMemoryTrack.figure(at: memoryDate(55), steps: steps, coverage: coverage) == nil)
        let points = ProcessMemoryTrack.points(steps: steps, coverage: coverage)
        #expect(!points.contains { $0.time > memoryDate(30) && $0.time < memoryDate(60) })
        #expect(Set(points.filter { $0.measure == .footprint }.map(\.segment))
            .isDisjoint(with: Set(points.filter { $0.measure == .resident }.map(\.segment))))
        let lifetime = ProcessLifetime(id: 1, identity: memoryIdentity, name: "daemon", firstSeen: memoryDate(10), lastSeen: memoryDate(70))
        let idle = ProcessHistoryPoint(time: memoryDate(30), records: 1, stored: 0, cpu: nil, cpuPeak: nil,
                                       memory: nil, diskRead: nil, diskWrite: nil)
        #expect(ProcessHistoryLabels.moment(of: lifetime, at: memoryDate(25), points: [idle], bucket: 30,
                                            memory: steps, coverage: coverage) == .memory(steps[1]))
        #expect(ProcessHistoryLabels.moment(of: lifetime, at: memoryDate(40), points: [idle], bucket: 30,
                                            memory: steps, coverage: coverage) == .notRecorded)
        #expect(ProcessHistoryLabels.memoryMoment(memoryStep(412, at: 20)) == "Footprint about 412 MB (from the memory track)")
    }
}

struct ProcessMemoryRecorderTests {
    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("otm-memory-\(UUID().uuidString)/history.sqlite")
    }

    @Test func migrationFromSixPreservesProcessRowsAndDoesNotInventMemory() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        // The process tables are exactly the pre-memory schema, with existing rows.
        let sql = """
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
            """ + FlightRecorder.processTables + FlightRecorder.shortRunTables
            + FlightRecorder.launchJobTables + FlightRecorder.connectionTables + """
            INSERT INTO process_watches VALUES (1, 10, 20);
            INSERT INTO process_lifetimes (id, pid, start_time, name, first_seen, last_seen, watch) VALUES (1, 42, 1, 'daemon', 10, 20, 1);
            INSERT INTO process_samples VALUES (1, 20, 10, 41943040, 0, 0);
            PRAGMA user_version = 6;
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        let old = try FlightRecorder(reading: url)
        let before = try #require(try await old.processLifetime(memoryIdentity))
        #expect(before.peakFootprint == nil)
        #expect(try await old.processMemory(before).isEmpty)
        let recorder = try FlightRecorder(url: url)
        #expect(try await recorder.schemaVersionOnDisk() == 8)
        let after = try #require(try await recorder.processLifetime(memoryIdentity))
        #expect(after == before)
        #expect(try await recorder.processMemoryCoverage(after, from: memoryDate(0), to: memoryDate(30)).isEmpty)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT memory FROM process_samples WHERE lifetime = 1", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int64(statement, 0) == 41_943_040)
        sqlite3_finalize(statement)
        #expect(try await recorder.processMemory(after).isEmpty)
        #expect(try await FlightRecorder(url: url).schemaVersionOnDisk() == 8)
    }

    @Test func idleMemorySearchPeakGrowthRetentionAndReadOnlyReopen() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let identities = [memoryIdentity, ProcessIdentity(pid: 43, startTime: memoryDate(1))]
        let starts = identities.map {
            ProcessHistoryBatch.Start(identity: $0, name: "daemon", path: nil, user: "test", isRestricted: false, firstSeen: memoryDate(10))
        }
        for time in [20.0, 30, 60] {
            try await recorder.append(HistoryRecord(time: memoryDate(time), values: HistoryValues()))
            let updates = identities.map { identity in
                let value: UInt64 = identity.pid == 42 ? (time == 20 ? 40 : time == 30 ? 1_000 : 900) : 200
                let step = memoryStep(value, at: time, edges: time == 20 ? 1 : 0)
                return ProcessMemoryUpdate(identity: identity, step: step, peak: step)
            }
            try await recorder.append(ProcessHistoryBatch(time: memoryDate(time), started: time == 20 ? starts : [], memory: updates))
        }
        let matches = try await recorder.processLifetimes(matching: "daemon", from: memoryDate(0), to: memoryDate(100), sort: .grew)
        #expect(matches.map(\.lifetime.identity.pid) == [42, 43])
        #expect(matches.first?.memoryGrowth == Int64(860 * 1_024 * 1_024))
        let lifetime = try #require(matches.first?.lifetime)
        #expect(lifetime.peakFootprint == 1_000 * 1_024 * 1_024)
        #expect(lifetime.peakFootprintTime == memoryDate(30))
        #expect(matches.first?.summary.isIdle == true)
        let steps = try await recorder.processMemory(lifetime)
        #expect(steps.count == 3)
        let coverage = try await recorder.processMemoryCoverage(lifetime, from: memoryDate(0), to: memoryDate(100))
        #expect(!coverage.contains { $0.contains(memoryDate(40)) })
        let reader = try FlightRecorder(reading: url)
        #expect(try await reader.processMemory(lifetime) == steps)
        try await recorder.prune(before: memoryDate(35))
        let pruned = try await recorder.processMemory(lifetime)
        #expect(pruned.map(\.time) == [memoryDate(35), memoryDate(60)])
        #expect(pruned.first?.footprint == 1_000 * 1_024 * 1_024)
        try await recorder.prune(before: memoryDate(1_000))
        #expect(try await recorder.processMemory(lifetime).isEmpty)
    }

    @Test func growthDoesNotCompareFootprintWithRSSAndEndsPreventAGapCarry() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let start = ProcessHistoryBatch.Start(identity: memoryIdentity, name: "daemon", path: nil, user: "test",
                                              isRestricted: false, firstSeen: memoryDate(1))
        try await recorder.append(ProcessHistoryBatch(time: memoryDate(10), started: [start], memory: [
            ProcessMemoryUpdate(identity: memoryIdentity, step: memoryStep(40, at: 1, edges: 1)),
            ProcessMemoryUpdate(identity: memoryIdentity, step: memoryStep(40, at: 10, edges: 2)),
        ]))
        try await recorder.append(ProcessHistoryBatch(time: memoryDate(60), memory: [
            ProcessMemoryUpdate(identity: memoryIdentity, step: memoryStep(100, at: 60, measure: .resident, edges: 1)),
        ]))
        let matches = try await recorder.processLifetimes(matching: "daemon", from: memoryDate(0), to: memoryDate(100), sort: .grew)
        let lifetime = try #require(matches.first?.lifetime)
        #expect(matches.first?.memoryGrowth == nil)
        let steps = try await recorder.processMemory(lifetime)
        #expect(ProcessMemoryTrack.figure(at: memoryDate(50), steps: steps, coverage: [memoryDate(1)...memoryDate(60)]) == nil)
        try await recorder.prune(before: memoryDate(30))
        #expect(try await recorder.processMemory(lifetime).map(\.time) == [memoryDate(60)])
    }

    @Test func trackerKeepsAnIdleSpikeAndFallWithinOneRecordAndItsActualPeak() {
        var tracker = ProcessHistoryTracker()
        let large = (1...5).map { memoryProcess(Int32($0), megabytes: 2_000) }
        let idle = memoryProcess()
        for tick in 1...30 {
            let figure = memoryProcess(megabytes: tick == 25 ? 900 : 40)
            let samples = large + [figure]
            tracker.add(samples, appeared: tick == 1 ? samples : [], disappeared: [], interval: 1, at: memoryDate(Double(tick)))
            if tick % 10 == 0 {
                let batch = tracker.close(at: memoryDate(Double(tick)), samples: samples)
                if tick == 30 {
                    let changes = batch.memory.filter { $0.identity == idle.identity }
                    #expect(changes.compactMap(\.step).map(\.footprint) == [900, 40].map { $0 * 1_024 * 1_024 })
                    #expect(changes.compactMap(\.peak).first?.time == memoryDate(25))
                }
            }
        }
    }

    @Test func endedMemoryRemainsVisibleThroughItsLastPartialRecord() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let start = ProcessHistoryBatch.Start(identity: memoryIdentity, name: "daemon", path: nil, user: "test",
                                              isRestricted: false, firstSeen: memoryDate(1))
        for time in [10.0, 20] { try await recorder.append(HistoryRecord(time: memoryDate(time), values: HistoryValues())) }
        try await recorder.append(ProcessHistoryBatch(time: memoryDate(10), started: [start], memory: [
            ProcessMemoryUpdate(identity: memoryIdentity, step: memoryStep(40, at: 1, edges: 1)),
        ]))
        try await recorder.append(ProcessHistoryBatch(time: memoryDate(20), ended: [
            ProcessHistoryBatch.End(identity: memoryIdentity, time: memoryDate(15), isEnded: true),
        ], memory: [ProcessMemoryUpdate(identity: memoryIdentity, step: memoryStep(45, at: 14, edges: 2))]))
        let lifetime = try #require(try await recorder.processLifetime(memoryIdentity))
        let coverage = try await recorder.processMemoryCoverage(lifetime, from: memoryDate(0), to: memoryDate(30))
        #expect(coverage == [memoryDate(1)...memoryDate(15)])
        let steps = try await recorder.processMemory(lifetime)
        let points = ProcessMemoryTrack.points(steps: steps, coverage: coverage)
        #expect(points.last?.time == memoryDate(14))
        #expect(ProcessMemoryTrack.figure(at: memoryDate(15), steps: steps, coverage: coverage) == nil)
    }

    @Test func trackerPromotesIdleStartsWithTheirFirstFigureAndClosesAtTheLastReading() {
        var tracker = ProcessHistoryTracker()
        let processes = (1...6).map { memoryProcess(Int32($0), megabytes: UInt64($0)) }
        tracker.add(processes, appeared: processes, disappeared: [], interval: 1, at: memoryDate(10))
        #expect(!tracker.close(at: memoryDate(10), samples: processes).memory.contains { $0.identity.pid == 1 })
        tracker.add(processes, appeared: [], disappeared: [], interval: 1, at: memoryDate(20))
        let promoted = tracker.close(at: memoryDate(20), samples: processes)
        #expect(promoted.memory.first { $0.identity.pid == 1 }?.step?.time == memoryDate(10))
        tracker.add([], appeared: [], disappeared: processes, interval: 1, at: memoryDate(21))
        let ended = tracker.close(at: memoryDate(30), samples: [])
        #expect(ended.memory.first { $0.identity.pid == 1 }?.step?.time == memoryDate(20))
        #expect(ended.memory.first { $0.identity.pid == 1 }?.step?.edges == 2)
    }
}

struct ProcessMemoryPerformanceTests {
    @Test func sixHundredSteadyProcessesAddNoRowsPerRecordAndReportMemoryPassTime() {
        let processes = (1...600).map { memoryProcess(Int32($0)) }
        var states = processes.map { ProcessMemoryState($0, at: memoryDate(0)) }
        var updates: [ProcessMemoryUpdate] = []
        for index in states.indices { states[index].record(processes[index], at: memoryDate(10), into: &updates) }
        updates.removeAll(keepingCapacity: true)
        let clock = ContinuousClock()
        let began = clock.now
        for record in 1...1_000 {
            for index in states.indices {
                states[index].record(processes[index], at: memoryDate(Double(record) * 10), into: &updates)
            }
        }
        let elapsed = began.duration(to: clock.now)
        print("H9: 600-process memory pass, 1000 steady records: \(elapsed); added time per record: \(elapsed / 1_000)")
        #expect(updates.isEmpty)
        var tracker = ProcessHistoryTracker()
        tracker.add(processes, appeared: processes, disappeared: [], interval: 1, at: memoryDate(10))
        _ = tracker.close(at: memoryDate(10), samples: processes)
        tracker.add(processes, appeared: [], disappeared: [], interval: 1, at: memoryDate(20))
        _ = tracker.close(at: memoryDate(20), samples: processes)
        tracker.add(processes, appeared: [], disappeared: [], interval: 1, at: memoryDate(30))
        #expect(tracker.close(at: memoryDate(30), samples: processes).memory.isEmpty)
        let trackerStart = clock.now
        for record in 4...103 {
            for tick in 1...10 {
                tracker.add(processes, appeared: [], disappeared: [], interval: 1, at: memoryDate(Double(record * 10 + tick)))
            }
            #expect(tracker.close(at: memoryDate(Double(record * 10 + 10)), samples: processes).memory.isEmpty)
        }
        print("H9: complete tracker, 600 steady processes, 10 ticks per record: \(trackerStart.duration(to: clock.now) / 100) per record")
    }
}
