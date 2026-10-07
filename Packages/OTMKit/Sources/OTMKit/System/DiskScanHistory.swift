import Foundation

public enum DiskScanHistoryError: Error, Equatable {
    /// Not a summary, or one that doesn't hang together.
    case corrupt
    /// Written by a newer version of the app, in a format this one doesn't know.
    case newerVersion(Int)
}

/// Saved scan summaries, so the Storage page can say what grew since an
/// earlier scan. Each scope keeps its last `keptPerScope` scans as small
/// JSON files in a folder of its own, and only the `keptScopes` most
/// recently scanned scopes are kept, so the folder stays small however
/// many places get scanned.
public struct DiskScanHistory: Sendable {
    public static let keptPerScope = 10
    public static let keptScopes = 40

    public let folder: URL

    public init(folder: URL = DiskScanHistory.defaultFolder) {
        self.folder = folder
    }

    /// Next to the History page's recording.
    public static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("OpenTaskManager/Scans", isDirectory: true)
    }

    // MARK: - Writing

    /// Writes `summary`, then deletes its scope's oldest scans beyond
    /// `keptPerScope` and the least recently scanned scopes beyond `keptScopes`.
    @discardableResult
    public func save(_ summary: DiskScanSummary) throws -> URL {
        let scopeFolder = folder.appendingPathComponent(summary.scope.key, isDirectory: true)
        try FileManager.default.createDirectory(at: scopeFolder, withIntermediateDirectories: true)
        let url = scopeFolder.appendingPathComponent(Self.fileName(for: summary.scannedAt))
        try Self.encode(summary).write(to: url, options: .atomic)
        prune(scopeFolder)
        pruneScopes()
        return url
    }

    public static func encode(_ summary: DiskScanSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(summary)
    }

    /// Milliseconds since 1970, padded so names sort by time.
    static func fileName(for date: Date) -> String {
        let milliseconds = String(max(Int64(date.timeIntervalSince1970 * 1000), 0))
        return String(repeating: "0", count: max(15 - milliseconds.count, 0)) + milliseconds + ".json"
    }

    /// Deletes every scan saved for `scope`.
    public func forget(_ scope: DiskScanScope) throws {
        let scopeFolder = folder.appendingPathComponent(scope.key, isDirectory: true)
        guard FileManager.default.fileExists(atPath: scopeFolder.path) else { return }
        try FileManager.default.removeItem(at: scopeFolder)
    }

    private func prune(_ scopeFolder: URL) {
        for url in Self.scanFiles(in: scopeFolder).dropFirst(Self.keptPerScope) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func pruneScopes() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let scopes = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else {
            return
        }
        let folders = scopes.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard folders.count > Self.keptScopes else { return }
        let newestFirst = folders.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for url in newestFirst.dropFirst(Self.keptScopes) { try? fileManager.removeItem(at: url) }
    }

    // MARK: - Reading

    /// Every summary saved for `scope` that this version can read, newest
    /// first. Corrupt files, newer formats and other scopes are skipped.
    public func summaries(of scope: DiskScanScope) -> [DiskScanSummary] {
        let scopeFolder = folder.appendingPathComponent(scope.key, isDirectory: true)
        return Self.scanFiles(in: scopeFolder).compactMap { url in
            guard let data = try? Data(contentsOf: url), let summary = try? Self.decode(data), summary.scope == scope else { return nil }
            return summary
        }
    }

    public static func decode(_ data: Data) throws(DiskScanHistoryError) -> DiskScanSummary {
        struct Header: Decodable {
            let version: Int
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.version >= 1 else { throw .corrupt }
        guard header.version <= DiskScanSummary.currentVersion else { throw .newerVersion(header.version) }
        guard let summary = try? decoder.decode(DiskScanSummary.self, from: data), summary.isWellFormed else { throw .corrupt }
        return summary
    }

    /// A scope's files, newest first.
    private static func scanFiles(in scopeFolder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: scopeFolder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted(by: >).map { scopeFolder.appendingPathComponent($0) }
    }
}
