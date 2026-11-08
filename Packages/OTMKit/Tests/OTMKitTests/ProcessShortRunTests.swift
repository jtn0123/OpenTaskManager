import Foundation
@testable import OTMKit
import SQLite3
import Testing

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("otm-short-runs-\(UUID().uuidString)")
        .appendingPathComponent("history.sqlite")
}

/// The app's PID in these tests.
private let app: Int32 = 900

/// A process at one tick. Five large ones fill the memory a record always keeps.
private func process(_ pid: Int32, start: Double, name: String = "sleep", path: String = "/bin/sleep", user: String = "me",
                     parent: Int32 = 1, cpuTime: Double = 0, memory: UInt64 = 1 << 20) -> ProcessSample {
    ProcessSample(
        pid: pid, parentPID: parent, responsiblePID: pid, uid: 501, userName: user, name: name, executablePath: path,
        state: .running, nice: 0, startTime: date(start), isTranslated: false, isRestricted: false, cpuPercent: 0, cpuTime: cpuTime,
        memory: memory, residentMemory: memory, threadCount: 1, diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0
    )
}

private let large = (30..<35).map { process(Int32($0), start: 100, name: "big\($0)", path: "/usr/bin/big", memory: 1 << 30) }

/// Ticks one a second from `from` through `through`, the processes at each
/// from `at`, then closes the record at the last.
private func record(_ tracker: inout ProcessHistoryTracker, from: Int, through: Int, previous: inout [ProcessSample],
                    at: (Double) -> [ProcessSample]) -> ProcessHistoryBatch {
    for tick in from...through {
        let time = Double(tick)
        let now = large + at(time)
        let appeared = now.filter { process in !previous.contains { $0.identity == process.identity } }
        let gone = previous.filter { process in !now.contains { $0.identity == process.identity } }
        tracker.add(now, appeared: appeared, disappeared: gone, interval: 1, at: date(time))
        previous = now
    }
    return tracker.close(at: date(Double(through)), samples: previous)
}

// MARK: - Which processes are only counted

struct ProcessShortRunTrackerTests {
    @Test func countsThoseThatStartAndEndWithinARecordAndKeepsThoseAtItsEnd() {
        var tracker = ProcessHistoryTracker(span: 10, ownPID: app)
        var previous: [ProcessSample] = []
        _ = record(&tracker, from: 1_001, through: 1_010, previous: &previous) { _ in [] }
        // Two sleeps come and go within the next record; a third is still there at its end.
        let batch = record(&tracker, from: 1_011, through: 1_020, previous: &previous) { time in
            var list: [ProcessSample] = []
            if time == 1_013 { list.append(process(50, start: 1_012.5)) }
            if time == 1_015 { list.append(process(51, start: 1_014.2)) }
            if time == 1_020 { list.append(process(52, start: 1_019.5)) }
            return list
        }
        #expect(batch.shortRuns == [ProcessHistoryBatch.ShortRuns(name: "sleep", path: "/bin/sleep", user: "me", count: 2)])
        #expect(batch.started.map(\.identity.pid) == [52], "the one seen at the record's end keeps its lifetime")
        #expect(batch.ended.isEmpty, "the counted ones get no end either")
        // It ends in the next record: it lived across the boundary, so it stays a lifetime of its own.
        let next = record(&tracker, from: 1_021, through: 1_030, previous: &previous) { _ in [] }
        #expect(next.ended.map(\.identity.pid) == [52])
        #expect(next.shortRuns.isEmpty)
    }

    @Test func keepsALifetimeForOneWhoseFiguresWereKept() {
        var tracker = ProcessHistoryTracker(span: 10, ownPID: app)
        var previous: [ProcessSample] = []
        _ = record(&tracker, from: 1_001, through: 1_010, previous: &previous) { _ in [] }
        // A compiler run: three seconds at a whole core, gone before the record ends.
        let batch = record(&tracker, from: 1_011, through: 1_020, previous: &previous) { time in
            var list: [ProcessSample] = []
            if (1_012...1_014).contains(time) {
                list.append(process(60, start: 1_011.5, name: "swift-frontend", path: "/usr/bin/swift-frontend", cpuTime: time - 1_011.5))
            }
            if time == 1_013 { list.append(process(61, start: 1_012.9)) }
            return list
        }
        #expect(batch.samples.contains { $0.identity.pid == 60 }, "busy enough to keep")
        #expect(batch.started.map(\.identity.pid) == [60])
        #expect(batch.ended.map(\.identity.pid) == [60])
        #expect(batch.shortRuns.map(\.name) == ["sleep"], "the idle one is only counted")
    }

