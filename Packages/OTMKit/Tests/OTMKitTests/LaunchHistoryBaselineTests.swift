import Foundation
import SQLite3
import Testing
@testable import OTMKit

struct LaunchHistoryBaselineTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
    }

    private func reading(_ seconds: Double, pid: Int32? = 412, exit: Int32 = 0) -> LaunchJobReading {
        LaunchJobReading(time: date(seconds), domains: ["system": ["job": LaunchJobStatus(label: "job", pid: pid, lastExit: .code(exit))]])
    }

    @Test func relaunchKeepsAnUnchangedBaselineWithoutEventsOrStateWrites() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.observeLaunchJobs(reading(1_000), starts: [412: date(900)])
            try await recorder.observeLaunchJobs(reading(1_060))
        }
        let recorder = try FlightRecorder(url: url)
        try await recorder.observeLaunchJobs(reading(1_070))
        try await recorder.observeLaunchJobs(reading(1_130), starts: [412: date(900)])
        let events = try await recorder.launchJobEvents(label: "job", from: date(0), to: date(2_000))
        #expect(events.count == 1)
        #expect(events[0].kind == .observed)
        let state = try #require(try await recorder.launchJobStates().values.first)
        #expect(state.time == date(1_000), "an unchanged read must not upsert the baseline")
        #expect(state.started == date(900), "cheap reads don't erase a known start time")
        let coverage = try await recorder.launchJobCoverage(domain: "system", from: date(0), to: date(2_000))
        #expect(coverage == [LaunchHistoryInterval(start: date(1_000), end: date(1_060)),
                             LaunchHistoryInterval(start: date(1_070), end: date(1_130))])
    }

    @Test func thePageGetsTheOriginalFailureTimeAfterRelaunchAndRetention() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.observeLaunchJobs(reading(1_000, pid: nil, exit: 1))
            try await recorder.prune(before: date(2_000))
        }
        let recorder = try FlightRecorder(url: url)
        try await recorder.observeLaunchJobs(reading(3_000, pid: nil, exit: 1))
        let key = LaunchHistoryKey(label: "job", domain: "system")
        let state = await recorder.launchJobObservedStates()[key]
        let status = LaunchItemStatus(execution: .failed(code: 1), registration: .init(isLoaded: true, isDisabled: false),
                                      needsAttention: true)
        #expect(status.failureFirstSeen(in: state, key: key) == date(1_000))
        try await recorder.observeLaunchJobs(reading(3_060, pid: nil, exit: 2))
        let changed = await recorder.launchJobObservedStates()[key]
        #expect(status.failureFirstSeen(in: changed, key: key) == nil)
    }

    @Test func changedRelaunchHasOneObservedChangeBoundedByTheLastRead() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.observeLaunchJobs(reading(1_000))
            try await recorder.observeLaunchJobs(reading(1_060))
        }
        let recorder = try FlightRecorder(url: url)
        try await recorder.observeLaunchJobs(reading(1_070, pid: nil))
        let changed = try await recorder.launchJobEvents(label: "job", from: date(1_061), to: date(2_000))
        #expect(changed.count == 1)
        #expect(changed[0].kind == .observed)
        // The state changed at 1,000, but it still held at the read at 1,060.
        #expect(changed[0].since == date(1_060))
        #expect(changed[0].words.contains("was running · PID 412"))
        #expect(changed[0].words.contains("now not running"))
    }

    @Test func changedFailureAcrossRelaunchIsBoundedWithoutAnInventedExit() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do { let recorder = try FlightRecorder(url: url); try await recorder.observeLaunchJobs(reading(1_000)) }
        let recorder = try FlightRecorder(url: url)
        try await recorder.observeLaunchJobs(reading(2_000, pid: nil, exit: 1))
        let changed = try await recorder.launchJobEvents(label: "job", from: date(1_001), to: date(3_000))
        #expect(changed.map(\.kind) == [.observed, .failed])
        #expect(changed.allSatisfy { $0.since == date(1_000) })
        #expect(changed[0].words == "Changed while not watched: was running · PID 412, "
            + "now not running · Exited with code 1")
    }

    @Test func sleepComparesTheLastReadAndWritesNothingForUnchangedJobs() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        try await recorder.observeLaunchJobs(reading(1_000))
        try await recorder.observeLaunchJobs(reading(1_060))
        try await recorder.observeLaunchJobs(reading(2_000))
        #expect(try await recorder.launchJobEvents(label: "job", from: date(1_061), to: date(2_000)).isEmpty)
        try await recorder.observeLaunchJobs(reading(3_000, pid: nil, exit: -11))
        let changed = try await recorder.launchJobEvents(label: "job", from: date(2_001), to: date(4_000))
        #expect(changed.map(\.kind) == [.observed, .crashed])
        #expect(changed.allSatisfy { $0.since == date(2_000) })
    }

    @Test func pruningClipsCoverageAndKeepsAnUnchangedLoadedBaseline() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        try await recorder.observeLaunchJobs(reading(1_000))
        try await recorder.observeLaunchJobs(reading(1_060))
        try await recorder.observeLaunchJobs(reading(2_000))
        try await recorder.observeLaunchJobs(reading(2_060))
        try await recorder.prune(before: date(2_010))
        #expect(try await recorder.launchJobCoverage(domain: "system", from: date(0), to: date(3_000))
            == [LaunchHistoryInterval(start: date(2_010), end: date(2_060))])
        #expect(try await recorder.launchJobEvents(label: "job", from: date(0), to: date(3_000)).isEmpty)
        #expect(try await recorder.launchJobStates().values.first?.time == date(1_000))
        try await recorder.observeLaunchJobs(LaunchJobReading(time: date(2_070), domains: ["system": [:]]))
        try await recorder.prune(before: date(2_080))
        #expect(try await recorder.launchJobStates().isEmpty, "old unloaded baselines can age out")
    }

    @Test func unchangedConfigurationsAreNotFirstReadAgainOnRelaunch() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plist: [String: Any] = ["Label": "job", "Program": "/usr/bin/true"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let item = LaunchItems.item(plist: data, path: "/Library/LaunchDaemons/job.plist", scope: .daemon, modified: date(900))
        do {
            let recorder = try FlightRecorder(url: url)
            try await recorder.observeLaunchJobs(reading(1_000), items: [item])
        }
        let recorder = try FlightRecorder(url: url)
        try await recorder.observeLaunchJobs(reading(2_000), items: [item])
        #expect(try await recorder.launchJobEvents(label: "job", from: date(1_001), to: date(3_000)).isEmpty)
    }

    private func installWriteCounters(at url: URL) throws {
        let recorder = try FlightRecorder(url: url)
        _ = recorder
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            CREATE TABLE probe_writes (kind TEXT PRIMARY KEY, count INTEGER NOT NULL);
            INSERT INTO probe_writes VALUES ('state', 0), ('reads', 0);
            CREATE TRIGGER state_insert AFTER INSERT ON launch_job_state
                BEGIN UPDATE probe_writes SET count = count + 1 WHERE kind = 'state'; END;
            CREATE TRIGGER state_update AFTER UPDATE ON launch_job_state
                BEGIN UPDATE probe_writes SET count = count + 1 WHERE kind = 'state'; END;
            CREATE TRIGGER read_insert AFTER INSERT ON launch_job_reads
                BEGIN UPDATE probe_writes SET count = count + 1 WHERE kind = 'reads'; END;
            CREATE TRIGGER read_update AFTER UPDATE ON launch_job_reads
                BEGIN UPDATE probe_writes SET count = count + 1 WHERE kind = 'reads'; END;
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func threeLaunchesWith950JobsAndTwoChangesWriteOnly953Events() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try installWriteCounters(at: url)
        var jobs = Dictionary(uniqueKeysWithValues: (0..<950).map { index in
            let label = "fake.job.\(index)"
            return (label, LaunchJobStatus(label: label, pid: nil, lastExit: .code(0)))
        })
        for launch in 0..<3 {
            if launch == 1 { jobs["fake.job.0"] = LaunchJobStatus(label: "fake.job.0", pid: 412, lastExit: .code(0)) }
            if launch == 2 { jobs["fake.job.0"] = LaunchJobStatus(label: "fake.job.0", pid: nil, lastExit: .code(1)) }
            let recorder = try FlightRecorder(url: url)
            for offset in [0.0, 60, 120] {
                let time = date(1_000 + Double(launch * 600) + offset)
                try await recorder.observeLaunchJobs(LaunchJobReading(time: time, domains: ["system": jobs]))
            }
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT (SELECT COUNT(*) FROM launch_job_events), (SELECT COUNT(*) FROM launch_job_state), "
            + "(SELECT COUNT(*) FROM launch_job_reads), (SELECT count FROM probe_writes WHERE kind = 'state'), "
            + "(SELECT count FROM probe_writes WHERE kind = 'reads')"
        #expect(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 953)
        #expect(sqlite3_column_int(statement, 1) == 950)
        #expect(sqlite3_column_int(statement, 2) == 3)
        #expect(sqlite3_column_int(statement, 3) == 952, "950 baselines and two changes, never per read")
        #expect(sqlite3_column_int(statement, 4) == 9, "one domain row touched per successful read")
    }
}
