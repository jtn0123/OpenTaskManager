import Foundation
@testable import OTMKit
import SQLite3
import Testing

private let endStart = Date(timeIntervalSince1970: 1_700_000_000)

private func endTime(_ seconds: Double) -> Date { endStart.addingTimeInterval(seconds) }

private func endedLifetime(path: String? = "/Applications/Worker.app/Contents/MacOS/Worker") -> ProcessLifetime {
    ProcessLifetime(id: 1, identity: ProcessIdentity(pid: 42, startTime: endStart), name: "Worker", path: path,
                    jobLabel: "local.worker", firstSeen: endTime(1), lastSeen: endTime(50), ended: endTime(60))
}

struct ProcessDiagnosticReportTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("otm-ending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(in folder: URL, suffix: String, type: String = "309", pid: Int32 = 42, at seconds: Double = 55,
                         path: String = "/Applications/Worker.app/Contents/MacOS/Worker", modified: Double = 60,
                         tail: String = "") throws -> URL {
        let url = folder.appendingPathComponent("Worker-\(suffix).ips")
        let timestamp = ISO8601DateFormatter().string(from: endTime(seconds))
        let text = """
            {"app_name":"Worker","bug_type":"\(type)","timestamp":"\(timestamp)"}
            {"pid":\(pid),"procName":"Worker","procPath":"\(path)",
             "exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
             "termination":{"namespace":"SIGNAL","code":11,"indicator":"Segmentation fault"}\(tail)}
            """
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: endTime(modified)], ofItemAtPath: url.path)
        return url
    }

    @Test func findsCrashAndJetsamButRejectsOtherPIDsPathsAndTimes() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crash = try fixture(in: directory, suffix: "crash")
        let jetsam = try fixture(in: directory, suffix: "jetsam", type: "298", at: 56)
        _ = try fixture(in: directory, suffix: "other-pid", pid: 43)
        _ = try fixture(in: directory, suffix: "old", at: -1)
        _ = try fixture(in: directory, suffix: "late", at: 181)
        _ = try fixture(in: directory, suffix: "other-path", path: "/tmp/Worker")
        let reports = ProcessDiagnosticReports.read(for: endedLifetime(), in: [directory])
        #expect(reports.map(\.report) == [crash, jetsam])
        #expect(reports[0].summary.contains("Crash report"))
        #expect(reports[0].summary.contains("EXC_BAD_ACCESS"))
        #expect(reports[0].summary.contains("SIGSEGV"))
        #expect(reports[1].summary.contains("Jetsam / memory report"))
    }

    @Test func missingPathUsesNameAndUnknownTypesStayNeutral() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try fixture(in: directory, suffix: "unknown", type: "999", path: "/tmp/Worker")
        let reports = ProcessDiagnosticReports.read(for: endedLifetime(path: nil), in: [directory])
        #expect(reports.count == 1)
        #expect(reports[0].summary.hasPrefix("Diagnostic report"))
        #expect(ProcessDiagnosticReports.kind("288") == "Hang / spin report")
    }

    @Test func capsReadsAndCanUseFieldsBeforeAnIncompleteThreadTail() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let padding = String(repeating: "x", count: ProcessDiagnosticReports.byteLimit * 2)
        let report = try fixture(in: directory, suffix: "big", tail: ",\"threads\":[{\"stack\":\"\(padding)\"}]")
        #expect(ProcessDiagnosticReports.read(for: endedLifetime(), in: [directory]).first?.report == report)
        try FileManager.default.setAttributes([.modificationDate: endTime(181)], ofItemAtPath: report.path)
        #expect(ProcessDiagnosticReports.read(for: endedLifetime(), in: [directory]).isEmpty)
    }

    @Test func jetsamNamesOnlyTheProcessReportedAsKilled() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("JetsamEvent-2023.ips")
        let text = """
            {"bug_type":298,"timestamp":"2023-11-14 22:14:15.000 +0000"}
            {"processes":[{"pid":43,"name":"Other","reason":"per-process-limit"},
                {"pid":42,"name":"Worker"}]}
            """
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: endTime(60)], ofItemAtPath: url.path)
        #expect(ProcessDiagnosticReports.read(for: endedLifetime(), in: [directory]).isEmpty)
        let killed = text.replacingOccurrences(of: "\"name\":\"Worker\"",
                                              with: "\"name\":\"Worker\",\"reason\":\"per-process-limit\"")
        try Data(killed.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: endTime(60)], ofItemAtPath: url.path)
        let reports = ProcessDiagnosticReports.read(for: endedLifetime(), in: [directory])
        #expect(reports.count == 1)
        #expect(reports.first?.summary == "Jetsam / memory report · per-process-limit")
    }

    @Test func scansBothSuppliedFoldersAndIgnoresUnreadableOnes() throws {
        let user = try folder()
        let system = try folder()
        defer {
            try? FileManager.default.removeItem(at: user)
            try? FileManager.default.removeItem(at: system)
        }
        let report = try fixture(in: system, suffix: "system")
        let missing = user.appendingPathComponent("missing")
        #expect(ProcessDiagnosticReports.read(for: endedLifetime(), in: [user, system, missing]).map(\.report) == [report])
    }
}

