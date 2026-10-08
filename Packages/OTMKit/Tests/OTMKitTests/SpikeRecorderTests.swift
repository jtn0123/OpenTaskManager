import Foundation
@testable import OTMKit
import Testing

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_791_369_600 + seconds) }

private let machine = RecordingMachine(modelIdentifier: "Mac17,8", modelName: "MacBook Pro (16-inch, M5 Pro)", chip: "Apple M5 Pro",
                                       memory: 32 << 30, macOSVersion: "27.2", macOSBuild: "26B5101f")

private func sample(_ seconds: Double, cpu: Double = 0.1, interval: Double = 1, disk: Double = 0,
                    pressure: MemoryPressure = .normal) -> SpikeSample {
    var sample = SpikeSample(time: date(seconds), interval: interval)
    sample.cpu = cpu
    sample.memory = 0.5
    sample.memoryPressure = pressure == .normal ? 0.3 : 0.75
    sample.pressure = pressure
    sample.diskWrite = disk
    sample.networkIn = 1_000
    return sample
}

private func process(_ pid: Int32, _ name: String, cpu: Double = 0, memory: UInt64 = 0, disk: Double = 0,
                     started: Double? = 0) -> ProcessSample {
    ProcessSample(
        pid: pid, parentPID: 1, responsiblePID: pid, uid: 501, userName: "me", name: name, executablePath: nil,
        state: .running, nice: 0, startTime: started.map(date), isTranslated: false, isRestricted: false,
        cpuPercent: cpu, cpuTime: 0, memory: memory, residentMemory: memory, threadCount: 1,
        diskReadRate: disk / 4, diskWriteRate: disk * 3 / 4, diskReadTotal: 0, diskWriteTotal: 0
    )
}

/// Feeds one update a second from `from` to `to`, returning the captures handed off.
private func feed(_ recorder: inout SpikeRecorder, from: Double, to: Double, processes: [ProcessSample] = [],
                  cores: Int = 4, _ make: (Double) -> SpikeSample) -> [SpikeCapture] {
    stride(from: from, through: to, by: 1).compactMap { recorder.add(make($0), processes: processes, logicalCores: cores) }
}

struct SpikeRecorderTests {
    // MARK: The ring

    @Test func theRingHoldsItsCapacityAndNoMore() {
        var recorder = SpikeRecorder(capacity: 5)
        #expect(feed(&recorder, from: 1, to: 8) { sample($0) }.isEmpty)
        #expect(recorder.count == 5)
        recorder.force(.cpu, after: 0)
        let capture = recorder.add(sample(9), processes: [], logicalCores: 4)
        #expect(capture?.moments.map(\.sample.time) == [5, 6, 7, 8, 9].map(date))
    }

    @Test func keepsEachUpdatesBusiestProcessesHighestFirst() throws {
        var recorder = SpikeRecorder()
        let processes = [
            process(1, "a", cpu: 5, memory: 100, disk: 10), process(2, "b", cpu: 50, memory: 900),
            process(3, "c", cpu: 0, memory: 50_000, disk: 40), process(4, "d", cpu: 20, memory: 300, disk: 20),
            process(5, "e", cpu: 70, memory: 0), process(6, "f", cpu: 10, memory: 400, disk: 30),
            process(7, "g", cpu: 30, memory: 200, disk: 5), process(8, "h", cpu: 30, memory: 800),
        ]
        recorder.force(.cpu, after: 0)
        let handed = recorder.add(sample(1), processes: processes, logicalCores: 4)
        let capture = try #require(handed)
        let moment = try #require(capture.moments.last)
        // A tie keeps the order the list gave; an idle process is left out.
        #expect(moment.topCPU.map(\.name) == ["e", "b", "g", "h", "d"])
        #expect(moment.topCPU.map(\.value) == [70, 50, 30, 30, 20])
        #expect(moment.topMemory.map(\.name) == ["c", "b", "h", "f", "d"])
        #expect(moment.topDisk.map(\.name) == ["c", "f", "d"])
        #expect(moment.topDisk.map(\.value) == [40, 30, 20])
        #expect(moment.topCPU[0].identity == ProcessIdentity(pid: 5, startTime: date(0)))
    }

