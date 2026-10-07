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
/// user marked, sit beside the records and are exported as recording files;
/// an opened file is replayed through an in-memory copy of the same tables.
public actor FlightRecorder {
    /// Seconds each record covers.
    public static let span: TimeInterval = 10
    /// Records older than this are deleted.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

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
    private let connection: Connection
    private var database: OpaquePointer { connection.handle }
    private var lastPrune = Date.distantPast

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
        self.connection = connection
    }

    /// A read-only view of a recording file: its records and session in an
    /// in-memory database, so the History page reads it with the same
    /// queries as the live recording. `url` is the file it was read from.
    public init(replaying file: RecordingFile, from url: URL) throws(FlightRecorderError) {
        let connection = try Self.open(":memory:")
        try Self.createTables(on: connection.handle)
        try Self.execute("BEGIN", on: connection.handle)
        try Self.insert(file.records, into: connection.handle)
        try Self.insert(file.session, into: connection.handle)
        try Self.execute("COMMIT", on: connection.handle)
        self.url = url
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
        try Self.insert([record], into: database)
        if record.time.timeIntervalSince(lastPrune) > 60 * 60 {
            try prune(before: record.time.addingTimeInterval(-Self.retention))
            lastPrune = record.time
        }
    }

    /// Deletes the records before `date`, and the sessions that ended before it.
    public func prune(before date: Date) throws(FlightRecorderError) {
        for sql in ["DELETE FROM records WHERE time < ?", "DELETE FROM sessions WHERE end_time < ?"] {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try step(statement)
        }
    }

    // MARK: - Reading

    /// Graph points between two dates, each the average of the records in a
    /// bucket of `bucket` seconds (CPU peak is the highest). Empty buckets
    /// are left out, and `HistoryPoint.segment` marks the gaps.
    public func points(from start: Date, to end: Date, bucket: TimeInterval) throws(FlightRecorderError) -> [HistoryPoint] {
        let bucket = max(bucket, Self.span)
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

    /// Every record between two dates, oldest first.
    public func records(from start: Date, to end: Date) throws(FlightRecorderError) -> [HistoryRecord] {
        let statement = try prepare("""
            SELECT time, \(Self.columns.joined(separator: ", ")), top_cpu, top_memory
            FROM records WHERE time > ? AND time <= ? ORDER BY time
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var records: [HistoryRecord] = []
        let apps = Int32(Self.columns.count + 1)
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(HistoryRecord(
                time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                values: Self.values(statement, from: 1),
                topCPU: Self.decode(statement, apps),
                topMemory: Self.decode(statement, apps + 1)
            ))
        }
        return records
    }

    /// Seconds recorded between two dates. Each record covers `span`
    /// seconds; copies of the app running side by side write records for the
    /// same stretch, so each stretch counts once.
    public func recordedSeconds(from start: Date, to end: Date) throws(FlightRecorderError) -> TimeInterval {
        let statement = try prepare("SELECT COUNT(DISTINCT CAST(time / ? AS INTEGER)) FROM records WHERE time > ? AND time <= ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Self.span)
        sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(database))) }
        return Double(sqlite3_column_int64(statement, 0)) * Self.span
    }

    /// Seconds per graph point for a graph `span` seconds wide: about
    /// `points` across, in whole records, so every point averages the same
    /// number of them.
    public static func bucket(for span: TimeInterval, points: Int = 360) -> TimeInterval {
        guard span.isFinite, span > 0, points > 0 else { return Self.span }
        let records = (span / Double(points) / Self.span - 1e-9).rounded(.up)
        return max(records, 1) * Self.span
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

    /// A recording file of `session`, made on `machine`. Its records are read
    /// in one transaction, so another copy of the app writing meanwhile
    /// can't tear the snapshot.
    public func recording(of session: RecordingSession, machine: RecordingMachine, generator: String,
                          exported: Date = .now) throws(FlightRecorderError) -> RecordingFile {
        try Self.execute("BEGIN", on: database)
        let records: [HistoryRecord]
        do throws(FlightRecorderError) {
            records = try self.records(from: session.start, to: session.end)
            try Self.execute("COMMIT", on: database)
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return RecordingFile(session: session, machine: machine, generator: generator, exported: exported, records: records)
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

    private static func decode(_ statement: OpaquePointer, _ column: Int32) -> [HistoryApp] {
        guard let text = sqlite3_column_text(statement, column) else { return [] }
        return (try? JSONDecoder().decode([HistoryApp].self, from: Data(String(cString: text).utf8))) ?? []
    }

    // MARK: - SQLite

    private static func open(_ path: String) throws(FlightRecorderError) -> Connection {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
            sqlite3_close(handle)
            throw .sqlite(message)
        }
        return Connection(handle)
    }

    private static func createTables(on handle: OpaquePointer) throws(FlightRecorderError) {
        let columns = columns.map { "\($0) REAL" }.joined(separator: ", ")
        try execute("""
            CREATE TABLE IF NOT EXISTS records (time REAL PRIMARY KEY, \(columns), top_cpu TEXT, top_memory TEXT) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY, start_time REAL NOT NULL, end_time REAL NOT NULL, note TEXT NOT NULL);
            """, on: handle)
    }

    private static func insert(_ records: [HistoryRecord], into handle: OpaquePointer) throws(FlightRecorderError) {
        let placeholders = Array(repeating: "?", count: columns.count + 3).joined(separator: ", ")
        let statement = try prepare(
            "INSERT OR REPLACE INTO records (time, \(columns.joined(separator: ", ")), top_cpu, top_memory) VALUES (\(placeholders))",
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

    private static func execute(_ sql: String, on handle: OpaquePointer) throws(FlightRecorderError) {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
    }

    private static func prepare(_ sql: String, on handle: OpaquePointer) throws(FlightRecorderError) -> OpaquePointer {
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

    private static func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        // SQLITE_TRANSIENT: SQLite copies the string before this returns.
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
