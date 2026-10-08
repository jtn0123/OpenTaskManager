import Foundation
import SQLite3

extension FlightRecorder {
    static let connectionTables = """
        CREATE TABLE IF NOT EXISTS connection_lifetimes (id TEXT PRIMARY KEY, first_seen REAL NOT NULL,
            last_seen REAL NOT NULL, active INTEGER NOT NULL, payload TEXT NOT NULL, writer TEXT NOT NULL,
            search TEXT NOT NULL, pid INTEGER NOT NULL, local_port INTEGER, remote_port INTEGER, open_key TEXT);
        CREATE INDEX IF NOT EXISTS connection_lifetimes_time ON connection_lifetimes (last_seen, first_seen);
        CREATE INDEX IF NOT EXISTS connection_lifetimes_open ON connection_lifetimes (open_key) WHERE open_key IS NOT NULL;
        CREATE INDEX IF NOT EXISTS connection_lifetimes_cap ON connection_lifetimes (active, last_seen, id);
        CREATE TABLE IF NOT EXISTS connection_coverage (id TEXT PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL,
            spacing REAL NOT NULL, hidden INTEGER NOT NULL, walks INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS connection_coverage_time ON connection_coverage (end, start);
        CREATE TABLE IF NOT EXISTS connection_limits (time REAL PRIMARY KEY, dropped INTEGER NOT NULL);
        """

    public func keepsConnectionHistory() throws(FlightRecorderError) -> Bool {
        // The actor owns the connection; the table query finalizes its statement.
        unsafe try Self.hasTable("connection_lifetimes", database)
    }