struct ProcessEndingEvidenceTests {
    @Test func noEvidenceNeverCallsADisappearanceACrash() {
        let ending = ProcessEnding(lifetime: endedLifetime())
        #expect(ending.words { String(Int($0.timeIntervalSince(endStart))) }
            == ["Ended between 50 and 60; no crash report or exit status was found"])
        var unobserved = endedLifetime()
        unobserved.ended = nil
        #expect(ProcessEnding(lifetime: unobserved).words { _ in "12:03:00" }
            == ["Last seen at 12:03:00; no crash report or exit status was found"])
    }

    @Test func deliveredSignalsAndAcceptedQuitRequestsKeepTheirMeaning() {
        let lifetime = endedLifetime()
        let force = HistoryEvent.endedByApp(time: endTime(55), name: "Worker",
            action: ProcessEndAction(identity: lifetime.identity, path: lifetime.path, signal: 9))
        let quit = HistoryEvent.endedByApp(time: endTime(54), name: "Worker",
            action: ProcessEndAction(identity: lifetime.identity, path: lifetime.path, signal: nil))
        let reused = HistoryEvent.endedByApp(time: endTime(56), name: "Worker",
            action: ProcessEndAction(identity: ProcessIdentity(pid: 42, startTime: endTime(52)), path: lifetime.path, signal: 9))
        let ending = ProcessEnding(lifetime: lifetime, events: [force, quit, reused])
        #expect(ending.evidence.count == 2)
        #expect(ending.words { _ in "12:03:10" } == [
            "Quit requested by OpenTaskManager (End Task) at 12:03:10",
            "Ended by OpenTaskManager (Force Quit) at 12:03:10",
        ])
        #expect(ProcessEndAction(identity: lifetime.identity, path: nil, signal: 15).words
            == "OpenTaskManager sent SIGTERM (End Task)")
    }

    @Test func launchdNeedsTheRightJobProcessAndObservedEnd() {
        let lifetime = endedLifetime()
        let key = LaunchHistoryKey(label: "local.worker", domain: "gui/501")
        let exit = LaunchHistoryEvent(key: key, time: endTime(90), since: endTime(30), kind: .exited,
                                     exit: .code(-9), exitedIdentity: lifetime.identity)
        let wrong = LaunchHistoryEvent(key: key, time: endTime(90), since: endTime(30), kind: .exited,
                                       exit: .code(1), exitedIdentity: ProcessIdentity(pid: 43, startTime: endStart))
        let late = LaunchHistoryEvent(key: key, time: endTime(200), since: endTime(30), kind: .exited,
                                      exit: .code(1), exitedIdentity: lifetime.identity)
        let ending = ProcessEnding(lifetime: lifetime, launchEvents: [exit, wrong, late])
        #expect(ending.evidence.map(\.summary) == ["launchd reported terminated by SIGKILL"])
        let legacy = LaunchHistoryEvent(key: key, time: endTime(90), since: endTime(30), kind: .exited, exit: .code(1))
        #expect(ProcessEnding(lifetime: lifetime, launchEvents: [legacy]).evidence.isEmpty)
        let start = LaunchHistoryEvent(key: key, time: endTime(10), kind: .started, pid: 42)
        #expect(ProcessEnding(lifetime: lifetime, launchEvents: [start, legacy]).evidence.map(\.summary)
            == ["launchd reported exit code 1"])
    }

    @Test func appEventsRoundTripAndKeepEverySameNamedGroupMember() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("otm-end-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try FlightRecorder(url: directory.appendingPathComponent("history.sqlite"))
        let events = [42, 43].map { pid in
            HistoryEvent.endedByApp(time: endTime(55), name: "Worker",
                action: ProcessEndAction(identity: ProcessIdentity(pid: Int32(pid), startTime: endStart), path: "/tmp/Worker", signal: 9))
        }
        try await recorder.append(events + events)
        #expect(try await recorder.events(from: endTime(0), to: endTime(100)) == events)
        #expect(HistoryEvent.merged(events, within: 5) == events)
        #expect(Set(events.map(\.id)).count == 2)
        let session = RecordingSession(id: 1, start: endTime(0), end: endTime(100), note: "End actions")
        let machine = RecordingMachine(modelIdentifier: "TestMac", modelName: nil, chip: "Test", memory: 1_024,
                                       macOSVersion: "14", macOSBuild: nil)
        let recording = RecordingFile(session: session, machine: machine, generator: "Tests", exported: endTime(100),
                                      records: [], events: events)
        let reopened = try RecordingFile.decode(recording.encoded())
        #expect(reopened.events == events)
    }
}

