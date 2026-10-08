import Foundation
@testable import OTMKit
import SQLite3
import Testing

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

/// Zero footprint keeps an idle process out of the largest-memory picks.
private func process(start: Double? = 1_008, cpuTime: Double = 0, restricted: Bool = false) -> ProcessSample {
    ProcessSample(
        pid: 50, parentPID: 1, responsiblePID: 50, uid: 501, userName: "me", name: "helper", executablePath: "/bin/helper",
        state: .running, nice: 0, startTime: start.map(date), isTranslated: false, isRestricted: restricted,
        cpuPercent: 0, cpuTime: cpuTime, memory: 0, residentMemory: 0, threadCount: 1,
        diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0
    )
}

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("otm-deferred-\(UUID().uuidString)")
        .appendingPathComponent("history.sqlite")
}

/// A process first seen partway through a record, with its exact tick time.
private func firstRecord(_ tracker: inout ProcessHistoryTracker, process: ProcessSample,
                         labels: [ProcessIdentity: String] = [:]) -> ProcessHistoryBatch {
    tracker.add([], appeared: [], disappeared: [], interval: 1, at: date(1_001))
    tracker.add([process], appeared: [process], disappeared: [], interval: 1, at: date(1_008.25))
    tracker.add([process], appeared: [], disappeared: [], interval: 1, at: date(1_010))
    return tracker.close(at: date(1_010), samples: [process], labels: labels)
}

struct ProcessDeferredLifetimeTests {
    @Test func defersAnIdleLifetimeOneRecordAndPreservesItsFirstSighting() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        var tracker = ProcessHistoryTracker()
        let idle = process()
        let labels = [idle.identity: "com.example.helper"]
        for time in [1_010.0, 1_020] {
            try await recorder.append(HistoryRecord(time: date(time), values: HistoryValues()))
        }
        let first = firstRecord(&tracker, process: idle, labels: labels)
        #expect(first.started.isEmpty && first.samples.isEmpty && first.labels.isEmpty)
        try await recorder.append(first)
        #expect(try await recorder.processLifetime(idle.identity) == nil)

