import Foundation
import SQLite3

/// The flight recorder's process history (schema 3).
///
/// - `process_lifetimes`: every process seen, once, by PID and start time
///   (0 where unread), with its name, path, user, bundle identifier and
///   launchd label, when the recording first and last saw it, and when it
///   ended if that was seen.
/// - `process_watches`: one row per run of the app, its last record's time
///   moved on with each record. An open lifetime points at the run that
///   watches it, so its last sighting costs one row a record, not one per
///   process.
/// - `process_samples`: the figures a record keeps (`ProcessHistoryKeep`),
///   one row per kept process: the record's time in whole seconds, CPU in
///   tenths of a percent of one core, footprint in bytes, disk bytes a
///   second (null where unread).
///
/// A record without a process's row while it ran left it out as idle;
/// a stretch without records wasn't recorded at all.
extension FlightRecorder {
    static let processTables = """
        CREATE TABLE IF NOT EXISTS process_watches (id INTEGER PRIMARY KEY, started REAL NOT NULL, last REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS process_lifetimes (id INTEGER PRIMARY KEY, pid INTEGER NOT NULL, start_time REAL NOT NULL,
            name TEXT NOT NULL, path TEXT, user_name TEXT NOT NULL DEFAULT '', bundle TEXT, job TEXT,
            restricted INTEGER NOT NULL DEFAULT 0, first_seen REAL NOT NULL, last_seen REAL NOT NULL, ended REAL, watch INTEGER);
        CREATE UNIQUE INDEX IF NOT EXISTS process_lifetimes_identity ON process_lifetimes (pid, start_time);
        CREATE TABLE IF NOT EXISTS process_samples (lifetime INTEGER NOT NULL, time INTEGER NOT NULL, cpu INTEGER NOT NULL,
            memory INTEGER NOT NULL, disk_read INTEGER, disk_write INTEGER, PRIMARY KEY (lifetime, time)) WITHOUT ROWID;
        """

    /// A lifetime's last sighting: its end, or else the later of its own
    /// last sighting and its watching run's last record.
    private static let lastSeen = "COALESCE(l.ended, MAX(l.last_seen, IFNULL(w.last, l.last_seen)))"
    private static let lifetimeColumns = """
        l.id, l.pid, l.start_time, l.name, l.path, l.user_name, l.bundle, l.job, l.restricted, l.first_seen, \(lastSeen), l.ended
        """

    // MARK: - Writing

    /// Saves a record's process history (`ProcessHistoryTracker`) in one transaction.
    public func append(_ batch: ProcessHistoryBatch) throws(FlightRecorderError) {
        try Self.execute("BEGIN IMMEDIATE", on: database)
        do throws(FlightRecorderError) {
            try processWriter.write(batch, on: database)
            try Self.execute("COMMIT", on: database)
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            processWriter.forget()
            throw error
        }
    }

    /// Deletes process figures before `date`, and the lifetimes and runs
    /// last seen before it.
    func pruneProcesses(before date: Date) throws(FlightRecorderError) {
        let cutoff = date.timeIntervalSince1970
        // A lifetime's last figures can come a record after its end; give
        // it a minute so none is left without its lifetime.
        let statements = [
            "DELETE FROM process_samples WHERE lifetime IN (SELECT id FROM process_lifetimes WHERE first_seen < ?1) AND time < ?1",
            """
            DELETE FROM process_lifetimes WHERE id IN (SELECT l.id FROM process_lifetimes l LEFT JOIN process_watches w ON w.id = l.watch
                WHERE l.first_seen < ?1 AND \(Self.lastSeen) < ?1 - 60)
            """,
            "DELETE FROM process_watches WHERE last < ?1 AND id NOT IN (SELECT watch FROM process_lifetimes WHERE watch IS NOT NULL)",
        ]
        for sql in statements {
            let statement = try Self.prepare(sql, on: database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw .sqlite(String(cString: sqlite3_errmsg(database))) }
        }
    }

