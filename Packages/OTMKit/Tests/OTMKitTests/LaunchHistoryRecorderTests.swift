import Foundation
import SQLite3
import Testing
@testable import OTMKit

struct LaunchHistoryRecorderTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
    }

    @Test func migratesSchemaFourKeepingRecordsAndProcessHistory() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            var values = HistoryValues()
            values.cpu = 42
            try await recorder.append(HistoryRecord(time: date(1_000), values: values))
            try await recorder.append(ProcessHistoryBatch(time: date(1_000), started: [
                ProcessHistoryBatch.Start(identity: ProcessIdentity(pid: 7, startTime: date(900)), name: "kept", path: nil,
                                          user: "me", isRestricted: false, firstSeen: date(900)),
            ]))
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "DROP TABLE launch_job_events; PRAGMA user_version = 4;", nil, nil, nil) == SQLITE_OK)
        let olderReader = try FlightRecorder(reading: url)
        #expect(try await !olderReader.keepsLaunchJobHistory())
        #expect(try await olderReader.launchJobEvents(label: "job", from: date(0), to: date(2_000)).isEmpty)
        let recorder = try FlightRecorder(url: url)
        #expect(try await recorder.schemaVersionOnDisk() == 5)
        #expect(try await recorder.keepsProcessHistory())
        #expect(try await recorder.processLifetimes(matching: "kept", from: date(0), to: date(2_000)).first?.lifetime.name == "kept")
        #expect(try await recorder.records(from: date(0), to: date(2_000)).first?.values.cpu == 42)
        #expect(try await recorder.keepsLaunchJobHistory())
        let event = LaunchHistoryEvent(key: LaunchHistoryKey(label: "job", domain: "system"), time: date(1_010), kind: .started, pid: 3)
        try await recorder.appendLaunchJobEvents([event])
        let reopened = try FlightRecorder(url: url)
        #expect(try await reopened.schemaVersionOnDisk() == 5)
        #expect(try await reopened.launchJobEvents(label: "job", from: date(0), to: date(2_000)) == [event])
    }

    @Test func persistsExactLabelsDomainsAndPrunesWithTheRecorder() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let keys = [LaunchHistoryKey(label: "job", domain: "system"), LaunchHistoryKey(label: "job", domain: "gui/501"),
                    LaunchHistoryKey(label: "job%", domain: "system")]
        let old = LaunchHistoryEvent(key: keys[0], time: date(999), kind: .exited, exit: .code(78))
        let events = keys.map { LaunchHistoryEvent(key: $0, time: date(1_000), since: date(990), kind: .started, pid: 5) }
        try await recorder.appendLaunchJobEvents([old] + events + events)
        #expect(try await recorder.launchJobEvents(label: "job", from: date(0), to: date(2_000)).count == 3)
        #expect(try await recorder.launchJobEvents(label: "job%", from: date(0), to: date(2_000)) == [events[2]])
        try await recorder.prune(before: date(1_000))
        let reader = try FlightRecorder(reading: url)
        #expect(try await reader.launchJobEvents(label: "job", domain: "system", from: date(0), to: date(2_000)) == [events[0]])
        #expect(try await reader.launchJobEvents(label: "job", domain: "gui/501", from: date(0), to: date(2_000)) == [events[1]])
    }

    @Test func failedDomainReadCannotUnloadAJobAndNextLaunchCannotInventARestart() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let domain = "gui/\(getuid())"
        func reading(_ time: Double, pid: Int32) -> LaunchJobReading {
            LaunchJobReading(time: date(time), domains: [domain: ["job": LaunchJobStatus(label: "job", pid: pid, lastExit: .code(0))]])
        }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.observeLaunchJobs(reading(1_000, pid: 1))
            try await recorder.observeLaunchJobs(LaunchJobReading(time: date(1_010), domains: [:]))
            try await recorder.observeLaunchJobs(reading(1_020, pid: 1))
            let events = try await recorder.launchJobEvents(label: "job", from: date(0), to: date(2_000))
            #expect(!events.contains { $0.kind == .unloaded || $0.kind == .restarted })
            #expect(events.last { $0.kind == .gap }?.since == date(1_000), "the failed read breaks observation coverage")
            // A bulk read can see a job unload even if no plist was scanned.
            try await recorder.observeLaunchJobs(LaunchJobReading(time: date(1_030), domains: [domain: [:]]))
            #expect(try await recorder.launchJobEvents(label: "job", from: date(0), to: date(2_000)).last?.kind == .unloaded)
        }
        let reopened = try FlightRecorder(url: url)
        try await reopened.observeLaunchJobs(reading(1_040, pid: 2))
        let events = try await reopened.launchJobEvents(label: "job", from: date(0), to: date(2_000))
        #expect(!events.contains { $0.kind == .restarted })
        #expect(events.filter { $0.kind == .gap }.count == 3)
    }

    @Test func remembersConfigurationAcrossLaunches() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plist = Data("""
            <plist version="1.0"><dict><key>Label</key><string>job</string><key>Program</key><string>/usr/bin/true</string></dict></plist>
            """.utf8)
        let first = LaunchItems.item(plist: plist, path: "/Library/LaunchAgents/job.plist", scope: .userAgent, modified: date(10))
        let changed = LaunchItems.item(plist: plist, path: first.plistPath, scope: first.scope, modified: date(20))
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.observeLaunchConfiguration(first, at: date(1_000))
        }
        let recorder = try FlightRecorder(url: url)
        try await recorder.observeLaunchConfiguration(changed, at: date(2_000))
        let events = try await recorder.launchJobEvents(label: "job", from: date(0), to: date(3_000))
        #expect(events.count == 2)
        #expect(events.last?.configuration?.modified == date(20))
        #expect(events.last?.words == "Configuration changed · time unknown")
        try await recorder.observeLaunchJobs(LaunchJobReading(time: date(2_010), domains: [LaunchHistoryKey(changed).domain: [:]]))
        let after = try await recorder.launchJobEvents(label: "job", from: date(0), to: date(3_000))
        #expect(after.filter { $0.kind == .configuration }.count == 2)
    }
}
