import Foundation
@testable import OTMKit
import Testing

private let machine = RecordingMachine(modelIdentifier: "Mac17,8", modelName: "MacBook Pro (16-inch, M5 Pro)", chip: "Apple M5 Pro",
                                       memory: 32 << 30, macOSVersion: "27.2", macOSBuild: "26B5101f")

private func record(at seconds: Double, cpu: Double, gpu: Double? = nil, watts: Double? = nil) -> HistoryRecord {
    var values = HistoryValues()
    values.cpu = cpu
    values.cpuPeak = cpu + 0.05
    values.memory = 0.61
    values.memoryPressure = 0.2
    values.swapUsed = 1_048_576
    values.gpu = gpu
    values.systemWatts = watts
    values.diskRead = 2_000
    values.diskWrite = 12_345.5
    values.networkIn = 0
    values.networkOut = 98.25
    return HistoryRecord(time: Date(timeIntervalSince1970: seconds), values: values,
                         topCPU: [HistoryApp(name: "Xcode, \"beta\"", value: cpu * 100)],
                         topMemory: [HistoryApp(name: "Safari", value: 2_000_000_000)])
}

/// A session of five records with a ten-minute gap after the third.
private func sampleFile() -> RecordingFile {
    let base = 1_791_369_600.0
    let records = [10.0, 20, 30, 630, 640].map { record(at: base + $0, cpu: $0 / 1_000, watts: $0 == 20 ? nil : 6.5) }
    return RecordingFile(session: RecordingSession(start: Date(timeIntervalSince1970: base), end: Date(timeIntervalSince1970: base + 640),
                                                   note: "  Xcode build  "),
                         machine: machine, generator: "OpenTaskManager 0.1.0", exported: Date(timeIntervalSince1970: base + 700),
                         records: records)
}

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("otm-recording-\(UUID().uuidString)")
        .appendingPathComponent("history.sqlite")
}

struct RecordingFileTests {
    @Test func roundTripsEveryFieldExactly() throws {
        let file = sampleFile()
        let decoded = try RecordingFile.decode(try file.encoded())
        #expect(decoded == file)
        #expect(decoded.session.note == "Xcode build")
        #expect(decoded.machine.summary == "MacBook Pro (16-inch, M5 Pro) · Apple M5 Pro · 32 GB · macOS 27.2")
        #expect(decoded.records.map(\.time) == file.records.map(\.time))
        #expect(decoded.records[0].topCPU[0].name == "Xcode, \"beta\"")
    }

    @Test func keepsNotReportedApartFromZero() throws {
        let file = sampleFile()
        #expect(file.reported[.gpu] == false)
        #expect(file.reported[.systemWatts] == true)
        let json = try #require(String(data: try file.encoded(), encoding: .utf8))
        // Missing figures are written as null, and a real zero stays a zero.
        #expect(json.contains("\"gpu\":null"))
        #expect(json.contains("\"networkIn\":0"))
        #expect(json.contains("\"reported\":{"))
        #expect(json.contains("\"units\":{"))
        let decoded = try RecordingFile.decode(try file.encoded())
        #expect(decoded.records[1].values.systemWatts == nil)
        #expect(decoded.records[0].values.systemWatts == 6.5)
        #expect(decoded.records[0].values.networkIn == 0)
        #expect(decoded.records.allSatisfy { $0.values.gpu == nil })
    }

    @Test func writesItsFormatAndVersion() throws {
        let object = try JSONSerialization.jsonObject(with: try sampleFile().encoded()) as? [String: Any]
        #expect(object?["format"] as? String == RecordingFile.format)
        #expect(object?["version"] as? Int == RecordingFile.version)
        #expect((object?["sampling"] as? [String: Any])?["recordSeconds"] as? Double == 10)
    }