    @Test func keepsALifetimeForOneThatStartedBeforeTheRecord() {
        var tracker = ProcessHistoryTracker(span: 10, ownPID: app)
        var previous: [ProcessSample] = []
        // Running since before the app launched, it quits within the first record: not a short run.
        let batch = record(&tracker, from: 1_001, through: 1_010, previous: &previous) { time in
            time <= 1_003 ? [process(70, start: 400, name: "Preview", path: "/Applications/Preview.app/Contents/MacOS/Preview")] : []
        }
        #expect(batch.shortRuns.isEmpty)
        #expect(batch.started.contains { $0.identity.pid == 70 })
        #expect(batch.ended.map(\.identity.pid) == [70])
    }

    @Test func countsByNameExecutableAndUser() {
        var tracker = ProcessHistoryTracker(span: 10, ownPID: app)
        var previous: [ProcessSample] = []
        _ = record(&tracker, from: 1_001, through: 1_010, previous: &previous) { _ in [] }
        let batch = record(&tracker, from: 1_011, through: 1_020, previous: &previous) { time in
            switch time {
            case 1_012: [process(80, start: 1_011.5), process(81, start: 1_011.6, user: "root")]
            case 1_014: [process(82, start: 1_013.5), process(83, start: 1_013.6, path: "/opt/bin/sleep")]
            case 1_016: [process(84, start: 1_015.5)]
            default: []
            }
        }
        #expect(batch.shortRuns == [
            ProcessHistoryBatch.ShortRuns(name: "sleep", path: "/bin/sleep", user: "me", count: 3),
            ProcessHistoryBatch.ShortRuns(name: "sleep", path: "/bin/sleep", user: "root", count: 1),
            ProcessHistoryBatch.ShortRuns(name: "sleep", path: "/opt/bin/sleep", user: "me", count: 1),
        ])
    }

    @Test func leavesTheAppsOwnShortRunsOut() {
        var tracker = ProcessHistoryTracker(span: 10, ownPID: app)
        var previous: [ProcessSample] = []
        _ = record(&tracker, from: 1_001, through: 1_010, previous: &previous) { _ in [] }
        let batch = record(&tracker, from: 1_011, through: 1_020, previous: &previous) { time in
            var list: [ProcessSample] = []
            // The app's own reads: ps every tick, a launchctl list; one ps is still running at the record's end.
            if time == 1_012 { list.append(process(90, start: 1_011.9, name: "ps", path: "/bin/ps", parent: app)) }
            if time == 1_015 { list.append(process(91, start: 1_014.9, name: "launchctl", path: "/bin/launchctl", parent: app)) }
            if time == 1_020 { list.append(process(92, start: 1_019.9, name: "ps", path: "/bin/ps", parent: app)) }
            // Someone else's ps is counted.
            if time == 1_017 { list.append(process(93, start: 1_016.9, name: "ps", path: "/bin/ps", parent: 4_000)) }
            return list
        }
        #expect(batch.shortRuns == [ProcessHistoryBatch.ShortRuns(name: "ps", path: "/bin/ps", user: "me", count: 1)])
        #expect(batch.started.map(\.identity.pid) == [92], "one of the app's own that outlives the record keeps its lifetime")
        #expect(batch.ended.isEmpty)
    }

    @Test func aProcessThatRanIntoAGapIsntAShortRun() {
        var tracker = ProcessHistoryTracker(span: 10, ownPID: app)
        var previous: [ProcessSample] = []
        _ = record(&tracker, from: 1_001, through: 1_010, previous: &previous) { _ in [] }
        // Started just before a minute's pause; seen once after it, then gone: it may have run the whole minute.
        tracker.add(large, appeared: [], disappeared: [], interval: 1, at: date(1_011))
        let late = process(95, start: 1_011.5)
        tracker.add(large + [late], appeared: [late], disappeared: [], interval: 61, at: date(1_072))
        tracker.add(large, appeared: [], disappeared: [late], interval: 1, at: date(1_073))
        let batch = tracker.close(at: date(1_073), samples: large)
        #expect(batch.shortRuns.isEmpty)
        #expect(batch.started.map(\.identity.pid) == [95])
    }
}

// MARK: - Storing, searching and pruning them

struct FlightRecorderShortRunTests {
    private func runs(_ name: String, path: String? = "/bin/sleep", user: String = "me", _ count: Int) -> ProcessHistoryBatch.ShortRuns {
        ProcessHistoryBatch.ShortRuns(name: name, path: path, user: user, count: count)
    }

