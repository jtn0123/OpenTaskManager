import Foundation
import SQLite3

extension FlightRecorder {
    static let incidentStart = "CASE WHEN l.start_time > 0 THEN MIN(l.start_time, l.first_seen) ELSE l.first_seen END"
    static let incidentClose = "json_extract(payload, '$.closedBy') + 978307200"
    static let incidentIndexes = """
        CREATE INDEX IF NOT EXISTS process_lifetimes_incident_start ON process_lifetimes
            (CASE WHEN start_time > 0 THEN MIN(start_time, first_seen) ELSE first_seen END);
        CREATE INDEX IF NOT EXISTS process_lifetimes_incident_end ON process_lifetimes (ended);
        CREATE INDEX IF NOT EXISTS process_watches_incident ON process_watches (last, started);
        CREATE INDEX IF NOT EXISTS connection_lifetimes_incident_start ON connection_lifetimes (first_seen);
        CREATE INDEX IF NOT EXISTS connection_lifetimes_incident_end ON connection_lifetimes
            (json_extract(payload, '$.closedBy') + 978307200);
        """

    /// Starts and observed ends, not a name search or every lifetime overlapping the window.
    public func processLifetimes(from start: Date, to end: Date, limit: Int = 201) throws(FlightRecorderError) -> [ProcessLifetime] {
        guard try keepsProcessHistory() else { return [] }
        let peaks = try keepsProcessMemory() ? "l.peak_footprint, l.peak_footprint_time, l.peak_footprint_measure" : "NULL, NULL, NULL"
        // The actor owns the handle; row values are copied before stepping and the statement is finalized here.
        let statement = unsafe try Self.prepare("""
            SELECT l.id, l.pid, l.start_time, l.name, l.path, l.user_name, l.bundle, l.job, l.restricted, l.first_seen,
                CASE WHEN l.ended IS NOT NULL THEN l.last_seen ELSE MAX(l.last_seen, IFNULL(w.last, l.last_seen)) END,
                l.ended, \(peaks)
            FROM process_lifetimes l LEFT JOIN process_watches w ON w.id = l.watch
            WHERE (\(Self.incidentStart) >= ?1 AND \(Self.incidentStart) <= ?2) OR (l.ended >= ?1 AND l.ended <= ?2)
            ORDER BY MIN(\(Self.incidentStart), COALESCE(l.ended, ?2)), l.id LIMIT ?3
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        unsafe sqlite3_bind_int64(statement, 3, Int64(max(limit, 0)))
        var rows: [ProcessLifetime] = []
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            unsafe rows.append(Self.lifetime(statement))
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        return rows
    }

    public func launchJobEvents(from start: Date, to end: Date, limit: Int = 201) throws(FlightRecorderError) -> [LaunchHistoryEvent] {
        guard try keepsLaunchJobHistory() else { return [] }
        // The actor owns this live connection; the helper copies text before stepping and finalizes its statement.
        return try incidentPayloads("""
            SELECT payload FROM launch_job_events WHERE time >= ?1 AND time <= ?2 ORDER BY time, id LIMIT ?3
            """, window: IncidentWindow(from: start, to: end), limit: limit)
    }

    func incidentConnections(_ window: IncidentWindow, limit: Int) throws(FlightRecorderError) -> [ConnectionLifetime] {
        guard try keepsConnectionHistory() else { return [] }
        // Both time predicates use schema 10's indexes. A stopped watch has no closedBy and invents no closure.
        return try incidentPayloads("""
            SELECT payload FROM connection_lifetimes WHERE (first_seen >= ?1 AND first_seen <= ?2)
                OR (\(Self.incidentClose) >= ?1 AND \(Self.incidentClose) <= ?2)
            ORDER BY first_seen, id LIMIT ?3
            """, window: window, limit: limit)
    }

    func incidentListenerChanges(_ window: IncidentWindow, limit: Int) throws(FlightRecorderError) -> [ListenerChange] {
        // The single review row is keyed by id. SQLite filters its pending changes before decoding the bounded result.
        guard unsafe try Self.hasTable("listener_review", database) else { return [] }
        return try incidentPayloads("""
            SELECT change.value FROM listener_review, json_each(listener_review.payload, '$.changes') AS change
            WHERE listener_review.id = 1 AND json_extract(change.value, '$.detectedAt') + 978307200 >= ?1
                AND json_extract(change.value, '$.detectedAt') + 978307200 <= ?2
            ORDER BY json_extract(change.value, '$.detectedAt') LIMIT ?3
            """, window: window, limit: limit)
    }

    private func incidentPayloads<Value: Decodable>(_ sql: String, window: IncidentWindow, limit: Int)
        throws(FlightRecorderError) -> [Value] {
        // The actor owns the handle; SQLite text is copied before the next step, and this statement is finalized here.
        let statement = unsafe try Self.prepare(sql, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, window.start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 2, window.end.timeIntervalSince1970)
        unsafe sqlite3_bind_int64(statement, 3, Int64(max(limit, 0)))
        var result: [Value] = []
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let payload = unsafe Self.text(statement, 0) else { throw .sqlite("Missing incident evidence") }
            do { result.append(try JSONDecoder().decode(Value.self, from: Data(payload.utf8))) } catch {
                throw .sqlite(error.localizedDescription)
            }
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        return result
    }

    func incidentCoverage(_ window: IncidentWindow, source: IncidentLaneKind, limit: Int) throws(FlightRecorderError)
        -> [String: IncidentCoverage] {
        let sql: String
        switch source {
        case .resources, .events:
            sql = "SELECT '', time - \(recordSpan), time FROM records WHERE time >= ?1 AND time <= ?2 + \(recordSpan) ORDER BY time LIMIT ?3"
        case .processes:
            guard try keepsProcessHistory() else { return [:] }
            sql = """
                SELECT '', time - \(recordSpan), time FROM records WHERE time >= ?1 AND time <= ?2 + \(recordSpan)
                    AND EXISTS (SELECT 1 FROM process_watches WHERE started <= records.time AND last >= records.time)
                ORDER BY time LIMIT ?3
                """
        case .jobs:
            guard try keepsLaunchJobHistory() else { return [:] }
            sql = "SELECT domain, start, end FROM launch_job_reads WHERE end >= ?1 AND start <= ?2 ORDER BY end LIMIT ?3"
        case .sockets:
            guard try keepsConnectionHistory() else { return [:] }
            sql = "SELECT '', start, end FROM connection_coverage WHERE end >= ?1 AND start <= ?2 ORDER BY end LIMIT ?3"
        }
        // Existing time indexes bound coverage reads. Extra rows disclose a cap instead of implying the unqueried part was watched.
        // The actor owns the live handle and finalizes the statement after copying its values.
        let statement = unsafe try Self.prepare(sql, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, window.start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 2, window.end.timeIntervalSince1970)
        unsafe sqlite3_bind_int64(statement, 3, Int64(limit + 1))
        var spans: [String: [LaunchHistoryInterval]] = [:]
        var count = 0
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            count += 1
            if count <= limit {
                let domain = unsafe Self.text(statement, 0) ?? ""
                let start = unsafe Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                let end = unsafe Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                spans[domain, default: []].append(LaunchHistoryInterval(start: start, end: end))
            }
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        return spans.mapValues { IncidentCoverage(window: window, spans: $0, cut: count > limit) }
    }
}
