import Foundation
@testable import OTMKit
import Testing

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_791_369_600 + seconds) }

private let machine = RecordingMachine(modelIdentifier: "VirtualMac2,1", modelName: nil, chip: "Apple M5 Pro (Virtual)",
                                       memory: 8 << 30, macOSVersion: "27.2", macOSBuild: nil)

/// A capture file of `kind` whose trigger is at `trigger` seconds.
private func captureFile(_ kind: SpikeKind = .cpu, at trigger: Double, records: Int = 3) -> RecordingFile {
    let primary = SpikeTrigger(kind: kind, time: date(trigger), since: date(trigger - 10), figure: 0.9, threshold: 0.8)
    let incident = SpikeIncident(triggers: [primary], start: date(trigger - 10), end: date(trigger + 5), ongoing: false,
                                 average: 0.9, peak: 0.97)
    let times = (0..<records).map { date(trigger - Double(records) + Double($0) + 1) }
    return RecordingFile(session: RecordingSession(start: date(trigger - Double(records)), end: date(trigger), note: incident.headline),
                         machine: machine, generator: "test", exported: date(trigger + 60), recordSeconds: 1,
                         records: times.map { HistoryRecord(time: $0, values: HistoryValues()) }, incident: incident)
}

private struct Scratch {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-captures-\(UUID().uuidString)", isDirectory: true)

    func library(count: Int = SpikeCaptureLibrary.keptCount, bytes: Int64 = SpikeCaptureLibrary.keptBytes) -> SpikeCaptureLibrary {
        SpikeCaptureLibrary(directory: folder, keptCount: count, keptBytes: bytes)
    }

    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Marks a file as written `seconds` into 2001, long before anything
    /// saved now, so pruning order doesn't hang on the clock's resolution.
    func written(_ url: URL, at seconds: Double) throws {
        let when = Date(timeIntervalSince1970: 1_000_000_000 + seconds)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

struct SpikeCaptureLibraryTests {
    @Test func namesACaptureByItsStartAndKind() {
        let utc = TimeZone(identifier: "UTC") ?? .current
        #expect(SpikeCaptureLibrary.name(start: Date(timeIntervalSince1970: 1_791_367_334), kind: .cpu, timeZone: utc)
            == "Spike 2026-10-07 at 10.02.14 CPU")
        #expect(SpikeCaptureLibrary.name(start: Date(timeIntervalSince1970: 1_791_367_334), kind: .memory, timeZone: utc)
            == "Spike 2026-10-07 at 10.02.14 Memory pressure")
        #expect(SpikeCaptureLibrary.name(start: Date(timeIntervalSince1970: 1_791_367_334), kind: nil, timeZone: utc)
            == "Spike 2026-10-07 at 10.02.14")
    }

    @Test func savesListsNewestFirstAndNumbersATakenName() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.library()
        let older = try library.save(captureFile(at: 100))
        let newer = try library.save(captureFile(.disk, at: 500))
        let again = try library.save(captureFile(at: 100))
        #expect(again.lastPathComponent == older.deletingPathExtension().lastPathComponent + " 2.otmrecording")
        #expect(older.pathExtension == "otmrecording")
        let entries = library.entries()
        #expect(entries.map(\.url.lastPathComponent).first == newer.lastPathComponent)
        #expect(entries.count == 3)
        #expect(entries[0].incident?.kind == .disk)
        #expect(entries[0].session.note == "Disk at 0 B/s for 15 s")
        #expect(entries.allSatisfy { $0.bytes > 0 })
        #expect(try RecordingFile.decode(try Data(contentsOf: newer)) == captureFile(.disk, at: 500))
    }

    @Test func keepsTheNewestCaptures() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let unlimited = scratch.library()
        var urls: [URL] = []
        for index in 0..<5 {
            let url = try unlimited.save(captureFile(at: Double(index) * 100))
            try scratch.written(url, at: Double(index))
            urls.append(url)
        }
        let deleted = scratch.library(count: 3).prune()
        #expect(Set(deleted.map(\.lastPathComponent)) == Set(urls.prefix(2).map(\.lastPathComponent)))
        #expect(scratch.names() == urls.suffix(3).map(\.lastPathComponent).sorted())
    }

    @Test func keepsWithinItsSpaceButAlwaysTheNewest() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let unlimited = scratch.library()
        let first = try unlimited.save(captureFile(at: 100, records: 50))
        try scratch.written(first, at: 1)
        let second = try unlimited.save(captureFile(at: 200, records: 50))
        try scratch.written(second, at: 2)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: second.path)[.size] as? Int64)
        // Room for one and a half: the older goes.
        #expect(scratch.library(bytes: size * 3 / 2).prune().map(\.lastPathComponent) == [first.lastPathComponent])
        // Room for none: the newest stays anyway.
        #expect(scratch.library(bytes: 1).prune().isEmpty)
        #expect(scratch.names() == [second.lastPathComponent])
    }

    @Test func savingPrunes() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.library(count: 2)
        for index in 0..<4 {
            let url = try library.save(captureFile(at: Double(index) * 100))
            try scratch.written(url, at: Double(index))
        }
        #expect(scratch.names().count == 2)
        #expect(library.entries().map(\.incident?.primary.time) == [date(300), date(200)])
    }

    @Test func findsTheSameSpikeCaughtByAnotherCopy() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.library()
        try library.save(captureFile(at: 1_000))
        #expect(library.hasCapture(of: .cpu, near: date(1_060), within: 120))
        #expect(!library.hasCapture(of: .cpu, near: date(1_200), within: 120))
        #expect(!library.hasCapture(of: .memory, near: date(1_000), within: 120))
    }

    @Test func leavesOutWhatItCantRead() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.library()
        try library.save(captureFile(at: 100))
        try Data("not json".utf8).write(to: scratch.folder.appendingPathComponent("broken.otmrecording"))
        try Data("{}".utf8).write(to: scratch.folder.appendingPathComponent("notes.txt"))
        var newer = try #require(try JSONSerialization.jsonObject(with: try captureFile(at: 200).encoded()) as? [String: Any])
        newer["version"] = RecordingFile.version + 1
        try JSONSerialization.data(withJSONObject: newer).write(to: scratch.folder.appendingPathComponent("future.otmrecording"))
        #expect(library.entries().count == 1)
        #expect(SpikeCaptureLibrary(directory: scratch.folder.appendingPathComponent("missing")).entries().isEmpty)
    }
}