    @Test func refusesANewerVersion() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try sampleFile().encoded()) as? [String: Any])
        object["version"] = RecordingFile.version + 1
        // A newer version may change anything else, so it's refused before the rest is read.
        object["records"] = "rearranged in version 2"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RecordingFileError.unsupportedVersion(RecordingFile.version + 1)) { try RecordingFile.decode(data) }
        object["version"] = 0
        #expect(throws: RecordingFileError.unsupportedVersion(0)) {
            try RecordingFile.decode(try JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func refusesOtherJSON() {
        #expect(throws: RecordingFileError.notARecording) { try RecordingFile.decode(Data(#"{"name": "a shopping list"}"#.utf8)) }
        #expect(throws: RecordingFileError.notARecording) { try RecordingFile.decode(Data("[1, 2, 3]".utf8)) }
        #expect(throws: RecordingFileError.notARecording) {
            try RecordingFile.decode(Data(#"{"format": "something.else", "version": 1}"#.utf8))
        }
    }

    @Test func reportsACorruptFile() throws {
        let data = try sampleFile().encoded()
        // Cut short, as by a failed copy.
        #expect(throws: RecordingFileError.corrupt("it isn't valid JSON")) { try RecordingFile.decode(data.prefix(data.count / 2)) }
        #expect(throws: RecordingFileError.corrupt("it isn't valid JSON")) { try RecordingFile.decode(Data([0xFF, 0x00, 0x13])) }
        #expect(throws: RecordingFileError.corrupt("it isn't valid JSON")) { try RecordingFile.decode(Data()) }

        // The right header over a damaged body.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var records = try #require(object["records"] as? [[String: Any]])
        records[3].removeValue(forKey: "cpu")
        object["records"] = records
        let damaged = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RecordingFileError.corrupt("cpu is missing from records.#3")) { try RecordingFile.decode(damaged) }

        object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sampling"] = ["recordSeconds": -10]
        let nonsense = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RecordingFileError.self) { try RecordingFile.decode(nonsense) }
    }

    @Test func explainsEachErrorPlainly() {
        #expect(RecordingFileError.notARecording.errorDescription == "This file isn't an OpenTaskManager recording.")
        #expect(RecordingFileError.unsupportedVersion(3).errorDescription?.contains("format version 3") == true)
        #expect(RecordingFileError.corrupt("cut short").errorDescription?.contains("cut short") == true)
    }
}

struct RecordingSessionTests {
    @Test func ordersItsEndsAndHoldsRecordsUpToItsEnd() {
        let session = RecordingSession(start: Date(timeIntervalSince1970: 200), end: Date(timeIntervalSince1970: 100), note: "\n")
        #expect(session.start == Date(timeIntervalSince1970: 100))
        #expect(session.duration == 100)
        #expect(session.note.isEmpty)
        #expect(!session.contains(Date(timeIntervalSince1970: 100)))
        #expect(session.contains(Date(timeIntervalSince1970: 110)))
        #expect(session.contains(Date(timeIntervalSince1970: 200)))
        #expect(!session.contains(Date(timeIntervalSince1970: 201)))
    }

    @Test func savesListsAndDeletesSessions() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        let later = try await recorder.addSession(from: Date(timeIntervalSince1970: 5_000), to: Date(timeIntervalSince1970: 6_000), note: "Render")
        let earlier = try await recorder.addSession(from: Date(timeIntervalSince1970: 2_000), to: Date(timeIntervalSince1970: 1_000))
        #expect(later.id != earlier.id)
        #expect(try await recorder.sessions() == [earlier, later])
        try await recorder.deleteSession(earlier.id)
        // Sessions survive reopening, and pruning drops those that ended before the cut.
        let reopened = try FlightRecorder(url: url)
        #expect(try await reopened.sessions() == [later])
        try await reopened.prune(before: Date(timeIntervalSince1970: 7_000))
        #expect(try await reopened.sessions().isEmpty)
    }

    @Test func exportsOnlyTheSessionsRecords() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let recorder = try FlightRecorder(url: url)
        for seconds in [10.0, 20, 30, 40, 50] {
            try await recorder.append(record(at: 1_500_000 + seconds, cpu: 0.1, gpu: 0.3))
        }
        let session = try await recorder.addSession(from: Date(timeIntervalSince1970: 1_500_010),
                                                    to: Date(timeIntervalSince1970: 1_500_040), note: "Middle")
        let file = try await recorder.recording(of: session, machine: machine, generator: "test", exported: .distantPast)
        #expect(file.records.map(\.time.timeIntervalSince1970) == [1_500_020, 1_500_030, 1_500_040])
        #expect(file.session == session)
        #expect(file.reported[.gpu] == true)
        #expect(file.reported[.chipCelsius] == false)
        #expect(file.recordSeconds == FlightRecorder.span)
    }
}