struct ProcessEndingRecorderTests {
    @Test func keepsTheLastSightingSeparateFromTheObservedEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("otm-end-span-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try FlightRecorder(url: directory.appendingPathComponent("history.sqlite"))
        let lifetime = endedLifetime()
        let start = ProcessHistoryBatch.Start(identity: lifetime.identity, name: lifetime.name, path: lifetime.path, user: "me",
                                               isRestricted: false, firstSeen: endTime(1))
        try await recorder.append(ProcessHistoryBatch(time: endTime(10), started: [start]))
        try await recorder.append(ProcessHistoryBatch(time: endTime(50)))
        let end = ProcessHistoryBatch.End(identity: lifetime.identity, time: endTime(60), isEnded: true, lastSeen: endTime(59))
        try await recorder.append(ProcessHistoryBatch(time: endTime(60), ended: [end]))
        try await recorder.append(ProcessHistoryBatch(time: endTime(100)))
        let saved = try #require(try await recorder.processLifetime(lifetime.identity))
        #expect(saved.lastSeen == endTime(59))
        #expect(saved.ended == endTime(60))
        let ending = try await recorder.processEnding(saved, reportFolders: [])
        #expect(ending.words { String(Int($0.timeIntervalSince(endStart))) }
            == ["Ended between 59 and 60; no crash report or exit status was found"])
    }

    @Test func migrationKeepsOldEventsAndAllowsSameNamedEndActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("otm-end-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let original = try FlightRecorder(url: url)
        let old = HistoryEvent(time: endTime(10), kind: .appQuit, name: "Worker", detail: "local.worker")
        try await original.append([old])
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
            DROP INDEX events_once;
            CREATE UNIQUE INDEX events_once ON events (kind, name, CAST(time AS INTEGER));
            PRAGMA user_version = 7;
            """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        let reader = try FlightRecorder(reading: url)
        #expect(try await reader.events(from: endTime(0), to: endTime(100)) == [old])
        let migrated = try FlightRecorder(url: url)
        #expect(try await migrated.schemaVersionOnDisk() == FlightRecorder.schemaVersion)
        let events = [42, 43].map { pid in
            HistoryEvent.endedByApp(time: endTime(55), name: "Worker",
                action: ProcessEndAction(identity: ProcessIdentity(pid: Int32(pid), startTime: endStart), path: nil, signal: 9))
        }
        try await migrated.append(events)
        #expect(try await migrated.events(from: endTime(0), to: endTime(100)) == [old] + events)
    }

    @Test func launchdDerivationKeepsIdentityOnlyForAnObservedProcessEnd() {
        let key = LaunchHistoryKey(label: "local.worker", domain: "gui/501")
        let before = LaunchHistorySnapshot(key: key, time: endTime(30),
                                          job: LaunchJobStatus(label: key.label, pid: 42, lastExit: nil), started: endStart)
        let stopped = LaunchHistorySnapshot(key: key, time: endTime(90),
                                           job: LaunchJobStatus(label: key.label, pid: nil, lastExit: .code(1)))
        let exit = LaunchHistoryDerivation.events(from: before, to: stopped).first { $0.kind == .exited }
        #expect(exit?.exitedIdentity == endedLifetime().identity)
        let replacement = LaunchHistorySnapshot(key: key, time: endTime(90),
                                                job: LaunchJobStatus(label: key.label, pid: 43, lastExit: .code(1)), started: endTime(70))
        let replaced = LaunchHistoryDerivation.events(from: before, to: replacement).first { $0.kind == .exited }
        #expect(replaced?.exitedIdentity == nil)
        #expect(ProcessEnding(lifetime: endedLifetime(), launchEvents: [replaced].compactMap { $0 }).evidence.isEmpty)
    }
}