    @Test func aSlotReusedKeepsOnlyItsOwnProcesses() throws {
        var recorder = SpikeRecorder(capacity: 2)
        let busy = (1...6).map { process($0, "busy \($0)", cpu: Double($0) * 10, memory: 100, disk: 100) }
        _ = feed(&recorder, from: 1, to: 2, processes: busy) { sample($0) }
        recorder.force(.cpu, after: 0)
        let handed = recorder.add(sample(3), processes: [process(9, "alone", cpu: 1)], logicalCores: 4)
        let capture = try #require(handed)
        #expect(capture.moments.count == 2)
        #expect(capture.moments[0].topCPU.count == 5)
        #expect(capture.moments[1].topCPU.map(\.name) == ["alone"])
        #expect(capture.moments[1].topMemory.isEmpty && capture.moments[1].topDisk.isEmpty)
    }

    // MARK: Captures

    @Test func aCaptureRunsFromBeforeTheTriggerToAMinuteAfter() throws {
        var recorder = SpikeRecorder(before: 20, after: 10)
        let worker = process(42, "yes", cpu: 100)
        #expect(feed(&recorder, from: 1, to: 30) { sample($0) }.isEmpty)
        #expect(feed(&recorder, from: 31, to: 44, processes: [worker]) { sample($0, cpu: 0.95) }.isEmpty)
        #expect(recorder.capturing == .cpu)
        #expect(feed(&recorder, from: 45, to: 49) { sample($0) }.isEmpty)
        let handed = recorder.add(sample(50), processes: [], logicalCores: 4)
        let capture = try #require(handed)
        #expect(recorder.capturing == nil)
        // Twenty seconds before the trigger at 40, ten after it.
        #expect(capture.moments.first?.sample.time == date(21))
        #expect(capture.moments.last?.sample.time == date(50))
        #expect(capture.moments.count == 30)
        #expect(capture.start == date(20) && capture.end == date(50))
        #expect(capture.recordSeconds == 1)
        #expect(capture.cleared == date(44))

        let incident = capture.incident
        #expect(incident.kind == .cpu)
        #expect(incident.start == date(30) && incident.end == date(44))
        #expect(!incident.ongoing)
        #expect(abs(incident.average - 0.95) < 1e-9)
        #expect(incident.peak == 0.95)
        #expect(incident.headline == "CPU at 95% for 14 s")
        let contributor = try #require(incident.contributors.first)
        #expect(contributor.name == "yes")
        #expect(contributor.measure == .cpu)
        #expect(contributor.average == 100)
        // One core of four, at 95% busy: a little over a quarter of the CPU time.
        #expect(abs((contributor.share ?? 0) - 100 / 380) < 1e-9)
        #expect(contributor.figureText == "26% of the CPU time")
        #expect(feed(&recorder, from: 51, to: 200) { sample($0) }.isEmpty)
    }

    @Test func aConditionStillGoingIsOngoing() throws {
        var recorder = SpikeRecorder(before: 20, after: 60)
        let captures = feed(&recorder, from: 1, to: 200) { sample($0, cpu: 0.9) }
        let capture = try #require(captures.first)
        #expect(captures.count == 1)
        #expect(capture.cleared == nil)
        #expect(capture.incident.ongoing)
        #expect(capture.incident.end == date(70))
        #expect(capture.incident.headline == "CPU at 90% for 1 min+")
    }

    @Test func otherKindsThatCrossJoinTheCapture() throws {
        var recorder = SpikeRecorder(before: 20, after: 30)
        _ = feed(&recorder, from: 1, to: 39) { sample($0, cpu: $0 > 30 ? 0.95 : 0.1) }
        let captures = feed(&recorder, from: 40, to: 80) { sample($0, cpu: 0.95, pressure: $0 >= 45 ? .critical : .normal) }
        let capture = try #require(captures.first)
        #expect(captures.count == 1)
        #expect(capture.triggers.map(\.kind) == [.cpu, .memory])
        #expect(capture.incident.triggers.count == 2)
        // Memory pressure's own trigger has had its capture, inside the CPU's.
        #expect(feed(&recorder, from: 81, to: 200) { sample($0, cpu: 0.95, pressure: .critical) }.isEmpty)
    }