    // MARK: - Reading

    /// Whether the database has process history tables: false for one an
    /// older build made that this build hasn't opened to write yet.
    public func keepsProcessHistory() throws(FlightRecorderError) -> Bool {
        let statement = try Self.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'process_samples'", on: database)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// The lifetimes seen between two dates whose name, executable path,
    /// bundle identifier or launchd label holds `query` (any case of ASCII
    /// letters), or whose PID it is, latest first, `limit` at most, each with
    /// its figures over the part of the range it ran.
    public func processLifetimes(matching query: String, from start: Date, to end: Date,
                                 limit: Int = 100) throws(FlightRecorderError) -> [ProcessHistoryMatch] {
        guard let query = ProcessHistorySearch.normalized(query) else { return [] }
        let statement = try Self.prepare("""
            SELECT \(Self.lifetimeColumns) FROM process_lifetimes l LEFT JOIN process_watches w ON w.id = l.watch
            WHERE (l.name LIKE ?1 ESCAPE '\\' OR l.path LIKE ?1 ESCAPE '\\' OR l.bundle LIKE ?1 ESCAPE '\\'
                OR l.job LIKE ?1 ESCAPE '\\' OR l.pid = ?2)
                AND l.first_seen <= ?4 AND \(Self.lastSeen) >= ?3
            ORDER BY \(Self.lastSeen) DESC, l.first_seen DESC, l.id DESC LIMIT ?5
            """, on: database)
        defer { sqlite3_finalize(statement) }
        Self.bind(ProcessHistorySearch.likePattern(query), to: statement, at: 1)
        if let pid = ProcessHistorySearch.pid(query) { sqlite3_bind_int64(statement, 2, Int64(pid)) } else { sqlite3_bind_null(statement, 2) }
        sqlite3_bind_double(statement, 3, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, end.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 5, Int64(max(limit, 0)))
        var lifetimes: [ProcessLifetime] = []
        while sqlite3_step(statement) == SQLITE_ROW { lifetimes.append(Self.lifetime(statement)) }
        var matches: [ProcessHistoryMatch] = []
        for lifetime in lifetimes {
            matches.append(ProcessHistoryMatch(lifetime: lifetime, summary: try processSummary(lifetime, from: start, to: end)))
        }
        return matches
    }

    /// The lifetime of `identity`, if the recording has seen it.
    public func processLifetime(_ identity: ProcessIdentity) throws(FlightRecorderError) -> ProcessLifetime? {
        let statement = try Self.prepare("""
            SELECT \(Self.lifetimeColumns) FROM process_lifetimes l LEFT JOIN process_watches w ON w.id = l.watch
            WHERE l.pid = ? AND l.start_time = ?
            """, on: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(identity.pid))
        sqlite3_bind_double(statement, 2, identity.startTime?.timeIntervalSince1970 ?? 0)
        return sqlite3_step(statement) == SQLITE_ROW ? Self.lifetime(statement) : nil
    }

    /// `lifetime`'s figures over the part of the range it ran.
    public func processSummary(_ lifetime: ProcessLifetime, from start: Date, to end: Date) throws(FlightRecorderError) -> ProcessHistorySummary {
        guard let window = try recordWindow(lifetime, from: start, to: end) else { return .empty }
        let records = try recordCount(in: window)
        let statement = try Self.prepare("""
            SELECT COUNT(*), SUM(cpu), MAX(cpu), MAX(memory), SUM(disk_read), SUM(disk_write), COUNT(disk_read)
            FROM process_samples WHERE lifetime = ? AND time >= ? AND time <= ?
            """, on: database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lifetime.id)
        sqlite3_bind_double(statement, 2, Self.sampleTime(window.lowerBound) - 1)
        sqlite3_bind_double(statement, 3, window.upperBound.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(database))) }
        let stored = Int(sqlite3_column_int64(statement, 0))
        // Copies of the app running side by side can each keep a record's row.
        let counted = max(records, stored)
        // Idle records count as nothing in the averages; with none kept there are no figures to give.
        let kept = stored > 0
        let hasDisk = kept && sqlite3_column_int64(statement, 6) > 0
        return ProcessHistorySummary(
            records: counted, stored: stored, recordedSeconds: Double(counted) * recordSpan,
            averageCPU: kept ? sqlite3_column_double(statement, 1) / 10 / Double(counted) : nil,
            peakCPU: kept ? sqlite3_column_double(statement, 2) / 10 : nil,
            peakMemory: kept ? UInt64(max(sqlite3_column_int64(statement, 3), 0)) : nil,
            averageDiskRead: hasDisk ? sqlite3_column_double(statement, 4) / Double(counted) : nil,
            averageDiskWrite: hasDisk ? sqlite3_column_double(statement, 5) / Double(counted) : nil
        )
    }

    /// `lifetime`'s chart points between two dates, a bucket of `bucket`
    /// seconds each, at least a record long, grouped as `points` groups
    /// the records. Only buckets with records while it ran are points; a
    /// gap in the recording breaks the segments as it does `points`'.
    public func processPoints(_ lifetime: ProcessLifetime, from start: Date, to end: Date,
                              bucket: TimeInterval) throws(FlightRecorderError) -> [ProcessHistoryPoint] {
        let bucket = max(bucket, recordSpan)
        guard let window = try recordWindow(lifetime, from: start, to: end) else { return [] }
        let records = try Self.prepare("""
            SELECT CAST(time / ?1 AS INTEGER), MAX(time), COUNT(DISTINCT CAST(time / ?2 AS INTEGER)) FROM records
            WHERE time >= ?3 AND time <= ?4 GROUP BY 1 ORDER BY 1
            """, on: database)
        defer { sqlite3_finalize(records) }
        sqlite3_bind_double(records, 1, bucket)
        sqlite3_bind_double(records, 2, recordSpan)
        sqlite3_bind_double(records, 3, window.lowerBound.timeIntervalSince1970)
        sqlite3_bind_double(records, 4, window.upperBound.timeIntervalSince1970)
        var buckets: [(key: Int64, time: Double, records: Int)] = []
        while sqlite3_step(records) == SQLITE_ROW {
            buckets.append((sqlite3_column_int64(records, 0), sqlite3_column_double(records, 1), Int(sqlite3_column_int64(records, 2))))
        }
        let samples = try Self.prepare("""
            SELECT CAST(time / ?1 AS INTEGER), COUNT(*), SUM(cpu), MAX(cpu), MAX(memory), SUM(disk_read), SUM(disk_write),
                COUNT(disk_read) FROM process_samples WHERE lifetime = ?2 AND time >= ?3 AND time <= ?4 GROUP BY 1
            """, on: database)
        defer { sqlite3_finalize(samples) }
        sqlite3_bind_double(samples, 1, bucket)
        sqlite3_bind_int64(samples, 2, lifetime.id)
        sqlite3_bind_double(samples, 3, Self.sampleTime(window.lowerBound) - 1)
        sqlite3_bind_double(samples, 4, window.upperBound.timeIntervalSince1970)
        var stored: [Int64: StoredBucket] = [:]
        while sqlite3_step(samples) == SQLITE_ROW {
            stored[sqlite3_column_int64(samples, 0)] = StoredBucket(
                count: Int(sqlite3_column_int64(samples, 1)), cpu: sqlite3_column_double(samples, 2) / 10,
                cpuPeak: sqlite3_column_double(samples, 3) / 10, memory: sqlite3_column_double(samples, 4),
                diskRead: sqlite3_column_double(samples, 5), diskWrite: sqlite3_column_double(samples, 6),
                hasDisk: sqlite3_column_int64(samples, 7) > 0
            )
        }
        var points: [ProcessHistoryPoint] = []
        points.reserveCapacity(buckets.count)
        for entry in buckets {
            let kept = stored[entry.key]
            let count = max(entry.records, kept?.count ?? 0)
            let disk = kept?.hasDisk == true
            points.append(ProcessHistoryPoint(
                time: Date(timeIntervalSince1970: entry.time), records: count, stored: kept?.count ?? 0,
                cpu: kept.map { $0.cpu / Double(count) }, cpuPeak: kept?.cpuPeak, memory: kept?.memory,
                diskRead: disk ? kept.map { $0.diskRead / Double(count) } : nil,
                diskWrite: disk ? kept.map { $0.diskWrite / Double(count) } : nil
            ))
        }
        return Self.segmented(points, gap: bucket * HistoryGap.spacing)
    }

    // MARK: - Helpers

    private struct StoredBucket {
        let count: Int
        let cpu: Double
        let cpuPeak: Double
        let memory: Double
        let diskRead: Double
        let diskWrite: Double
        let hasDisk: Bool
    }

    /// The records that cover `lifetime`'s run, within the range: from the
    /// first after it was seen to its last sighting, or for one seen ending
    /// to the first record from then, which holds its last seconds.
    private func recordWindow(_ lifetime: ProcessLifetime, from start: Date, to end: Date) throws(FlightRecorderError) -> ClosedRange<Date>? {
        var last = lifetime.lastSeen
        if let ended = lifetime.ended {
            // Only a record that follows on: one after a gap didn't cover it.
            let statement = try Self.prepare("SELECT MIN(time) FROM records WHERE time >= ? AND time <= ?", on: database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, ended.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, ended.timeIntervalSince1970 + recordSpan * 1.5)
            if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL {
                last = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            }
        }
        let lower = max(lifetime.firstSeen, start)
        let upper = min(max(last, lifetime.firstSeen), end)
        return lower <= upper ? lower...upper : nil
    }

    private func recordCount(in window: ClosedRange<Date>) throws(FlightRecorderError) -> Int {
        let statement = try Self.prepare(
            "SELECT COUNT(DISTINCT CAST(time / ? AS INTEGER)) FROM records WHERE time >= ? AND time <= ?", on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, recordSpan)
        sqlite3_bind_double(statement, 2, window.lowerBound.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, window.upperBound.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(database))) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// A record's time as `process_samples` keeps it, in whole seconds.
    static func sampleTime(_ date: Date) -> Double {
        date.timeIntervalSince1970.rounded(.down)
    }

    private static func segmented(_ points: [ProcessHistoryPoint], gap: TimeInterval) -> [ProcessHistoryPoint] {
        var segment = 0
        var previous: Date?
        return points.map { point in
            if let previous, point.time.timeIntervalSince(previous) > gap { segment += 1 }
            previous = point.time
            var point = point
            point.segment = segment
            return point
        }
    }

    static func lifetime(_ statement: OpaquePointer) -> ProcessLifetime {
        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
        }
        let start = sqlite3_column_double(statement, 2)
        return ProcessLifetime(
            id: sqlite3_column_int64(statement, 0),
            identity: ProcessIdentity(pid: Int32(truncatingIfNeeded: sqlite3_column_int64(statement, 1)),
                                      startTime: start > 0 ? Date(timeIntervalSince1970: start) : nil),
            name: text(statement, 3) ?? "", path: text(statement, 4), user: text(statement, 5) ?? "",
            bundleID: text(statement, 6), jobLabel: text(statement, 7), isRestricted: sqlite3_column_int(statement, 8) != 0,
            firstSeen: date(9) ?? .distantPast, lastSeen: date(10) ?? .distantPast, ended: date(11)
        )
    }
}