    /// Starts, minute bumps, ends and coverage commit together, off the main actor.
    public func appendConnections(_ batch: ConnectionHistoryBatch) throws(FlightRecorderError) {
        guard !batch.rows.isEmpty || batch.interval != nil else { return }
        // The actor owns the live handle; SQLite copies bound strings before their borrow ends.
        unsafe try Self.execute("BEGIN IMMEDIATE", on: database)
        do throws(FlightRecorderError) {
            try writeConnections(batch)
            if let interval = batch.interval { try writeConnectionInterval(interval) }
            if !batch.rows.isEmpty { try capConnections(at: batch.interval?.end ?? batch.rows.map(\.socket.lastSeen).max() ?? .now) }
            unsafe try Self.execute("COMMIT", on: database)
        } catch {
            unsafe sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func writeConnections(_ batch: ConnectionHistoryBatch) throws(FlightRecorderError) {
        guard !batch.rows.isEmpty else { return }
        // This actor owns the connection and finalizes the statement after the batch; text bindings are copied.
        let statement = unsafe try Self.prepare("""
            INSERT INTO connection_lifetimes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                last_seen = excluded.last_seen, active = excluded.active, payload = excluded.payload, writer = excluded.writer,
                search = excluded.search, local_port = excluded.local_port, remote_port = excluded.remote_port,
                open_key = excluded.open_key
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        for row in batch.rows {
            let payload: Data
            do { payload = try JSONEncoder().encode(row) } catch { throw .sqlite(error.localizedDescription) }
            unsafe sqlite3_reset(statement)
            unsafe sqlite3_clear_bindings(statement)
            unsafe Self.bind(row.id, to: statement, at: 1)
            unsafe sqlite3_bind_double(statement, 2, row.socket.firstSeen.timeIntervalSince1970)
            unsafe sqlite3_bind_double(statement, 3, row.socket.lastSeen.timeIntervalSince1970)
            unsafe sqlite3_bind_int(statement, 4, batch.active.contains(row.id) ? 1 : 0)
            unsafe Self.bind(String(decoding: payload, as: UTF8.self), to: statement, at: 5)
            unsafe Self.bind(connectionWriterID, to: statement, at: 6)
            unsafe Self.bind(row.searchText, to: statement, at: 7)
            unsafe sqlite3_bind_int(statement, 8, row.socket.connection.pid)
            unsafe sqlite3_bind_int64(statement, 9, Int64(row.socket.connection.local.port ?? 0))
            unsafe sqlite3_bind_int64(statement, 10, Int64(row.socket.connection.remote?.port ?? 0))
            // Only a row not seen closing can carry on; a closed one keeps no key.
            if row.ending != .closed, let key = row.socket.connection.historyKey {
                unsafe Self.bind(key, to: statement, at: 11)
            }
            unsafe try connectionStep(statement)
        }
    }

    private func writeConnectionInterval(_ interval: ConnectionWatchInterval) throws(FlightRecorderError) {
        // The live handle and statement stay on this actor; SQLite copies the ID binding.
        let statement = unsafe try Self.prepare("""
            INSERT INTO connection_coverage VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
                end = excluded.end, hidden = excluded.hidden, walks = excluded.walks
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe Self.bind(interval.id, to: statement, at: 1)
        unsafe sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 4, interval.spacing)
        unsafe sqlite3_bind_int64(statement, 5, Int64(interval.hiddenProcesses))
        unsafe sqlite3_bind_int64(statement, 6, Int64(interval.walks))
        unsafe try connectionStep(statement)
    }

    private func capConnections(at time: Date) throws(FlightRecorderError) {
        // Indexed ordering drops ended rows first, then the oldest active rows only if they alone exceed the cap.
        // The actor owns this handle; statements are finalized and SQLite copies bindings.
        unsafe try Self.execute("""
            DELETE FROM connection_lifetimes WHERE id IN (SELECT id FROM connection_lifetimes
                ORDER BY active, last_seen, id LIMIT MAX(0, (SELECT COUNT(*) FROM connection_lifetimes) -
                \(ConnectionHistoryRetention.rowLimit)));
            """, on: database)
        let dropped = unsafe sqlite3_changes(database)
        guard dropped > 0 else { return }
        let statement = unsafe try Self.prepare("""
            INSERT INTO connection_limits VALUES (?, ?) ON CONFLICT(time) DO UPDATE SET dropped = dropped + excluded.dropped
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, time.timeIntervalSince1970)
        unsafe sqlite3_bind_int(statement, 2, dropped)
        unsafe try connectionStep(statement)
    }

    public func connectionHistory(matching search: String = "", from start: Date, to end: Date) throws(FlightRecorderError)
        -> [ConnectionLifetime] {
        guard try keepsConnectionHistory() else { return [] }
        let query = ConnectionLifetime.normalized(search)
        let number = Int(query)
        // Filter the compact search text before decoding timelines, on an explicit query only.
        // Column strings are copied before stepping; the actor finalizes its statement.
        let statement = unsafe try Self.prepare("""
            SELECT payload, writer FROM connection_lifetimes WHERE last_seen >= ?1 AND first_seen <= ?2
                AND (?3 = '' OR (?4 = 1 AND (pid = ?5 OR local_port = ?5 OR remote_port = ?5))
                    OR (?4 = 0 AND instr(search, ?3) > 0)) ORDER BY first_seen DESC, id
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        unsafe Self.bind(query, to: statement, at: 3)
        unsafe sqlite3_bind_int(statement, 4, number == nil ? 0 : 1)
        unsafe sqlite3_bind_int64(statement, 5, Int64(number ?? 0))
        var rows: [ConnectionLifetime] = []
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard !Task.isCancelled else { throw .sqlite("Socket history query cancelled") }
            guard let payload = unsafe Self.text(statement, 0) else { throw .sqlite("Missing socket lifetime") }
            do {
                var row = try JSONDecoder().decode(ConnectionLifetime.self, from: Data(payload.utf8))
                // Another recorder's unfinished row is an interrupted watch, never proof the socket still runs.
                if row.ending == .watching, unsafe Self.text(statement, 1) != connectionWriterID { row.ending = .stopped }
                if row.matches(search) { rows.append(row) }
            } catch { throw .sqlite(error.localizedDescription) }
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        return rows
    }

    /// Stored rows not seen closing whose sockets have these keys, the latest per key: what a watch
    /// that starts again (a page visit, a relaunch) carries on rather than starting a second row.
    public func resumableConnections(keys: [String]) throws(FlightRecorderError) -> [String: ConnectionLifetime] {
        guard !keys.isEmpty, try keepsConnectionHistory() else { return [:] }
        var rows: [String: ConnectionLifetime] = [:]
        // Chunks stay under SQLite's bound-parameter limit; the actor finalizes each statement.
        for start in stride(from: 0, to: keys.count, by: 500) {
            let chunk = Array(keys[start..<min(start + 500, keys.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let statement = unsafe try Self.prepare(
                "SELECT open_key, payload FROM connection_lifetimes WHERE open_key IN (\(marks))", on: database
            )
            defer { unsafe sqlite3_finalize(statement) }
            for (index, key) in chunk.enumerated() { unsafe Self.bind(key, to: statement, at: Int32(index + 1)) }
            var status = unsafe sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let key = unsafe Self.text(statement, 0), let payload = unsafe Self.text(statement, 1) else {
                    throw .sqlite("Missing socket lifetime")
                }
                let row: ConnectionLifetime
                do { row = try JSONDecoder().decode(ConnectionLifetime.self, from: Data(payload.utf8)) } catch {
                    throw .sqlite(error.localizedDescription)
                }
                if row.ending != .closed, rows[key].map({ $0.socket.lastSeen < row.socket.lastSeen }) ?? true { rows[key] = row }
                status = unsafe sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        }
        return rows
    }

    public func connectionHistoryResult(matching search: String = "", from start: Date, to end: Date) throws(FlightRecorderError)
        -> ConnectionHistoryResult {
        // No actor suspension inside this transaction; coverage and lifetimes describe one snapshot.
        // The connection belongs to the recorder, and execute borrows it only for the call.
        unsafe try Self.execute("BEGIN", on: database)
        do throws(FlightRecorderError) {
            let rows = try connectionHistory(matching: search, from: start, to: end)
            let coverage = try connectionCoverage(from: start, to: end)
            unsafe try Self.execute("COMMIT", on: database)
            return ConnectionHistoryResult(coverage: coverage, lifetimes: rows)
        } catch {
            unsafe sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Coverage is independent of the search: no match says nothing about an unwatched stretch.
    public func connectionCoverage(from start: Date, to end: Date, limit: Int = -1) throws(FlightRecorderError) -> ConnectionHistoryCoverage {
        guard try keepsConnectionHistory() else { return ConnectionHistoryCoverage(from: start, to: end, intervals: []) }
        // The actor owns both statements; copied IDs outlive the column's next step.
        let statement = unsafe try Self.prepare("""
            SELECT id, start, end, spacing, hidden, walks FROM connection_coverage WHERE end >= ? AND start <= ? ORDER BY start LIMIT ?3
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        unsafe sqlite3_bind_int64(statement, 3, Int64(limit))
        var intervals: [ConnectionWatchInterval] = []
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            unsafe intervals.append(ConnectionWatchInterval(
                id: Self.text(statement, 0) ?? "", start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), spacing: sqlite3_column_double(statement, 3),
                hiddenProcesses: Int(sqlite3_column_int64(statement, 4)), walks: Int(sqlite3_column_int64(statement, 5))
            ))
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        let limits = unsafe try Self.prepare("SELECT COALESCE(SUM(dropped), 0) FROM connection_limits WHERE time >= ?", on: database)
        defer { unsafe sqlite3_finalize(limits) }
        unsafe sqlite3_bind_double(limits, 1, end.addingTimeInterval(-Self.retention).timeIntervalSince1970)
        guard unsafe sqlite3_step(limits) == SQLITE_ROW else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        let dropped = unsafe Int(sqlite3_column_int64(limits, 0))
        return ConnectionHistoryCoverage(from: start, to: end, intervals: intervals, droppedRows: dropped)
    }

    func pruneConnections(before date: Date) throws(FlightRecorderError) {
        guard try keepsConnectionHistory() else { return }
        // The actor owns each prepared statement until its delete or clip has finished.
        for sql in ["DELETE FROM connection_lifetimes WHERE last_seen < ?",
                    "DELETE FROM connection_coverage WHERE end < ?", "UPDATE connection_coverage SET start = ? WHERE start < ?",
                    "DELETE FROM connection_limits WHERE time < ?"] {
            let statement = unsafe try Self.prepare(sql, on: database)
            defer { unsafe sqlite3_finalize(statement) }
            unsafe sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            if sql.hasPrefix("UPDATE") { unsafe sqlite3_bind_double(statement, 2, date.timeIntervalSince1970) }
            unsafe try connectionStep(statement)
        }
    }

    private func connectionStep(_ statement: OpaquePointer) throws(FlightRecorderError) {
        // The caller owns this statement on the recorder's live connection.
        guard unsafe sqlite3_step(statement) == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
    }
}