    @Test func aReusedPIDIsAnotherProcess() throws {
        var recorder = SpikeRecorder(before: 5, after: 5)
        let first = process(42, "worker", cpu: 100, started: 0)
        let second = process(42, "worker", cpu: 100, started: 15)
        _ = feed(&recorder, from: 1, to: 14, processes: [first]) { sample($0, cpu: 0.9) }
        let captures = feed(&recorder, from: 15, to: 30, processes: [second]) { sample($0, cpu: 0.9) }
        let capture = try #require(captures.first)
        let workers = capture.incident.contributors.filter { $0.name == "worker" }
        #expect(workers.count == 2)
        #expect(Set(workers.map(\.identity)) == [ProcessIdentity(pid: 42, startTime: date(0)), ProcessIdentity(pid: 42, startTime: date(15))])
    }

    @Test func memoryCapturesNameTheLargestFootprints() throws {
        var recorder = SpikeRecorder(before: 10, after: 5)
        let processes = [process(1, "small", cpu: 90, memory: 1 << 20), process(2, "big", memory: 8 << 30)]
        _ = feed(&recorder, from: 1, to: 10, processes: processes) { sample($0) }
        let capture = try #require(feed(&recorder, from: 11, to: 20, processes: processes) { sample($0, pressure: .warning) }.first)
        let incident = capture.incident
        #expect(incident.kind == .memory)
        #expect(incident.level == "warning")
        #expect(incident.contributors.map(\.name) == ["big", "small"])
        #expect(incident.contributors[0].share == nil)
        #expect(incident.contributors[0].figureText == "8.00 GB at most")
        #expect(incident.headline == "Memory pressure reached warning for 6 s+")
    }

    @Test func diskCapturesNameTheBusiestDiskUsers() throws {
        var thresholds = SpikeThresholds()
        thresholds.warmUp = 5
        var recorder = SpikeRecorder(thresholds: thresholds, before: 10, after: 15)
        let quiet = [process(1, "idle", disk: 1_000)]
        let busy = [process(1, "idle", disk: 1_000), process(2, "copier", cpu: 40, disk: 150_000_000)]
        _ = feed(&recorder, from: 1, to: 20, processes: quiet) { sample($0, disk: 1_000) }
        let capture = try #require(feed(&recorder, from: 21, to: 60, processes: busy) { sample($0, disk: 150_001_000) }.first)
        let incident = capture.incident
        #expect(incident.kind == .disk)
        #expect(incident.contributors.first?.name == "copier")
        #expect(incident.contributors.first?.measure == .disk)
        #expect(abs((incident.contributors.first?.share ?? 0) - 150_000_000 / 150_001_000) < 1e-9)
    }

    @Test func quietUpdatesNeverCapture() {
        var recorder = SpikeRecorder()
        #expect(feed(&recorder, from: 1, to: 2_000, processes: [process(1, "a", cpu: 50)]) { sample($0) }.isEmpty)
        #expect(recorder.capturing == nil)
    }

    @Test func aPausePastItsEndHandsTheCaptureOffAsItStood() throws {
        var recorder = SpikeRecorder(before: 20, after: 30)
        _ = feed(&recorder, from: 1, to: 15) { sample($0, cpu: 0.95) }
        #expect(recorder.capturing == .cpu)
        // Asleep from 15 to 300.
        let handed = recorder.add(sample(300, interval: 285), processes: [], logicalCores: 4)
        let capture = try #require(handed)
        #expect(capture.moments.last?.sample.time == date(15))
        #expect(capture.incident.ongoing)
        #expect(recorder.capturing == nil)
    }

    @Test func theClockGoingBackwardsHandsOffAndStartsAfresh() throws {
        var recorder = SpikeRecorder(before: 20, after: 30)
        _ = feed(&recorder, from: 100, to: 115) { sample($0, cpu: 0.95) }
        let handed = recorder.add(sample(50), processes: [], logicalCores: 4)
        let capture = try #require(handed)
        #expect(capture.moments.first?.sample.time == date(100))
        #expect(recorder.count == 1)
    }