/// Writes process history for one recorder: its run's row in
/// `process_watches`, the open lifetimes' rows by process, and the bundle
/// identifiers read from apps' Info.plist files, each once.
final class ProcessHistoryWriter {
    private var watch: Int64?
    private var rows: [ProcessIdentity: Int64] = [:]
    private var bundles: [String: String?] = [:]

    /// Forgets what a rolled-back write may have added.
    func forget() {
        watch = nil
        rows = [:]
    }

    func write(_ batch: ProcessHistoryBatch, on handle: OpaquePointer) throws(FlightRecorderError) {
        let time = batch.time.timeIntervalSince1970
        let watch: Int64
        if let current = self.watch {
            watch = current
        } else {
            watch = try newWatch(at: time, on: handle)
            self.watch = watch
        }
        if !batch.started.isEmpty { try start(batch.started, watch: watch, on: handle) }
        if !batch.labels.isEmpty { try label(batch.labels, on: handle) }
        if !batch.samples.isEmpty { try keep(batch.samples, at: batch.time, on: handle) }
        if !batch.ended.isEmpty { try end(batch.ended, watch: watch, on: handle) }
        let moved = try FlightRecorder.prepare("UPDATE process_watches SET last = MAX(last, ?) WHERE id = ?", on: handle)
        defer { sqlite3_finalize(moved) }
        sqlite3_bind_double(moved, 1, time)
        sqlite3_bind_int64(moved, 2, watch)
        try Self.step(moved, on: handle)
    }

