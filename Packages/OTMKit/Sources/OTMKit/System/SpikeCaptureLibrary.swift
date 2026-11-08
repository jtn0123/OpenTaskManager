import Foundation

/// A saved spike capture as the list of them shows it: its file, session
/// and incident, read without its records.
public struct SpikeCaptureEntry: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let session: RecordingSession
    /// Nil for a recording without an incident block, or with one this build can't read.
    public let incident: SpikeIncident?
    /// The file's size.
    public let bytes: Int64

    public init(url: URL, session: RecordingSession, incident: SpikeIncident?, bytes: Int64) {
        self.url = url
        self.session = session
        self.incident = incident
        self.bytes = bytes
    }
}

/// The spike captures on disk: one `.otmrecording` file each in a folder
/// beside the History page's recording, the newest `keptCount` kept as long
/// as together they take no more than `keptBytes` (the newest is always
/// kept), the oldest by when they were written deleted first.
public struct SpikeCaptureLibrary: Sendable {
    public static let keptCount = 20
    public static let keptBytes: Int64 = 100 * 1_048_576

    public let directory: URL
    public let keptCount: Int
    public let keptBytes: Int64

    public init(directory: URL = SpikeCaptureLibrary.defaultDirectory, keptCount: Int = SpikeCaptureLibrary.keptCount,
                keptBytes: Int64 = SpikeCaptureLibrary.keptBytes) {
        self.directory = directory
        self.keptCount = max(keptCount, 1)
        self.keptBytes = keptBytes
    }

    /// Application Support/OpenTaskManager/Captures.
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("OpenTaskManager/Captures", isDirectory: true)
    }

    // MARK: - Writing

    /// Writes `file` under a name from its start and incident ("Spike
    /// 2026-10-07 at 10.02.14 CPU.otmrecording", numbered if taken), then
    /// deletes the oldest captures beyond the limits.
    @discardableResult
    public func save(_ file: RecordingFile) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = Self.name(start: file.session.start, kind: file.incident?.kind)
        var url = directory.appendingPathComponent(base).appendingPathExtension(RecordingFile.fileExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(number)").appendingPathExtension(RecordingFile.fileExtension)
            number += 1
        }
        try file.encoded().write(to: url, options: .atomic)
        prune()
        return url
    }

    /// "Spike 2026-10-07 at 10.02.14 CPU", in this Mac's time zone.
    static func name(start: Date, kind: SpikeKind?, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Spike \(formatter.string(from: start))" + (kind.map { " \($0.label)" } ?? "")
    }

    /// Deletes the oldest captures, by when they were written, beyond
    /// `keptCount` or once the newer ones take `keptBytes`. Returns those deleted.
    @discardableResult
    public func prune() -> [URL] {
        var kept = 0
        var bytes: Int64 = 0
        var deleted: [URL] = []
        for file in files() {
            if kept == 0 || (kept < keptCount && bytes + file.bytes <= keptBytes) {
                kept += 1
                bytes += file.bytes
            } else if (try? FileManager.default.removeItem(at: file.url)) != nil {
                deleted.append(file.url)
            }
        }
        return deleted
    }

    /// Moves a capture to the Trash.
    public func delete(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Reading

    /// The captures this build can read, newest first by when they began.
    /// A file that isn't a recording, or is of a newer format, is left out.
    public func entries() -> [SpikeCaptureEntry] {
        files().compactMap { file in
            guard let data = try? Data(contentsOf: file.url), let summary = try? RecordingFile.summary(data) else { return nil }
            return SpikeCaptureEntry(url: file.url, session: summary.session, incident: summary.incident, bytes: file.bytes)
        }
        .sorted { $0.session.start == $1.session.start ? $0.url.path > $1.url.path : $0.session.start > $1.session.start }
    }

    /// Whether a capture of `kind` whose first trigger is within `within`
    /// seconds of `time` is already saved: another copy of the app running
    /// alongside caught the same spike.
    public func hasCapture(of kind: SpikeKind, near time: Date, within: TimeInterval) -> Bool {
        entries().contains { entry in
            guard let incident = entry.incident, incident.kind == kind else { return false }
            return abs(incident.primary.time.timeIntervalSince(time)) <= within
        }
    }

    /// A recording in the folder: its size, and when it was written.
    private struct StoredFile {
        let url: URL
        let bytes: Int64
        let written: Date
    }

    /// The recordings in the folder, newest written first.
    private func files() -> [StoredFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                   options: .skipsHiddenFiles)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == RecordingFile.fileExtension, let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return StoredFile(url: url, bytes: Int64(values.fileSize ?? 0), written: values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.written == $1.written ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.written > $1.written }
    }
}
