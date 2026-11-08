import Foundation
import SQLite3
import Testing
@testable import OTMKit

struct IncidentTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
    }

    @Test func windowBoundsBaselineAndCoverage() {
        let window = IncidentWindow(at: date(1_000))
        #expect(window.start == date(880))
        #expect(window.end == date(1_120))
        #expect(window.baseline.start == date(280))
        #expect(window.contains(date(880)))
        #expect(!window.contains(date(879)))
        #expect(IncidentWindow(from: date(1_120), to: date(880)) == window)
        let partial = IncidentCoverage(window: window, spans: [.init(start: date(700), end: date(900)),
                                                              .init(start: date(900), end: date(950))])
        #expect(partial.state == .partly)
        #expect(partial.spans == [.init(start: date(880), end: date(950))])
        #expect(IncidentCoverage(window: window, spans: []).state == .none)
        #expect(IncidentCoverage(window: window, spans: [.init(start: date(800), end: date(1_200))]).state == .whole)
        #expect(IncidentCoverage(window: window, spans: [.init(start: date(800), end: date(1_200))], cut: true).state == .partly)
    }

    @Test func identitiesNeverJoinRelaunchesOrUnknownStarts() {
        let old = ProcessIdentity(pid: 7, startTime: date(100))
        let new = ProcessIdentity(pid: 7, startTime: date(200))
        let lifetimes = [ProcessLifetime(id: 1, identity: old, name: "Agent", firstSeen: date(100), lastSeen: date(190)),
                         ProcessLifetime(id: 2, identity: new, name: "Agent", firstSeen: date(200), lastSeen: date(300))]
        #expect(IncidentTimeline.lifetime(for: old, in: lifetimes)?.id == 1)
        #expect(IncidentTimeline.lifetime(for: new, in: lifetimes)?.id == 2)
        #expect(IncidentTimeline.lifetime(for: ProcessIdentity(pid: 7, startTime: nil), in: lifetimes) == nil)
    }

    @Test func sequencesCarryEvidenceAndRespectPortsAndDomains() {
        let fixture = IncidentFixture.timeline(IncidentWindow(at: date(1_000)))
        #expect(fixture.sequences.count == 3)
        #expect(fixture.sequences.allSatisfy { !$0.evidence.isEmpty })
        #expect(fixture.sequences.contains { $0.label.contains("restarted 2 times") })
        #expect(fixture.sequences.contains { $0.label.contains("same port 8080") })
        var rows = fixture.lanes.first { $0.kind == .jobs }!.rows
        rows[1].job = LaunchHistoryKey(label: "com.example.agent", domain: "system")
        let lane = IncidentLane(kind: .jobs, rows: rows, coverage: fixture.lanes[0].coverage)
        let sequences = IncidentSequences.make([lane])
        #expect(sequences.count == 2)
        #expect(sequences.allSatisfy { $0.label.contains("restarted 1 time") })
        let sockets = fixture.lanes.first { $0.kind == .sockets }!
        var unrelated = sockets.rows
        unrelated[0].process = ProcessIdentity(pid: 412, startTime: date(20))
        let changed = IncidentLane(kind: .sockets, rows: unrelated, coverage: sockets.coverage)
        #expect(!IncidentSequences.make([fixture.lanes[1], changed]).contains { $0.label.contains("same port") })
    }

    @Test func redactsBothFormatsAndOptInPreservesDetails() throws {
        let window = IncidentWindow(at: date(1_000))
        let row = IncidentRow(id: "row", time: date(1_000), title: "alice Agent",
            detail: "/Users/alice/Library/log.txt · user: alice · 192.0.2.147:443 · 2001:db8:abcd:1234::9",
            remoteAddress: "192.0.2.147")
        let ipv6 = IncidentRow(id: "ipv6", time: date(1_001), title: "IPv6", remoteAddress: "2001:db8:abcd:1234::9")
        let lane = IncidentLane(kind: .sockets, rows: [row, ipv6], coverage: .init(window: window, spans: []))
        let timeline = IncidentTimeline(window: window, lanes: [lane])
        let export = IncidentExport(timeline, home: "/Users/alice", user: "alice")
        for text in [export.markdown(), String(decoding: try export.json(), as: UTF8.self)] {
            #expect(!text.contains("alice"))
            #expect(!text.contains("192.0.2.147"))
            #expect(!text.contains("1234::9"))
            #expect(text.contains("192.0.2.0/24"))
            #expect(text.contains("~/Library/log.txt"))
        }
        #expect(IncidentExport.maskAddress("") == "[masked remote]")
        #expect(IncidentExport.maskAddress("%") == "[masked remote]")
        #expect(IncidentExport.maskAddress("::1") == "0:0:0::/48")
        #expect(IncidentExport.maskAddress("2001:db8::99%en0") == "2001:db8:0::/48")
        let full = IncidentExport(timeline, includesPrivateDetails: true, home: "/Users/alice", user: "alice")
        #expect(full.markdown().contains("192.0.2.147"))
        #expect(String(decoding: try full.json(), as: UTF8.self).contains("/Users/alice/"))
    }

    @Test func temporaryDatabaseBoundsCutsAndReadOnlySnapshot() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let events = (0..<205).map { HistoryEvent(time: date(1_000 + Double($0)), kind: .wake, name: "Wake \($0)") }
        try await recorder.append(events + [.init(time: date(999), kind: .sleep, name: "Outside")])
        let key = LaunchHistoryKey(label: "agent", domain: "system")
        try await recorder.appendLaunchJobEvents([.init(key: key, time: date(1_004), kind: .restarted, pid: 7)])
        let window = IncidentWindow(from: date(1_000), to: date(1_300))
        let reader = try FlightRecorder(reading: url)
        let result = try await reader.incident(window, reportFolders: [])
        let lane = try #require(result.lanes.first { $0.kind == .events })
        #expect(lane.cut)
        #expect(lane.rows.count == 200)
        #expect(lane.rows.allSatisfy { window.contains($0.time) })
        #expect(lane.coverage.state == .partly)
        #expect(lane.coverage.inferred)
        #expect(result.lanes.first { $0.kind == .jobs }?.rows.count == 1)
        #expect(try await reader.schemaVersionOnDisk() == 10)
    }

    @Test func socketClosureInsideWindowAndPIDReuseLinkExactLifetime() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let old = ProcessIdentity(pid: 7, startTime: date(990))
        let new = ProcessIdentity(pid: 7, startTime: date(1_005))
        try await recorder.append(ProcessHistoryBatch(time: date(990), started: [
            .init(identity: old, name: "Agent", path: nil, user: "me", isRestricted: false, firstSeen: date(990)),
        ]))
        try await recorder.append(ProcessHistoryBatch(time: date(1_000), ended: [
            .init(identity: old, time: date(1_000), isEnded: true, lastSeen: date(999)),
        ]))
        try await recorder.append(ProcessHistoryBatch(time: date(1_005), started: [
            .init(identity: new, name: "Agent", path: nil, user: "me", isRestricted: false, firstSeen: date(1_005)),
        ]))
        let connection = Connection(id: .init(pid: 7, fd: 3, socket: 10), processName: "Agent", transport: .tcp, family: .ipv4,
            local: Endpoint(address: "127.0.0.1", port: 8080), remote: nil, tcpState: .listen, processStart: date(990))
        var watch = ConnectionWatch()
        var tracker = ConnectionHistoryTracker()
        watch.observe([connection], at: date(990))
        try await recorder.appendConnections(tracker.observe(watch, at: date(990), spacing: 3, hidden: 0))
        watch.observe([], at: date(1_000))
        try await recorder.appendConnections(tracker.observe(watch, at: date(1_000), spacing: 30, hidden: 0))
        let timeline = try await recorder.incident(.init(from: date(999), to: date(1_010)), reportFolders: [])
        let processes = try #require(timeline.lanes.first { $0.kind == .processes })
        #expect(processes.rows.count == 2)
        #expect(Set(processes.rows.compactMap(\.process)) == [old, new])
        let sockets = try #require(timeline.lanes.first { $0.kind == .sockets })
        let closed = try #require(sockets.rows.first { $0.kind == "closed" })
        #expect(closed.process == old)
        #expect(closed.lifetime == processes.rows.first { $0.process == old }?.lifetime)
        #expect(!sockets.rows.contains { $0.kind == "opened" })
    }

    @Test func migratesNineWithIndexesAndPreservesEvidence() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.append([.init(time: date(1_000), kind: .wake, name: "Keep me")])
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, """
            DROP INDEX process_lifetimes_incident_start; DROP INDEX process_lifetimes_incident_end;
            DROP INDEX process_watches_incident; DROP INDEX connection_lifetimes_incident_start;
            DROP INDEX connection_lifetimes_incident_end; PRAGMA user_version = 9;
            """, nil, nil, nil) == SQLITE_OK)
        let reader = try FlightRecorder(reading: url)
        #expect(try await reader.schemaVersionOnDisk() == 9)
        #expect(try await reader.incident(.init(at: date(1_000)), reportFolders: []).lanes.last?.rows.count == 1)
        #expect(try await reader.schemaVersionOnDisk() == 9)
        let migrated = try FlightRecorder(url: url)
        #expect(try await migrated.schemaVersionOnDisk() == 10)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name LIKE '%incident%'",
                                  -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 5)
        #expect(try await migrated.events(from: date(999), to: date(1_001)).first?.name == "Keep me")
    }
}