    private func newWatch(at time: Double, on handle: OpaquePointer) throws(FlightRecorderError) -> Int64 {
        let statement = try FlightRecorder.prepare("INSERT INTO process_watches (started, last) VALUES (?, ?)", on: handle)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, time)
        sqlite3_bind_double(statement, 2, time)
        try Self.step(statement, on: handle)
        return sqlite3_last_insert_rowid(handle)
    }

    /// Adds each lifetime, or takes over one already there (seen by an
    /// earlier run of the app, the process still running): its last
    /// sighting becomes that run's last record.
    private func start(_ starts: [ProcessHistoryBatch.Start], watch: Int64, on handle: OpaquePointer) throws(FlightRecorderError) {
        let statement = try FlightRecorder.prepare("""
            INSERT INTO process_lifetimes (pid, start_time, name, path, user_name, bundle, restricted, first_seen, last_seen, watch)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9)
            ON CONFLICT (pid, start_time) DO UPDATE SET
                last_seen = MAX(last_seen, IFNULL((SELECT last FROM process_watches WHERE id = process_lifetimes.watch), last_seen)),
                watch = excluded.watch, ended = NULL, name = excluded.name, path = COALESCE(excluded.path, path),
                bundle = COALESCE(excluded.bundle, bundle), restricted = excluded.restricted
            RETURNING id
            """, on: handle)
        defer { sqlite3_finalize(statement) }
        for start in starts {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, Int64(start.identity.pid))
            sqlite3_bind_double(statement, 2, start.identity.startTime?.timeIntervalSince1970 ?? 0)
            FlightRecorder.bind(start.name, to: statement, at: 3)
            bindOptional(start.path, to: statement, at: 4)
            FlightRecorder.bind(start.user, to: statement, at: 5)
            bindOptional(start.path.flatMap(bundleID(forExecutable:)), to: statement, at: 6)
            sqlite3_bind_int(statement, 7, start.isRestricted ? 1 : 0)
            sqlite3_bind_double(statement, 8, start.firstSeen.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 9, watch)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
            rows[start.identity] = sqlite3_column_int64(statement, 0)
            while sqlite3_step(statement) == SQLITE_ROW {}
        }
    }

    private func label(_ labels: [ProcessIdentity: String], on handle: OpaquePointer) throws(FlightRecorderError) {
        let statement = try FlightRecorder.prepare("UPDATE process_lifetimes SET job = ? WHERE pid = ? AND start_time = ?", on: handle)
        defer { sqlite3_finalize(statement) }
        for (identity, label) in labels {
            sqlite3_reset(statement)
            FlightRecorder.bind(label, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, Int64(identity.pid))
            sqlite3_bind_double(statement, 3, identity.startTime?.timeIntervalSince1970 ?? 0)
            try Self.step(statement, on: handle)
        }
    }

    private func keep(_ samples: [ProcessHistorySample], at time: Date, on handle: OpaquePointer) throws(FlightRecorderError) {
        let statement = try FlightRecorder.prepare("""
            INSERT OR REPLACE INTO process_samples (lifetime, time, cpu, memory, disk_read, disk_write) VALUES (?, ?, ?, ?, ?, ?)
            """, on: handle)
        defer { sqlite3_finalize(statement) }
        for sample in samples {
            guard let row = try row(for: sample.identity, on: handle) else { continue }
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, row)
            sqlite3_bind_int64(statement, 2, Int64(FlightRecorder.sampleTime(time)))
            sqlite3_bind_int64(statement, 3, Int64((sample.cpuPercent * 10).rounded()))
            sqlite3_bind_int64(statement, 4, Int64(clamping: sample.memory))
            for (index, rate) in [sample.diskRead, sample.diskWrite].enumerated() {
                if let rate, rate.isFinite { sqlite3_bind_int64(statement, Int32(index + 5), Int64(rate.rounded())) } else {
                    sqlite3_bind_null(statement, Int32(index + 5))
                }
            }
            try Self.step(statement, on: handle)
        }
    }

    /// Closes each lifetime: ended, or for one no longer watched, last seen
    /// now and no longer this run's.
    private func end(_ ends: [ProcessHistoryBatch.End], watch: Int64, on handle: OpaquePointer) throws(FlightRecorderError) {
        let ended = try FlightRecorder.prepare("UPDATE process_lifetimes SET ended = ?1, last_seen = MAX(last_seen, ?1) WHERE id = ?2",
                                               on: handle)
        defer { sqlite3_finalize(ended) }
        let unwatched = try FlightRecorder.prepare("""
            UPDATE process_lifetimes SET last_seen = MAX(last_seen, ?1), watch = NULL WHERE id = ?2 AND watch = ?3
            """, on: handle)
        defer { sqlite3_finalize(unwatched) }
        for end in ends {
            guard let row = try row(for: end.identity, on: handle) else { continue }
            rows.removeValue(forKey: end.identity)
            let statement = end.isEnded ? ended : unwatched
            sqlite3_reset(statement)
            sqlite3_bind_double(statement, 1, end.time.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 2, row)
            if !end.isEnded { sqlite3_bind_int64(statement, 3, watch) }
            try Self.step(statement, on: handle)
        }
    }

    /// The lifetime's row: this run's, or one the database has.
    private func row(for identity: ProcessIdentity, on handle: OpaquePointer) throws(FlightRecorderError) -> Int64? {
        if let row = rows[identity] { return row }
        let statement = try FlightRecorder.prepare("SELECT id FROM process_lifetimes WHERE pid = ? AND start_time = ?", on: handle)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(identity.pid))
        sqlite3_bind_double(statement, 2, identity.startTime?.timeIntervalSince1970 ?? 0)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// The identifier of the app bundle an executable runs from, read from
    /// its Info.plist once per bundle.
    private func bundleID(forExecutable path: String) -> String? {
        guard let range = path.range(of: "/Contents/MacOS/", options: .backwards) else { return nil }
        let bundle = String(path[..<range.lowerBound])
        if let known = bundles[bundle] { return known }
        let info = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")
        let identifier = (NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        bundles[bundle] = .some(identifier)
        return identifier
    }

    private func bindOptional(_ text: String?, to statement: OpaquePointer, at index: Int32) {
        if let text { FlightRecorder.bind(text, to: statement, at: index) } else { sqlite3_bind_null(statement, index) }
    }

    private static func step(_ statement: OpaquePointer, on handle: OpaquePointer) throws(FlightRecorderError) {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw .sqlite(String(cString: sqlite3_errmsg(handle))) }
    }
}