    @Test func resetForgetsEverything() {
        var recorder = SpikeRecorder(before: 20, after: 30)
        _ = feed(&recorder, from: 1, to: 15) { sample($0, cpu: 0.95) }
        recorder.reset()
        #expect(recorder.count == 0 && recorder.capturing == nil)
        #expect(!recorder.triggers.isActive(.cpu))
    }

    @Test func aForcedCaptureEndsWhenAsked() throws {
        var recorder = SpikeRecorder()
        _ = feed(&recorder, from: 1, to: 15) { sample($0) }
        recorder.force(.network, after: 10)
        #expect(feed(&recorder, from: 16, to: 25) { sample($0) }.isEmpty)
        let handed = recorder.add(sample(26), processes: [], logicalCores: 4)
        let capture = try #require(handed)
        #expect(capture.triggers.map(\.kind) == [.network])
        #expect(capture.moments.count == 26)
    }

    // MARK: Files

    private func capture() throws -> SpikeCapture {
        var recorder = SpikeRecorder(before: 20, after: 10)
        let workers = [process(42, "yes", cpu: 100, memory: 1_000), process(43, "yes", cpu: 80, memory: 2_000, started: 1),
                       process(7, "WindowServer", cpu: 5, memory: 900_000_000)]
        _ = feed(&recorder, from: 1, to: 30, processes: workers) { sample($0) }
        return try #require(feed(&recorder, from: 31, to: 60, processes: workers) { sample($0, cpu: 0.95) }.first)
    }

    @Test func aCaptureIsARecordingOfOneSecondRecords() throws {
        let capture = try capture()
        let launched = HistoryEvent(time: date(25), kind: .appLaunched, name: "Xcode")
        let outside = HistoryEvent(time: date(2), kind: .appQuit, name: "Mail")
        let file = capture.recording(machine: machine, generator: "OpenTaskManager 0.1.0", exported: date(100),
                                     events: [launched, outside])
        #expect(file.records.count == capture.moments.count)
        #expect(file.recordSeconds == 1)
        #expect(file.session.start == capture.start && file.session.end == capture.end)
        // Busy from 30, the trigger at 40, still busy when the capture ends at 50.
        #expect(file.session.note == "CPU at 95% for 20 s+")
        #expect(file.incident == capture.incident)
        #expect(file.events.map(\.kind) == [.appLaunched, .spike])
        #expect(file.events.last?.name == "CPU")
        #expect(file.events.last?.detail == "95% of the whole CPU for 10 s")
        // A pressure kind is a word in the event's name, and named in full in its detail.
        let pressure = SpikeTrigger(kind: .memory, time: date(40), since: date(39), figure: 0.6, threshold: 0, level: "warning")
        #expect(pressure.event.name == "Memory")
        #expect(pressure.event.detail == "Memory pressure reached warning")
        // Same-named processes are one app in the records, as in the flight recorder.
        #expect(file.records.last?.topCPU == [HistoryApp(name: "yes", value: 180), HistoryApp(name: "WindowServer", value: 5)])
        #expect(file.records.last?.values.cpuPeak == 0.95)
    }

    @Test func roundTripsTheIncidentAndListsWithoutTheRecords() throws {
        let file = try capture().recording(machine: machine, generator: "OpenTaskManager 0.1.0", exported: date(100))
        let data = try file.encoded()
        let decoded = try RecordingFile.decode(data)
        #expect(decoded == file)
        #expect(decoded.incident?.contributors.map(\.name) == ["yes", "yes", "WindowServer"])
        let summary = try RecordingFile.summary(data)
        #expect(summary.session == decoded.session)
        #expect(summary.incident == file.incident)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let incident = try #require(object["incident"] as? [String: Any])
        #expect(incident["version"] as? Int == RecordingFile.incidentVersion)
        #expect((object["units"] as? [String: String])?["incident"] != nil)
        #expect((object["sampling"] as? [String: Any])?["recordSeconds"] as? Double == 1)
    }