    @Test func searchFindsTheCountsGroupedOverRecordsThatFollowOn() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        // Three records in a row count sleeps; none in the next two; then one more.
        for (time, count) in [(1_010.0, 7), (1_020, 9), (1_030, 4), (1_060, 2)] {
            try await recorder.append(ProcessHistoryBatch(time: date(time), shortRuns: [runs("sleep", count)]))
        }
        try await recorder.append(ProcessHistoryBatch(time: date(1_020), shortRuns: [runs("sleep", user: "root", 5),
                                                                                      runs("zsh", path: "/bin/zsh", 1)]))
        let found = try await recorder.processShortRuns(matching: "sleep", from: date(1_000), to: date(1_100))
        #expect(found == [
            ProcessHistoryShortRuns(name: "sleep", path: "/bin/sleep", user: "me", count: 2, records: 1, from: date(1_050), to: date(1_060)),
            ProcessHistoryShortRuns(name: "sleep", path: "/bin/sleep", user: "me", count: 20, records: 3, from: date(1_000), to: date(1_030)),
            ProcessHistoryShortRuns(name: "sleep", path: "/bin/sleep", user: "root", count: 5, records: 1, from: date(1_010), to: date(1_020)),
        ], "latest first, a group per kind and run of records")
        #expect(try await recorder.processShortRuns(matching: "/BIN/Z", from: date(1_000), to: date(1_100)).map(\.count) == [1],
                "executable paths, any case")
        #expect(try await recorder.processShortRuns(matching: "sleep", from: date(1_025), to: date(1_045)).map(\.count) == [4],
                "only the records in the range")
        #expect(try await recorder.processShortRuns(matching: "1020", from: date(1_000), to: date(1_100)).isEmpty, "no PIDs to find")
        #expect(try await recorder.processShortRuns(matching: "sleep", from: date(1_000), to: date(1_100), limit: 1).map(\.count) == [2])
        #expect(try await recorder.processLifetimes(matching: "sleep", from: date(1_000), to: date(1_100)).isEmpty,
                "counted, not given lifetimes")
    }

    @Test func aTrackedShortRunIsFoundBySearch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        var tracker = ProcessHistoryTracker(span: 10, ownPID: app)
        var previous: [ProcessSample] = []
        try await recorder.append(record(&tracker, from: 1_001, through: 1_010, previous: &previous) { _ in [] })
        try await recorder.append(record(&tracker, from: 1_011, through: 1_020, previous: &previous) { time in
            time == 1_013 || time == 1_016 ? [process(Int32(time), start: time - 0.5, name: "git", path: "/usr/bin/git")] : []
        })
        let found = try await recorder.processShortRuns(matching: "git", from: date(1_000), to: date(1_100))
        #expect(found.map(\.count) == [2])
        #expect(found.first?.path == "/usr/bin/git")
        #expect(found.first?.from == date(1_010))
        #expect(try await recorder.processLifetimes(matching: "git", from: date(1_000), to: date(1_100)).isEmpty)
    }

    @Test func pruningTakesShortRunsAndTheirKindsWithTheRest() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let week = FlightRecorder.retention
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), shortRuns: [runs("old", 3), runs("both", 1)]))
        try await recorder.append(ProcessHistoryBatch(time: date(1_000 + week + 100), shortRuns: [runs("both", 2)]))
        try await recorder.prune(before: date(1_000 + week))

        #expect(try await recorder.processShortRuns(matching: "old", from: date(0), to: date(2 * week)).isEmpty)
        #expect(try await recorder.processShortRuns(matching: "both", from: date(0), to: date(2 * week)).map(\.count) == [2])
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT name FROM process_kinds ORDER BY name", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var kinds: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { kinds.append(String(cString: sqlite3_column_text(statement, 0))) }
        #expect(kinds == ["both"], "a kind with no short runs left goes too")
    }

    @Test func bringsASchemaThreeDatabaseUpAndReadsOneThatHasNoShortRuns() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [
                ProcessHistoryBatch.Start(identity: ProcessIdentity(pid: 5, startTime: date(900)), name: "kept", path: nil, user: "me",
                                          isRestricted: false, firstSeen: date(1_001)),
            ]))
        }
        // As the first process-history build left it: schema 3, no short-run tables.
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let older = "DROP TABLE process_short_runs; DROP TABLE process_kinds; PRAGMA user_version = 3;"
        #expect(sqlite3_exec(handle, older, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let reader = try FlightRecorder(reading: url)
        #expect(try await reader.processShortRuns(matching: "sleep", from: date(0), to: date(2_000)).isEmpty, "nothing, not an error")
        let recorder = try FlightRecorder(url: url)
        #expect(try await recorder.schemaVersionOnDisk() == FlightRecorder.schemaVersion)
        #expect(try await recorder.processLifetimes(matching: "kept", from: date(0), to: date(2_000)).count == 1)
        try await recorder.append(ProcessHistoryBatch(time: date(1_020), shortRuns: [runs("sleep", 4)]))
        #expect(try await recorder.processShortRuns(matching: "sleep", from: date(0), to: date(2_000)).map(\.count) == [4])
    }
}