        tracker.add([idle], appeared: [], disappeared: [], interval: 1, at: date(1_020))
        let second = tracker.close(at: date(1_020), samples: [idle])
        #expect(second.started.map(\.identity) == [idle.identity])
        #expect(second.labels == labels, "a label learned while deferred is handed on")
        try await recorder.append(second)
        let lifetime = try #require(try await recorder.processLifetime(idle.identity))
        #expect(lifetime.firstSeen == date(1_008.25), "the first tick, not the write time")
        #expect(lifetime.lastSeen == date(1_020))
        #expect(lifetime.jobLabel == labels[idle.identity])
        let found = try await recorder.processLifetimes(matching: "helper", from: date(1_000), to: date(1_030))
        #expect(found.map(\.lifetime.identity) == [idle.identity])
        #expect(found.first?.summary.records == 2)
        let points = try await recorder.processPoints(lifetime, from: date(1_000), to: date(1_030), bucket: 10)
        #expect(points.map(\.time) == [date(1_010), date(1_020)])
        #expect(points.allSatisfy { $0.state == .idle })
        tracker.add([idle], appeared: [], disappeared: [], interval: 1, at: date(1_030))
        #expect(tracker.close(at: date(1_030), samples: [idle], labels: labels).started.isEmpty)
        tracker.add([], appeared: [], disappeared: [idle], interval: 1, at: date(1_031))
        let ended = tracker.close(at: date(1_040), samples: [])
        #expect(ended.started.isEmpty && ended.shortRuns.isEmpty, "two record ends earned a lifetime")
        #expect(ended.ended.map(\.identity) == [idle.identity])
        try await recorder.append(ended)
        #expect(try await recorder.processLifetime(idle.identity)?.ended == date(1_031))
    }

    @Test(arguments: [1_008.0, nil])
    func countsAnIdleProcessThatEndsAfterOneBoundary(start: Double?) async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        var tracker = ProcessHistoryTracker()
        let idle = process(start: start)
        try await recorder.append(firstRecord(&tracker, process: idle))
        tracker.add([], appeared: [], disappeared: [idle], interval: 1, at: date(1_011))
        let second = tracker.close(at: date(1_020), samples: [])
        #expect(second.started.isEmpty && second.ended.isEmpty && second.samples.isEmpty)
        #expect(second.shortRuns == [ProcessHistoryBatch.ShortRuns(name: "helper", path: "/bin/helper", user: "me", count: 1)])
        try await recorder.append(second)
        #expect(try await recorder.processLifetime(idle.identity) == nil)
        #expect(try await recorder.processShortRuns(matching: "/bin/helper", from: date(1_000), to: date(1_030)).map(\.count) == [1])
    }

    @Test(arguments: [false, true])
    func keepsFiguresInEitherRecordEvenWhenTheProcessEnds(busyInFirst: Bool) async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        var tracker = ProcessHistoryTracker()
        let idle = process()
        tracker.add([], appeared: [], disappeared: [], interval: 1, at: date(1_001))
        tracker.add([idle], appeared: [idle], disappeared: [], interval: 1, at: date(1_008.25))
        let atBoundary = process(cpuTime: busyInFirst ? 1 : 0)
        tracker.add([atBoundary], appeared: [], disappeared: [], interval: 1, at: date(1_010))
        let first = tracker.close(at: date(1_010), samples: [atBoundary])
        #expect(first.started.isEmpty == !busyInFirst)
        #expect(first.samples.isEmpty == !busyInFirst)
        try await recorder.append(first)
        #expect((try await recorder.processLifetime(idle.identity) != nil) == busyInFirst)
        let last = process(cpuTime: 1)
        tracker.add([last], appeared: [], disappeared: [], interval: 1, at: date(1_011))
        tracker.add([], appeared: [], disappeared: [last], interval: 1, at: date(1_012))
        let second = tracker.close(at: date(1_020), samples: [])
        #expect(second.shortRuns.isEmpty)
        #expect(second.samples.isEmpty == busyInFirst)
        #expect(second.ended.map(\.identity) == [idle.identity])
        try await recorder.append(second)
        let lifetime = try #require(try await recorder.processLifetime(idle.identity))
        #expect(lifetime.firstSeen == date(1_008.25))
        #expect(lifetime.ended == date(1_012))
        #expect(try await recorder.processLifetimes(matching: "helper", from: date(1_000), to: date(1_030)).count == 1)
        #expect(try await recorder.processShortRuns(matching: "helper", from: date(1_000), to: date(1_030)).isEmpty)
    }

    @Test func aDeferredProcessThatStopsBeingWatchedIsNotCountedAsEnded() {
        var tracker = ProcessHistoryTracker()
        let root = process(restricted: true)
        _ = firstRecord(&tracker, process: root)
        tracker.watchesRestricted = false
        tracker.add([], appeared: [], disappeared: [root], interval: 1, at: date(1_011))
        let second = tracker.close(at: date(1_020), samples: [])
        #expect(second.started.map(\.identity) == [root.identity])
        #expect(second.ended.map(\.isEnded) == [false])
        #expect(second.shortRuns.isEmpty)
    }

    @Test func aDeferredProcessThatRanIntoAGapKeepsItsLifetime() {
        var tracker = ProcessHistoryTracker()
        let idle = process()
        _ = firstRecord(&tracker, process: idle)
        tracker.add([], appeared: [], disappeared: [idle], interval: 60, at: date(1_070))
        let second = tracker.close(at: date(1_080), samples: [])
        #expect(second.started.map(\.identity) == [idle.identity])
        #expect(second.ended.map(\.time) == [date(1_010)])
        #expect(second.shortRuns.isEmpty, "the gap did not observe how long it ran")
    }

    @Test func deferralLeavesMigratedRecordsAndRecordingFilesUnchanged() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let records = [1_010.0, 1_020].map { HistoryRecord(time: date($0), values: HistoryValues()) }
        do {
            let recorder = try FlightRecorder(url: url)
            for record in records { try await recorder.append(record) }
        }
        // Schema 3 kept lifetimes but had no short-run tables.
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let sql = "DROP TABLE process_short_runs; DROP TABLE process_kinds; PRAGMA user_version = 3;"
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let recorder = try FlightRecorder(url: url)
        #expect(try await recorder.schemaVersionOnDisk() == 4, "deferral needs no new schema")
        var tracker = ProcessHistoryTracker()
        let idle = process()
        try await recorder.append(firstRecord(&tracker, process: idle))
        tracker.add([], appeared: [], disappeared: [idle], interval: 1, at: date(1_011))
        try await recorder.append(tracker.close(at: date(1_020), samples: []))
        #expect(try await recorder.processShortRuns(matching: "helper", from: date(1_000), to: date(1_030)).map(\.count) == [1])
        #expect(try await recorder.records(from: date(1_000), to: date(1_030)) == records)
        let machine = RecordingMachine(modelIdentifier: "Test", modelName: nil, chip: "Test", memory: 1 << 30,
                                       macOSVersion: "14", macOSBuild: nil)
        let session = RecordingSession(start: date(1_000), end: date(1_020))
        let file = try await recorder.recording(of: session, machine: machine, generator: "tests", exported: date(1_030))
        let decoded = try RecordingFile.decode(file.encoded())
        #expect(decoded == file)
        #expect(decoded.records == records)
        let replay = try FlightRecorder(replaying: decoded, from: url)
        #expect(try await replay.records(from: date(1_000), to: date(1_030)) == records)
        #expect(try await replay.processLifetimes(matching: "helper", from: date(1_000), to: date(1_030)).isEmpty,
                "recording files still carry no process history")
    }
}
