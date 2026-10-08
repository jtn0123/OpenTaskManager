import Foundation
import SQLite3
import Testing
@testable import OTMKit

struct ConnectionHistoryRecorderTests {
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
    }

    private func batch(at time: Double, tracker: inout ConnectionHistoryTracker, watch: inout ConnectionWatch,
                       open: Bool = true) -> ConnectionHistoryBatch {
        let socket = Connection(id: .init(pid: 7, fd: 3, socket: 10), processName: "Browser", transport: .tcp, family: .ipv4,
                                local: Endpoint(address: "127.0.0.1", port: 50_000), remote: Endpoint(address: "192.0.2.1", port: 443),
                                tcpState: .established, processStart: date(1))
        watch.observe(open ? [socket] : [], at: date(time))
        return tracker.observe(watch, at: date(time), spacing: 3, hidden: 2,
                               processes: [socket.process: .init(name: "Browser", path: "/Applications/Browser.app", user: "me")])
    }

    @Test func migrationFiveKeepsLaunchEventsStatesAndReads() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = LaunchHistoryKey(label: "job", domain: "system")
        let event = LaunchHistoryEvent(key: key, time: date(100), kind: .started, pid: 7)
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.appendLaunchJobEvents([event])
            try await recorder.observeLaunchJobs(LaunchJobReading(time: date(103), domains: ["system": [
                "job": LaunchJobStatus(label: "job", pid: 7, lastExit: .code(0)),
            ]]))
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, """
            DROP TABLE connection_lifetimes; DROP TABLE connection_coverage; DROP TABLE connection_limits; PRAGMA user_version = 5;
            """, nil, nil, nil) == SQLITE_OK)
        let oldReader = try FlightRecorder(reading: url)
        #expect(try await !oldReader.keepsConnectionHistory())
        #expect(try await oldReader.connectionHistory(from: date(0), to: date(200)).isEmpty)
        let recorder = try FlightRecorder(url: url)
        #expect(try await recorder.schemaVersionOnDisk() == 7)
        #expect(try await recorder.keepsConnectionHistory())
        #expect(try await recorder.launchJobEvents(label: "job", from: date(0), to: date(200)).contains(event))
        #expect(try await recorder.launchJobStates()[key]?.pid == 7)
        #expect(try await recorder.launchJobCoverage(domain: "system", from: date(0), to: date(200)).count == 1)
        let reopened = try FlightRecorder(url: url)
        #expect(try await reopened.schemaVersionOnDisk() == 7)
    }

    @Test func persistsEndsTimelineCoverageAndPrunesWithRecorder() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        try await recorder.appendConnections(batch(at: 100, tracker: &tracker, watch: &watch))
        try await recorder.appendConnections(batch(at: 103, tracker: &tracker, watch: &watch))
        try await recorder.appendConnections(batch(at: 106, tracker: &tracker, watch: &watch, open: false))
        let reader = try FlightRecorder(reading: url)
        let row = try #require(try await reader.connectionHistory(matching: "browser.app", from: date(0), to: date(200)).first)
        #expect(row.socket.firstSeen == date(100))
        #expect(row.socket.lastSeen == date(103))
        #expect(row.closedBy == date(106))
        #expect(row.ending == .closed)
        #expect(row.socket.timeline.last?.kind == .closed)
        #expect(row.states == [.established])
        for query in ["browser", "BROWSER.APP", "192.0.2", "https", "443", "7", ""] {
            #expect(try await reader.connectionHistoryResult(matching: query, from: date(0), to: date(200)).lifetimes.count == 1)
        }
        for query in ["4430", "%", "_"] {
            #expect(try await reader.connectionHistoryResult(matching: query, from: date(0), to: date(200)).lifetimes.isEmpty)
        }
        let coverage = try await reader.connectionCoverage(from: date(0), to: date(200))
        #expect(coverage.intervals.count == 1)
        #expect(coverage.intervals.first?.hiddenProcesses == 2)
        #expect(coverage.watchedSeconds == 6)
        try await recorder.prune(before: date(104))
        #expect(try await reader.connectionHistory(from: date(0), to: date(200)).isEmpty)
        #expect(try await reader.connectionCoverage(from: date(0), to: date(200)).intervals.first?.start == date(104))
    }

    @Test func interruptedLaunchAndExplicitStopHaveNoInventedCloseTime() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.appendConnections(batch(at: 100, tracker: &tracker, watch: &watch))
        }
        let recorder = try FlightRecorder(url: url)
        let interrupted = try #require(try await recorder.connectionHistory(from: date(0), to: date(200)).first)
        #expect(interrupted.ending == .stopped)
        #expect(interrupted.closedBy == nil)
        _ = batch(at: 103, tracker: &tracker, watch: &watch)
        try await recorder.appendConnections(tracker.stop())
        let stopped = try #require(try await recorder.connectionHistory(from: date(0), to: date(200)).first)
        #expect(stopped.socket.lastSeen == date(103))
        #expect(stopped.closedBy == nil)
        try await recorder.prune(before: date(104))
        #expect(try await recorder.connectionHistory(from: date(0), to: date(200)).isEmpty)
    }

    @Test func moreClosuresThanTheRecentListStillKeepEveryClosingStep() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        let sockets = (1...250).map { descriptor in
            Connection(id: .init(pid: 7, fd: Int32(descriptor), socket: UInt64(descriptor)), processName: "many",
                       transport: .tcp, family: .ipv4, local: Endpoint(address: "127.0.0.1", port: descriptor),
                       remote: nil, tcpState: .listen, processStart: date(1))
        }
        watch.observe(sockets, at: date(100))
        try await recorder.appendConnections(tracker.observe(watch, at: date(100), spacing: 3, hidden: 0))
        watch.observe([], at: date(103))
        #expect(watch.closed.count == ConnectionWatch.keptClosed)
        try await recorder.appendConnections(tracker.observe(watch, at: date(103), spacing: 3, hidden: 0))
        let rows = try await recorder.connectionHistory(from: date(0), to: date(200))
        #expect(rows.count == 250)
        #expect(rows.allSatisfy { $0.ending == .closed && $0.closedBy == date(103) && $0.socket.timeline.last?.kind == .closed })
    }

    @Test func rowCapDropsOldestEndedRowsAndReportsTheLoss() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        // Payloads are irrelevant to this SQL ordering check; no reader decodes these fixture rows.
        #expect(sqlite3_exec(handle, """
            WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n < 50002)
            INSERT INTO connection_lifetimes SELECT CAST(n AS TEXT), n, n, CASE WHEN n = 1 THEN 1 ELSE 0 END,
                '{}', 'fixture', '', 7, 0, 0 FROM numbers;
            """, nil, nil, nil) == SQLITE_OK)
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        try await recorder.appendConnections(batch(at: 60_000, tracker: &tracker, watch: &watch))
        #expect(scalar("SELECT COUNT(*) FROM connection_lifetimes", handle) == 50_000)
        #expect(scalar("SELECT COUNT(*) FROM connection_lifetimes WHERE id = '1'", handle) == 1)
        #expect(scalar("SELECT COUNT(*) FROM connection_lifetimes WHERE id IN ('2', '3', '4')", handle) == 0)
        #expect(try await recorder.connectionCoverage(from: date(0), to: date(60_001)).droppedRows == 3)
    }

    private func scalar(_ sql: String, _ handle: OpaquePointer?) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
