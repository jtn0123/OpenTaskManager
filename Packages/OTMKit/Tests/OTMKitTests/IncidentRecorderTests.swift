import Foundation
import Testing
@testable import OTMKit

struct IncidentRecorderTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
    }

    @Test func endingEvidenceLoadsOnlyTwentyLifetimes() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let identities = (0..<21).map { ProcessIdentity(pid: Int32(100 + $0), startTime: date(900)) }
        let starts = identities.map {
            ProcessHistoryBatch.Start(identity: $0, name: "Worker", path: nil, user: "other", isRestricted: false, firstSeen: date(900))
        }
        try await recorder.append(ProcessHistoryBatch(time: date(900), started: starts))
        let ends = identities.enumerated().map { index, identity in
            ProcessHistoryBatch.End(identity: identity, time: date(1_000 + Double(index)), isEnded: true, lastSeen: date(999))
        }
        try await recorder.append(ProcessHistoryBatch(time: date(1_030), ended: ends))
        let timeline = try await recorder.incident(.init(from: date(999), to: date(1_030)), reportFolders: [])
        let rows = try #require(timeline.lanes.first { $0.kind == .processes }?.rows)
        #expect(rows.count == 21)
        #expect(rows.filter { $0.ending != nil }.count == 20)
        #expect(rows.filter { $0.detail.contains("no crash report or exit status was found") }.count == 20)
        #expect(rows.filter { $0.detail.contains("Evidence not loaded") }.count == 1)
        let exported = String(decoding: try IncidentExport(timeline).json(), as: UTF8.self)
        #expect(!exported.contains("other"))
    }

    @Test func resourceBaselineGapsAndCPUSequenceUseRecordedFigures() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        var before = HistoryValues()
        before.cpu = 0.12
        before.cpuPeak = 0.15
        before.memory = 0.4
        before.memoryPressure = 0.25
        before.diskWrite = 1_024
        try await recorder.append(HistoryRecord(time: date(900), values: before))
        var during = before
        during.cpu = 0.85
        during.cpuPeak = 0.95
        during.memoryPressure = 0.5
        during.diskWrite = 2_048
        for second in [1_010.0, 1_020, 1_050, 1_060] {
            try await recorder.append(HistoryRecord(time: date(second), values: during, topCPU: [.init(name: "Worker", value: 120)]))
        }
        let timeline = try await recorder.incident(.init(from: date(1_000), to: date(1_060)), reportFolders: [])
        let resources = try #require(timeline.lanes.first { $0.kind == .resources })
        #expect(resources.coverage.state == .partly)
        #expect(resources.coverage.spans.count == 2)
        #expect(resources.rows.contains { $0.title == "CPU: 85.0% (was 12.0%)" })
        #expect(resources.rows.contains { $0.title.contains("Memory pressure: 50.0% (was 25.0%)") })
        #expect(timeline.sequences.contains { $0.label == "CPU rose while Worker was busiest" })
        #expect(timeline.lanes.first { $0.kind == .processes }?.coverage.state == IncidentCoverage.State.none)
    }

    @Test func launchDomainCoverageGapsAndInstanceIdentitySurviveRoundTrip() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let identity = ProcessIdentity(pid: 42, startTime: date(1_010))
        try await recorder.append(ProcessHistoryBatch(time: date(1_010), started: [
            .init(identity: identity, name: "Agent", path: nil, user: "me", isRestricted: false, firstSeen: date(1_010)),
        ]))
        let key = LaunchHistoryKey(label: "example.agent", domain: "system")
        try await recorder.observeLaunchJobs(.init(time: date(1_000), domains: ["system": [
            key.label: .init(label: key.label, pid: nil, lastExit: nil),
        ]]))
        try await recorder.observeLaunchJobs(.init(time: date(1_020), domains: ["system": [
            key.label: .init(label: key.label, pid: 42, lastExit: nil),
        ]]), starts: [42: date(1_010)])
        try await recorder.observeLaunchJobs(.init(time: date(1_200), domains: ["system": [
            key.label: .init(label: key.label, pid: 42, lastExit: nil),
        ]]), starts: [42: date(1_010)])
        let timeline = try await recorder.incident(.init(from: date(990), to: date(1_210)), reportFolders: [])
        let jobs = try #require(timeline.lanes.first { $0.kind == .jobs })
        let started = try #require(jobs.rows.first { $0.kind == "started" })
        #expect(started.process == identity)
        #expect(started.lifetime != nil)
        #expect(jobs.domains["system"]?.state == .partly)
        #expect(jobs.domains["system"]?.spans.count == 2)
        let other = try #require(jobs.domains.keys.first { $0 != "system" })
        #expect(jobs.domains[other]?.state == IncidentCoverage.State.none)
        let stored = try await recorder.launchJobEvents(label: key.label, from: date(1_000), to: date(1_100))
        #expect(stored.first { $0.kind == .started }?.observedIdentity == identity)
    }

    @Test func processWatchNeverBridgesMissingResourceRecords() async throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let identity = ProcessIdentity(pid: 7, startTime: date(900))
        try await recorder.append(ProcessHistoryBatch(time: date(1_000), started: [
            .init(identity: identity, name: "Agent", path: nil, user: "me", isRestricted: false, firstSeen: date(1_000)),
        ]))
        try await recorder.append(HistoryRecord(time: date(1_010), values: HistoryValues()))
        try await recorder.append(HistoryRecord(time: date(1_100), values: HistoryValues()))
        try await recorder.append(ProcessHistoryBatch(time: date(1_100)))
        let timeline = try await recorder.incident(.init(from: date(1_000), to: date(1_100)), reportFolders: [])
        let coverage = try #require(timeline.lanes.first { $0.kind == .processes }?.coverage)
        #expect(coverage.state == .partly)
        #expect(coverage.spans == [.init(start: date(1_000), end: date(1_010)), .init(start: date(1_090), end: date(1_100))])
    }

}