struct RecordingReplayTests {
    @Test func replaysAFileWithItsGapsAndSession() async throws {
        let file = try RecordingFile.decode(try sampleFile().encoded())
        let url = URL(fileURLWithPath: "/tmp/never-written.otmrecording")
        let replay = try FlightRecorder(replaying: file, from: url)
        let session = file.session
        let points = try await replay.points(from: session.start, to: session.end, bucket: 10)
        #expect(points.count == 5)
        // The ten minutes nothing was recorded stay a gap.
        #expect(points.map(\.segment) == [0, 0, 0, 1, 1])
        #expect(points[1].values.systemWatts == nil)
        #expect(try await replay.recordedSeconds(from: session.start, to: session.end) == 50)
        #expect(try await replay.records(from: session.start, to: session.end) == file.records)
        let sessions = try await replay.sessions()
        #expect(sessions.map(\.note) == ["Xcode build"])
        #expect(replay.fileSize == 0)
    }
}

struct HistoryPlaybackTests {
    /// Points every ten seconds, with a gap of ten minutes after the fourth.
    private let points = HistoryPoint.segmented([0.0, 10, 20, 30, 630, 640, 650].map {
        HistoryPoint(time: Date(timeIntervalSince1970: $0), values: HistoryValues())
    }, gap: 25)

    private func step(_ current: Double?, speed: Double) -> HistoryPlayback.Step? {
        HistoryPlayback.step(after: current.map { Date(timeIntervalSince1970: $0) }, in: points, speed: speed)
    }

    @Test func startsOnTheFirstPointAtOnce() {
        #expect(step(nil, speed: 10) == HistoryPlayback.Step(time: Date(timeIntervalSince1970: 0), delay: 0))
        #expect(step(-500, speed: 10) == HistoryPlayback.Step(time: Date(timeIntervalSince1970: 0), delay: 0))
        #expect(HistoryPlayback.step(after: nil, in: [], speed: 1) == nil)
        #expect(step(nil, speed: 0) == nil)
    }

    @Test func keepsTheRecordingsPace() {
        #expect(step(0, speed: 1) == HistoryPlayback.Step(time: Date(timeIntervalSince1970: 10), delay: 10))
        #expect(step(0, speed: 10) == HistoryPlayback.Step(time: Date(timeIntervalSince1970: 10), delay: 1))
        // From a moment between points, the next point.
        #expect(step(15, speed: 10) == HistoryPlayback.Step(time: Date(timeIntervalSince1970: 20), delay: 0.5))
    }

    @Test func skipsPointsRatherThanStepFasterThanItsLimit() throws {
        // At 60×, ten seconds pass in a sixth of a second: too often, so a
        // step of half a second takes three points.
        let fast = try #require(step(0, speed: 60))
        #expect(fast.time == Date(timeIntervalSince1970: 30))
        #expect(fast.delay == HistoryPlayback.shortestStep)
        // But never skips over a gap: the last point before one is shown.
        #expect(step(20, speed: 60)?.time == Date(timeIntervalSince1970: 30))
        #expect(step(20, speed: 60)?.delay == HistoryPlayback.shortestStep)
    }

    @Test func crossesAGapInOneCappedJump() throws {
        let slow = try #require(step(30, speed: 1))
        #expect(slow.time == Date(timeIntervalSince1970: 630))
        #expect(slow.gap == 600)
        #expect(slow.delay == HistoryPlayback.longestGapWait)
        let fast = try #require(step(30, speed: 600))
        #expect(fast.time == Date(timeIntervalSince1970: 630))
        #expect(fast.delay == 1)
        // The step after the gap is an ordinary one.
        #expect(step(630, speed: 10)?.gap == nil)
    }

    @Test func stopsAtTheLastPoint() {
        #expect(step(650, speed: 10) == nil)
        #expect(step(9_999, speed: 10) == nil)
    }
}
