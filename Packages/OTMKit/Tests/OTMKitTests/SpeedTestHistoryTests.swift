import Foundation
@testable import OTMKit
import Testing

private func result(_ interface: String, at time: TimeInterval, download: Double = 100_000_000) -> NetworkQualityResult {
    NetworkQualityResult(date: Date(timeIntervalSince1970: time), requestedInterface: interface, interface: interface,
                         downloadBitsPerSecond: download, uploadBitsPerSecond: 20_000_000, responsiveness: 800)
}

/// A history in a folder of the test's own, never the real one.
private func scratchHistory(perKey: Int = 3, keys: Int = 2) -> SpeedTestHistory<NetworkQualityResult> {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-speedhistory-\(UUID().uuidString)", isDirectory: true)
    return SpeedTestHistory(file: folder.appendingPathComponent("network-quality.json"), keptPerKey: perKey, keptKeys: keys)
}

struct SpeedTestHistoryTests {
    @Test func keepsTheNewestResultsPerInterface() throws {
        let history = scratchHistory()
        defer { try? FileManager.default.removeItem(at: history.file.deletingLastPathComponent()) }
        #expect(history.load().isEmpty)
        for time in 1...5 { try history.append(result("en0", at: TimeInterval(time))) }
        try history.append(result("en1", at: 6))

        let loaded = history.load()
        #expect(loaded.map(\.date.timeIntervalSince1970) == [6, 5, 4, 3])
        #expect(history.results(for: "en0").map(\.date.timeIntervalSince1970) == [5, 4, 3])
        #expect(history.results(for: "en1").count == 1)
    }

    @Test func keepsOnlyTheMostRecentlyTestedInterfaces() throws {
        let history = scratchHistory(perKey: 5, keys: 2)
        defer { try? FileManager.default.removeItem(at: history.file.deletingLastPathComponent()) }
        try history.append(result("en0", at: 1))
        try history.append(result("en1", at: 2))
        let kept = try history.append(result("en2", at: 3))
        #expect(Set(kept.map(\.historyKey)) == ["en1", "en2"])
        #expect(history.load() == kept)
    }

    @Test func forgetsOneInterface() throws {
        let history = scratchHistory()
        defer { try? FileManager.default.removeItem(at: history.file.deletingLastPathComponent()) }
        try history.append(result("en0", at: 1))
        try history.append(result("en1", at: 2))
        try history.forget("en0")
        #expect(history.load().map(\.historyKey) == ["en1"])
    }

    @Test func skipsWhatItCantRead() throws {
        let history = scratchHistory()
        let folder = history.file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try Data("not json".utf8).write(to: history.file)
        #expect(history.load().isEmpty)

        // A damaged entry and one from a newer version don't cost the rest.
        var newer = result("en0", at: 3)
        newer.version = NetworkQualityResult.currentVersion + 1
        let good = try JSONEncoder().encode(result("en0", at: 1))
        let file = "{\"version\":1,\"results\":[\(String(decoding: good, as: UTF8.self)),{\"date\":\"yesterday\"},"
            + "\(String(decoding: try JSONEncoder().encode(newer), as: UTF8.self))]}"
        try Data(file.utf8).write(to: history.file)
        #expect(history.load().map(\.date.timeIntervalSince1970) == [1])

        // Appending rewrites the file with only what it could read.
        try history.append(result("en0", at: 2))
        #expect(history.load().map(\.date.timeIntervalSince1970) == [2, 1])
    }

    @Test func pruningIsNewestFirst() {
        let records = [result("a", at: 1), result("b", at: 4), result("a", at: 3), result("c", at: 2), result("a", at: 5)]
        let pruned = SpeedTestHistory<NetworkQualityResult>.pruned(records, perKey: 2, keys: 2)
        #expect(pruned.map(\.date.timeIntervalSince1970) == [5, 4, 3])
    }

    @Test func storesUnderApplicationSupport() {
        #expect(SpeedTestHistory<NetworkQualityResult>.networkQuality.file.path.hasSuffix("OpenTaskManager/SpeedTests/network-quality.json"))
        #expect(SpeedTestHistory<DiskSpeedResult>.diskSpeed.file.path.hasSuffix("OpenTaskManager/SpeedTests/disk-speed.json"))
    }
}
