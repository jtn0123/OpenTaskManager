import Foundation
import SQLite3

public enum FlightRecorderError: Error, Equatable, LocalizedError {
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): "The recording's database reported an error: \(message)."
        }
    }
}

/// Keeps a stretch-by-stretch record of the whole system on disk, so the
/// History page can show what the Mac was doing hours or days ago, and which
/// apps were busy then.
///
/// Each row is one `HistoryRecord` (ten seconds by default). Graph points are
/// averaged by SQLite itself, so reading a week costs one grouped query
/// rather than loading tens of thousands of rows. Sessions, stretches the
/// user marked, and events (`HistoryEvent`: apps launched and quit, the
/// network changing) sit beside the records and are exported with them as
/// recording files; an opened file is replayed through an in-memory copy of
/// the same tables.
///
/// The database's `user_version` is its schema: 0, records and sessions;
/// 1 added the events table; 2 the hardware series (`HistoryHardwareSeries`:
/// core loads, clocks, fans, temperatures, power rails), named once each in
/// `hardware_series` and kept per record in a compact `hardware` column; 3
/// the process history (`process_lifetimes`, `process_watches` and
/// `process_samples`; see FlightRecorderProcesses). An older database is
/// brought up to date when it opens, and an older build still opens a newer
/// one: it never reads the tables and columns it doesn't know, and its
/// records simply have no hardware figures or process history.
public actor FlightRecorder {
    /// Seconds each record covers.
    public static let span: TimeInterval = 10
    /// Records older than this are deleted.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// The schema this build writes (`user_version`).
    static let schemaVersion: Int32 = 3

    private static let columns = [
        "cpu", "cpu_peak", "memory", "pressure", "swap", "gpu", "system_watts", "cpu_watts", "gpu_watts",
        "disk_read", "disk_write", "net_in", "net_out", "chip_celsius",
    ]

    /// Owns the SQLite connection and closes it when the recorder goes away.
    private final class Connection {
        let handle: OpaquePointer

        init(_ handle: OpaquePointer) {
            self.handle = handle
        }

        deinit {
            sqlite3_close(handle)
        }
    }

    /// The database file, or for a replayed recording the file it came from.
    public nonisolated let url: URL
    /// Seconds each of its records covers: `span` for the live recording,
    /// the file's own for a replayed one (one for a spike capture).
    public nonisolated let recordSpan: TimeInterval
    private let connection: Connection
    var database: OpaquePointer { connection.handle }
    private var lastPrune = Date.distantPast
    /// The hardware series this recorder has written, by ID.
    private let catalogue = HardwareCatalogue()
    /// This run's process history rows (`ProcessHistoryWriter`).
    let processWriter = ProcessHistoryWriter()

    /// Opens the recording at `url`, creating it and its folder if needed.
    public init(url: URL) throws(FlightRecorderError) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .sqlite(error.localizedDescription)
        }
        let connection = try Self.open(url.path)
        // Every running copy of the app writes here; wait for each other's writes.
        sqlite3_busy_timeout(connection.handle, 2_000)
        try Self.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;", on: connection.handle)
        try Self.createTables(on: connection.handle)
        self.url = url
        recordSpan = Self.span
        self.connection = connection
    }

    /// A read-only view of a recording file: its records and session in an
    /// in-memory database, so the History page reads it with the same
    /// queries as the live recording, at its own record length. `url` is
    /// the file it was read from.
    public init(replaying file: RecordingFile, from url: URL) throws(FlightRecorderError) {
        let connection = try Self.open(":memory:")
        try Self.createTables(on: connection.handle)
        try Self.execute("BEGIN", on: connection.handle)
        try Self.insert(file.records, into: connection.handle, catalogue: HardwareCatalogue())
        try Self.insert(file.session, into: connection.handle)
        try Self.insert(file.events, into: connection.handle)
        try Self.execute("COMMIT", on: connection.handle)
        self.url = url
        recordSpan = max(file.recordSeconds, 0.1)
        self.connection = connection
    }

    /// The recording at `url` to read, never written or migrated, as the
    /// `otm` tool reads the app's: it fails when there's no such file.
    public init(reading url: URL) throws(FlightRecorderError) {
        let connection = try Self.open(url.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
        sqlite3_busy_timeout(connection.handle, 2_000)
        self.url = url
        recordSpan = Self.span
        self.connection = connection
    }

    /// Where the app keeps its recording.
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("OpenTaskManager/history.sqlite")
    }

    // MARK: - Writing

    public func append(_ record: HistoryRecord) throws(FlightRecorderError) {
        try Self.insert([record], into: database, catalogue: catalogue)
        if record.time.timeIntervalSince(lastPrune) > 60 * 60 {
            try prune(before: record.time.addingTimeInterval(-Self.retention))
            lastPrune = record.time
        }
    }

    /// Saves events, in any order. One another copy of the app already
    /// saved (the same kind and name in the same second) is left out.
    public func append(_ events: [HistoryEvent]) throws(FlightRecorderError) {
        try Self.insert(events, into: database)
    }

    /// Deletes the records and events before `date`, and the sessions that ended before it.
    public func prune(before date: Date) throws(FlightRecorderError) {
        for sql in ["DELETE FROM records WHERE time < ?", "DELETE FROM sessions WHERE end_time < ?", "DELETE FROM events WHERE time < ?"] {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try step(statement)
        }
        if try keepsProcessHistory() { try pruneProcesses(before: date) }
    }

    // MARK: - Reading

    /// Graph points between two dates, each the average of the records in a
    /// bucket of `bucket` seconds, at least a record long (CPU peak is the
    /// highest). Empty buckets are left out, and `HistoryPoint.segment` marks the gaps.
    public func points(from start: Date, to end: Date, bucket: TimeInterval) throws(FlightRecorderError) -> [HistoryPoint] {
        let bucket = max(bucket, recordSpan)
        let averages = Self.columns.map { $0 == "cpu_peak" ? "MAX(cpu_peak)" : "AVG(\($0))" }.joined(separator: ", ")
        let statement = try prepare("""
            SELECT MAX(time), \(averages) FROM records WHERE time > ? AND time <= ?
            GROUP BY CAST(time / ? AS INTEGER) ORDER BY 1
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, bucket)
        var points: [HistoryPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let time = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            points.append(HistoryPoint(time: time, values: Self.values(statement, from: 1)))
        }
        return HistoryPoint.segmented(points, gap: bucket * HistoryGap.spacing)
    }

    /// Every record between two dates, oldest first, with its hardware series.
    public func records(from start: Date, to end: Date) throws(FlightRecorderError) -> [HistoryRecord] {
        let series = try HardwareCatalogue.load(on: database)
        let statement = try prepare("""
            SELECT time, \(Self.columns.joined(separator: ", ")), top_cpu, top_memory, hardware
            FROM records WHERE time > ? AND time <= ? ORDER BY time
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var records: [HistoryRecord] = []
        let apps = Int32(Self.columns.count + 1)
        while sqlite3_step(statement) == SQLITE_ROW {
            var values = Self.values(statement, from: 1)
            let hardware = HardwareBlob.read(statement, apps + 2, series: series, into: &values)
            records.append(HistoryRecord(
                time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                values: values,
                topCPU: Self.decode(statement, apps),
                topMemory: Self.decode(statement, apps + 1),
                hardwareSeries: hardware
            ))
        }
        return records
    }

    /// Seconds recorded between two dates. Each record covers `recordSpan`
    /// seconds; copies of the app running side by side write records for the
    /// same stretch, so each stretch counts once.
    public func recordedSeconds(from start: Date, to end: Date) throws(FlightRecorderError) -> TimeInterval {
        let statement = try prepare("SELECT COUNT(DISTINCT CAST(time / ? AS INTEGER)) FROM records WHERE time > ? AND time <= ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, recordSpan)
        sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(database))) }
        return Double(sqlite3_column_int64(statement, 0)) * recordSpan
    }

    /// Seconds per graph point for a graph `span` seconds wide: about
    /// `points` across, in whole records of `record` seconds, so every point
    /// averages the same number of them.
    public static func bucket(for span: TimeInterval, points: Int = 360, record: TimeInterval = FlightRecorder.span) -> TimeInterval {
        let record = record.isFinite && record > 0 ? record : Self.span
        guard span.isFinite, span > 0, points > 0 else { return record }
        let records = (span / Double(points) / record - 1e-9).rounded(.up)
        return max(records, 1) * record
    }

    /// The times of the first and last records between two dates, or nil
    /// when there are none: what the History page fits its graphs to.
    public func recordedSpan(from start: Date, to end: Date) throws(FlightRecorderError) -> ClosedRange<Date>? {
        let statement = try prepare("SELECT MIN(time), MAX(time) FROM records WHERE time > ? AND time <= ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))...Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
    }

    /// The figures between two dates summed up, gaps left out
    /// (`HistoryIntervalStats`). Reads the figures alone, not the top
    /// apps, so a week's records cost little.
    public func stats(from start: Date, to end: Date) throws(FlightRecorderError) -> HistoryIntervalStats {
        let series = try HardwareCatalogue.load(on: database)
        let statement = try prepare("""
            SELECT time, \(Self.columns.joined(separator: ", ")), hardware FROM records WHERE time > ? AND time <= ? ORDER BY time
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, min(start, end).timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, max(start, end).timeIntervalSince1970)
        var records: [HistoryRecord] = []
        var seen: Set<HistoryHardwareSeries> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var values = Self.values(statement, from: 1)
            seen.formUnion(HardwareBlob.read(statement, Int32(Self.columns.count + 1), series: series, into: &values))
            records.append(HistoryRecord(time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)), values: values))
        }
        return HistoryIntervalStats(records: records, from: start, to: end, recordSeconds: recordSpan, hardware: seen.sorted())
    }

    /// The hardware series between two dates as graph points' figures, each
    /// series and core averaged per bucket of `bucket` seconds over the
    /// records that have it, bucketed as `points` groups (`HistoryHardwareTrack`).
    /// Read only while the History page shows them.
    public func hardware(from start: Date, to end: Date, bucket: TimeInterval) throws(FlightRecorderError) -> HistoryHardwareTrack {
        let series = try HardwareCatalogue.load(on: database)
        let statement = try prepare(
            "SELECT time, hardware FROM records WHERE time > ? AND time <= ? AND hardware IS NOT NULL ORDER BY time"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var records: [HistoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var values = HistoryValues()
            HardwareBlob.read(statement, 1, series: series, into: &values)
            records.append(HistoryRecord(time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)), values: values))
        }
        let first = try prepare("SELECT time FROM records WHERE hardware IS NOT NULL ORDER BY time LIMIT 1")
        defer { sqlite3_finalize(first) }
        let earliest = sqlite3_step(first) == SQLITE_ROW ? Date(timeIntervalSince1970: sqlite3_column_double(first, 0)) : nil
        return HistoryHardwareTrack(records: records, series: Array(series.values), bucket: bucket, earliest: earliest, record: recordSpan)
    }

    /// The apps that used the most CPU between two dates, averaged over the
    /// records as `HistoryRecord.topApps` does (an app missing from a
    /// record's list counts as idle there), summed by SQLite rather than
    /// decoding every record's list.
    public func topCPU(from start: Date, to end: Date, count: Int) throws(FlightRecorderError) -> [HistoryApp] {
        let counting = try prepare("SELECT COUNT(*) FROM records WHERE time > ? AND time <= ?")
        defer { sqlite3_finalize(counting) }
        sqlite3_bind_double(counting, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(counting, 2, end.timeIntervalSince1970)
        guard sqlite3_step(counting) == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(database))) }
        let records = Double(sqlite3_column_int64(counting, 0))
        guard records > 0 else { return [] }
        let statement = try prepare("""
            SELECT json_extract(app.value, '$.n'), SUM(json_extract(app.value, '$.v'))
            FROM records, json_each(records.top_cpu) AS app WHERE records.time > ? AND records.time <= ? GROUP BY 1
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var totals: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = Self.text(statement, 0) else { continue }
            totals[name] = sqlite3_column_double(statement, 1) / records
        }
        return HistoryRecord.ranked(totals, count: count)
    }

    /// The events from `start` to `end`, both included, oldest first.
    public func events(from start: Date, to end: Date) throws(FlightRecorderError) -> [HistoryEvent] {
        let statement = try prepare("""
            SELECT time, kind, name, detail, count, approximate FROM events WHERE time >= ? AND time <= ? ORDER BY time, rowid
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var events: [HistoryEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // A kind from a newer build is left out rather than misread.
            guard let kind = Self.text(statement, 1).flatMap(HistoryEvent.Kind.init(rawValue:)) else { continue }
            events.append(HistoryEvent(
                time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)), kind: kind,
                name: Self.text(statement, 2) ?? "", detail: Self.text(statement, 3) ?? "",
                count: Int(sqlite3_column_int64(statement, 4)), isApproximate: sqlite3_column_int(statement, 5) != 0
            ))
        }
        return events
    }

    /// The oldest record kept, if any.
    public func earliest() throws(FlightRecorderError) -> Date? {
        let statement = try prepare("SELECT MIN(time) FROM records")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// Bytes on disk, including the write-ahead log.
    public nonisolated var fileSize: Int64 {
        [url.path, url.path + "-wal"].reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    // MARK: - Sessions

    /// Saves a stretch the user marked, with an optional note, and returns
    /// it with its ID.
    public func addSession(from start: Date, to end: Date, note: String = "") throws(FlightRecorderError) -> RecordingSession {
        let session = RecordingSession(start: start, end: end, note: note)
        try Self.insert(session, into: database)
        return RecordingSession(id: sqlite3_last_insert_rowid(database), start: session.start, end: session.end, note: session.note)
    }

    /// Every saved session, oldest first.
    public func sessions() throws(FlightRecorderError) -> [RecordingSession] {
        let statement = try prepare("SELECT id, start_time, end_time, note FROM sessions ORDER BY start_time, id")
        defer { sqlite3_finalize(statement) }
        var sessions: [RecordingSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            sessions.append(RecordingSession(
                id: sqlite3_column_int64(statement, 0),
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                note: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            ))
        }
        return sessions
    }

    /// Forgets a session. Its records stay until they age out.
    public func deleteSession(_ id: RecordingSession.ID) throws(FlightRecorderError) {
        let statement = try prepare("DELETE FROM sessions WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        try step(statement)
    }

    /// A recording file of `session`, made on `machine`. Its records and
    /// events are read in one transaction, so another copy of the app
    /// writing meanwhile can't tear the snapshot.
    public func recording(of session: RecordingSession, machine: RecordingMachine, generator: String,
                          exported: Date = .now) throws(FlightRecorderError) -> RecordingFile {
        try Self.execute("BEGIN", on: database)
        let records: [HistoryRecord]
        let events: [HistoryEvent]
        do throws(FlightRecorderError) {
            records = try self.records(from: session.start, to: session.end)
            events = try self.events(from: session.start, to: session.end)
            try Self.execute("COMMIT", on: database)
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return RecordingFile(session: session, machine: machine, generator: generator, exported: exported, records: records,
                             events: events)
    }

    // MARK: - Rows

    private static func row(_ values: HistoryValues) -> [Double?] {
        [values.cpu, values.cpuPeak, values.memory, values.memoryPressure, values.swapUsed, values.gpu,
         values.systemWatts, values.cpuWatts, values.gpuWatts, values.diskRead, values.diskWrite,
         values.networkIn, values.networkOut, values.chipCelsius]
    }

    private static func values(_ statement: OpaquePointer, from first: Int32) -> HistoryValues {
        func column(_ offset: Int32) -> Double? {
            sqlite3_column_type(statement, first + offset) == SQLITE_NULL ? nil : sqlite3_column_double(statement, first + offset)
        }
        var values = HistoryValues()
        values.cpu = column(0) ?? 0
        values.cpuPeak = column(1) ?? 0
        values.memory = column(2) ?? 0
        values.memoryPressure = column(3) ?? 0
        values.swapUsed = column(4) ?? 0
        values.gpu = column(5)
        values.systemWatts = column(6)
        values.cpuWatts = column(7)
        values.gpuWatts = column(8)
        values.diskRead = column(9) ?? 0
        values.diskWrite = column(10) ?? 0
        values.networkIn = column(11) ?? 0
        values.networkOut = column(12) ?? 0
        values.chipCelsius = column(13)
        return values
    }

    private static func encode(_ apps: [HistoryApp]) -> String {
        // Whole numbers keep the rows small; CPU keeps a tenth of a percent.
        let rounded = apps.map { HistoryApp(name: $0.name, value: ($0.value * 10).rounded() / 10) }
        return (try? JSONEncoder().encode(rounded)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func decode(_ statement: OpaquePointer, _ column: Int32) -> [HistoryApp] {
        guard let text = sqlite3_column_text(statement, column) else { return [] }
        return (try? JSONDecoder().decode([HistoryApp].self, from: Data(String(cString: text).utf8))) ?? []
    }

    // MARK: - SQLite

    private static func open(_ path: String,
                             flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX) throws(FlightRecorderError) -> Connection {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
            sqlite3_close(handle)
            throw .sqlite(message)
        }
        return Connection(handle)
    }

    /// The first schema's tables, then the steps since (`migrate`).
    private static func createTables(on handle: OpaquePointer) throws(FlightRecorderError) {
        let columns = columns.map { "\($0) REAL" }.joined(separator: ", ")
        try execute("""
            CREATE TABLE IF NOT EXISTS records (time REAL PRIMARY KEY, \(columns), top_cpu TEXT, top_memory TEXT) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY, start_time REAL NOT NULL, end_time REAL NOT NULL, note TEXT NOT NULL);
            """, on: handle)
        try migrate(handle)
    }

    /// Brings a database from an older build up to `schemaVersion`, in one
    /// transaction, which also keeps another copy of the app from migrating
    /// it at the same moment. Its records and sessions stay as they are.
    static func migrate(_ handle: OpaquePointer) throws(FlightRecorderError) {
        guard try userVersion(handle) < schemaVersion else { return }
        try execute("BEGIN IMMEDIATE", on: handle)
        do throws(FlightRecorderError) {
            // Read again: another copy may have migrated it while this one waited.
            let version = try userVersion(handle)
            if version < 1 {
                // An event counts once per kind, name and second, whichever copy of the app saw it.
                try execute("""
                    CREATE TABLE IF NOT EXISTS events (time REAL NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
                        detail TEXT NOT NULL DEFAULT '', count INTEGER NOT NULL DEFAULT 1, approximate INTEGER NOT NULL DEFAULT 0);
                    CREATE UNIQUE INDEX IF NOT EXISTS events_once ON events (kind, name, CAST(time AS INTEGER));
                    CREATE INDEX IF NOT EXISTS events_time ON events (time);
                    """, on: handle)
            }
            if version < 2 {
                // Each series named once; a record holds a number per series in `hardware` (`HardwareBlob`).
                try execute("""
                    CREATE TABLE IF NOT EXISTS hardware_series (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                        unit TEXT NOT NULL, label TEXT NOT NULL, source TEXT NOT NULL, rank INTEGER NOT NULL DEFAULT 0);
                    """, on: handle)
                if try !hasColumn("hardware", in: "records", handle) {
                    try execute("ALTER TABLE records ADD COLUMN hardware BLOB", on: handle)
                }
            }
            if version < 3 {
                // Process lifetimes, the app's runs that watch them, and the figures records keep.
                try execute(processTables, on: handle)
            }
            if version < schemaVersion { try execute("PRAGMA user_version = \(schemaVersion)", on: handle) }
            try execute("COMMIT", on: handle)
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// The database's schema version (`user_version`).
    static func userVersion(_ handle: OpaquePointer) throws(FlightRecorderError) -> Int32 {
        let statement = try prepare("PRAGMA user_version", on: handle)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
        return sqlite3_column_int(statement, 0)
    }

    /// The database's schema version, for tests.
    func schemaVersionOnDisk() throws(FlightRecorderError) -> Int32 {
        try Self.userVersion(database)
    }

    static func hasColumn(_ column: String, in table: String, _ handle: OpaquePointer) throws(FlightRecorderError) -> Bool {
        let statement = try prepare("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", on: handle)
        defer { sqlite3_finalize(statement) }
        bind(table, to: statement, at: 1)
        bind(column, to: statement, at: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func insert(_ events: [HistoryEvent], into handle: OpaquePointer) throws(FlightRecorderError) {
        guard !events.isEmpty else { return }
        let statement = try prepare(
            "INSERT OR IGNORE INTO events (time, kind, name, detail, count, approximate) VALUES (?, ?, ?, ?, ?, ?)", on: handle
        )
        defer { sqlite3_finalize(statement) }
        for event in events {
            sqlite3_reset(statement)
            sqlite3_bind_double(statement, 1, event.time.timeIntervalSince1970)
            bind(event.kind.rawValue, to: statement, at: 2)
            bind(event.name, to: statement, at: 3)
            bind(event.detail, to: statement, at: 4)
            sqlite3_bind_int64(statement, 5, Int64(event.count))
            sqlite3_bind_int(statement, 6, event.isApproximate ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
        }
    }

    private static func insert(_ records: [HistoryRecord], into handle: OpaquePointer,
                               catalogue: HardwareCatalogue) throws(FlightRecorderError) {
        let placeholders = Array(repeating: "?", count: columns.count + 4).joined(separator: ", ")
        let statement = try prepare(
            "INSERT OR REPLACE INTO records (time, \(columns.joined(separator: ", ")), top_cpu, top_memory, hardware) VALUES (\(placeholders))",
            on: handle
        )
        defer { sqlite3_finalize(statement) }
        for record in records {
            sqlite3_reset(statement)
            sqlite3_bind_double(statement, 1, record.time.timeIntervalSince1970)
            for (index, value) in row(record.values).enumerated() {
                if let value { sqlite3_bind_double(statement, Int32(index + 2), value) } else { sqlite3_bind_null(statement, Int32(index + 2)) }
            }
            bind(encode(record.topCPU), to: statement, at: Int32(columns.count + 2))
            bind(encode(record.topMemory), to: statement, at: Int32(columns.count + 3))
            if let blob = try HardwareBlob.encode(record, catalogue: catalogue, on: handle) {
                _ = blob.withUnsafeBytes { bytes in
                    // SQLITE_TRANSIENT: SQLite copies the bytes before this returns.
                    sqlite3_bind_blob(statement, Int32(columns.count + 4), bytes.baseAddress, Int32(bytes.count),
                                      unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(statement, Int32(columns.count + 4))
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
        }
    }

    private static func insert(_ session: RecordingSession, into handle: OpaquePointer) throws(FlightRecorderError) {
        let statement = try prepare("INSERT INTO sessions (start_time, end_time, note) VALUES (?, ?, ?)", on: handle)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, session.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, session.end.timeIntervalSince1970)
        bind(session.note, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
    }

    static func execute(_ sql: String, on handle: OpaquePointer) throws(FlightRecorderError) {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
    }

    static func prepare(_ sql: String, on handle: OpaquePointer) throws(FlightRecorderError) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    private func prepare(_ sql: String) throws(FlightRecorderError) -> OpaquePointer {
        try Self.prepare(sql, on: database)
    }

    private func step(_ statement: OpaquePointer) throws(FlightRecorderError) {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw .sqlite(String(cString: sqlite3_errmsg(database))) }
    }

    static func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        // SQLITE_TRANSIENT: SQLite copies the string before this returns.
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