    @Test func aRecordingWithoutAnIncidentWritesNone() throws {
        let file = RecordingFile(session: RecordingSession(start: date(0), end: date(10)), machine: machine, generator: "test",
                                 exported: date(20), records: [HistoryRecord(time: date(10), values: HistoryValues())])
        let object = try #require(try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        #expect(object["incident"] == nil)
        #expect(try RecordingFile.summary(try file.encoded()).incident == nil)
    }

    @Test func skipsANewerIncidentBlockButKeepsTheRecording() throws {
        let file = try capture().recording(machine: machine, generator: "test", exported: date(100))
        var object = try #require(try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        var incident = try #require(object["incident"] as? [String: Any])
        incident["version"] = RecordingFile.incidentVersion + 1
        object["incident"] = incident
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try RecordingFile.decode(data)
        #expect(decoded.incident == nil)
        #expect(decoded.records == file.records)
        #expect(try RecordingFile.summary(data).incident == nil)
    }

    @Test func skipsAnIncidentOfAKindThisBuildDoesntKnow() throws {
        let file = try capture().recording(machine: machine, generator: "test", exported: date(100))
        var object = try #require(try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        var incident = try #require(object["incident"] as? [String: Any])
        var triggers = try #require(incident["triggers"] as? [[String: Any]])
        var extra = triggers[0]
        extra["kind"] = "battery"
        incident["triggers"] = triggers + [extra]
        object["incident"] = incident
        // A later trigger of an unknown kind is left out...
        #expect(try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object)).incident?.triggers.count == 1)
        // ...and an incident started by one is skipped whole.
        triggers[0]["kind"] = "battery"
        incident["triggers"] = triggers
        object["incident"] = incident
        #expect(try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object)).incident == nil)
    }

    @Test func aCaptureReadsAsAnyRecordingWithoutItsIncident() throws {
        // What a build from before captures sees: every key it knows, the same records.
        let file = try capture().recording(machine: machine, generator: "test", exported: date(100))
        var object = try #require(try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let record = try #require((object["records"] as? [[String: Any]])?.first)
        #expect(Set(record.keys) == [
            "time", "cpu", "cpuPeak", "memory", "memoryPressure", "swapUsed", "gpu", "systemWatts", "cpuWatts", "gpuWatts",
            "diskRead", "diskWrite", "networkIn", "networkOut", "chipCelsius", "topCPU", "topMemory",
        ])
        object["incident"] = nil
        let older = try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object))
        #expect(older.records == file.records)
        #expect(older.events.count == file.events.count)
        #expect(older.incident == nil)
    }

    @Test func replaysACaptureAtOneSecondARecord() async throws {
        let file = try RecordingFile.decode(try capture().recording(machine: machine, generator: "test", exported: date(100)).encoded())
        let recorder = try FlightRecorder(replaying: file, from: URL(fileURLWithPath: "/never/written.otmrecording"))
        #expect(recorder.recordSpan == 1)
        let session = file.session
        let step = FlightRecorder.bucket(for: session.duration, record: recorder.recordSpan)
        #expect(step == 1)
        let points = try await recorder.points(from: session.start, to: session.end, bucket: step)
        #expect(points.count == file.records.count)
        #expect(Set(points.map(\.segment)) == [0])
        #expect(try await recorder.recordedSeconds(from: session.start, to: session.end) == Double(file.records.count))
        let stats = try await recorder.stats(from: session.start, to: session.end)
        #expect(stats.sampledSeconds == Double(file.records.count))
        let events = try await recorder.events(from: session.start, to: session.end)
        #expect(events.map(\.kind) == [.spike])
    }

    @Test func bucketsGoInWholeRecordsOfTheRecordingsLength() {
        #expect(FlightRecorder.bucket(for: 180, record: 1) == 1)
        #expect(FlightRecorder.bucket(for: 3_600, record: 1) == 10)
        #expect(FlightRecorder.bucket(for: 3_600) == 10)
        #expect(FlightRecorder.bucket(for: 0, record: 1) == 1)
        #expect(FlightRecorder.bucket(for: 600, record: 0) == 10)
    }

    @Test func aLiveRecorderKeepsTenSecondRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = try FlightRecorder(url: folder.appendingPathComponent("history.sqlite"))
        #expect(recorder.recordSpan == FlightRecorder.span)
    }
}
