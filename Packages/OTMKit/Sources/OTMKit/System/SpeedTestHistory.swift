import Foundation

/// A speed-test result the history keeps: when it ran, what it measured
/// (an interface, a volume), and its format version.
public protocol SpeedTestRecord: Codable, Sendable {
    static var currentVersion: Int { get }
    var version: Int { get }
    var date: Date { get }
    var historyKey: String { get }
}

/// The last few results of one kind of speed test, per interface or volume,
/// in one small JSON file under Application Support/OpenTaskManager/SpeedTests.
/// The app and `otm` share it. Only the `keptKeys` most recently tested
/// interfaces or volumes are kept, so the file stays small.
public struct SpeedTestHistory<Record: SpeedTestRecord>: Sendable {
    public let file: URL
    public let keptPerKey: Int
    public let keptKeys: Int

    public init(file: URL, keptPerKey: Int = 5, keptKeys: Int = 20) {
        self.file = file
        self.keptPerKey = keptPerKey
        self.keptKeys = keptKeys
    }

    /// Next to the History page's recording and the Storage page's scans.
    public static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("OpenTaskManager/SpeedTests", isDirectory: true)
    }

    /// One result that may not decode, so a damaged or newer entry doesn't
    /// cost the rest of the file.
    private struct Lenient: Decodable {
        let record: Record?

        init(from decoder: any Decoder) throws {
            record = try? Record(from: decoder)
        }
    }

    /// Every result this version can read, newest first. A missing or
    /// unreadable file is an empty history.
    public func load() -> [Record] {
        guard let data = try? Data(contentsOf: file),
              let envelope = try? JSONDecoder().decode(SpeedTestFile<Lenient>.self, from: data) else { return [] }
        return envelope.results.compactMap(\.record)
            .filter { $0.version >= 1 && $0.version <= Record.currentVersion }
            .sorted { $0.date > $1.date }
    }

    /// The newest results for one interface or volume.
    public func results(for key: String) -> [Record] {
        load().filter { $0.historyKey == key }
    }

    /// Adds `record`, keeps the newest `keptPerKey` of its key and the
    /// `keptKeys` most recently tested keys, and returns what's kept.
    @discardableResult
    public func append(_ record: Record) throws -> [Record] {
        let kept = Self.pruned([record] + load(), perKey: keptPerKey, keys: keptKeys)
        try write(kept)
        return kept
    }

    /// Forgets one interface's or volume's results.
    @discardableResult
    public func forget(_ key: String) throws -> [Record] {
        let kept = load().filter { $0.historyKey != key }
        try write(kept)
        return kept
    }

    /// Newest first; each key's newest `perKey`, and only the `keys` keys
    /// tested most recently.
    static func pruned(_ records: [Record], perKey: Int, keys: Int) -> [Record] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        return records.sorted { $0.date > $1.date }.filter { record in
            let key = record.historyKey
            if counts[key] == nil {
                guard order.count < keys else { return false }
                order.append(key)
            }
            counts[key, default: 0] += 1
            return counts[key, default: 0] <= perKey
        }
    }

    private func write(_ records: [Record]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SpeedTestFile(results: records)).write(to: file, options: .atomic)
    }
}

/// The history file: a format version around the results.
private struct SpeedTestFile<Item> {
    var version = 1
    var results: [Item]
}

extension SpeedTestFile: Encodable where Item: Encodable {}
extension SpeedTestFile: Decodable where Item: Decodable {}

public extension SpeedTestHistory where Record == NetworkQualityResult {
    /// Internet quality results, per interface.
    static var networkQuality: Self {
        Self(file: defaultFolder.appendingPathComponent("network-quality.json"))
    }
}

public extension SpeedTestHistory where Record == DiskSpeedResult {
    /// Disk speed results, per volume.
    static var diskSpeed: Self {
        Self(file: defaultFolder.appendingPathComponent("disk-speed.json"))
    }
}
