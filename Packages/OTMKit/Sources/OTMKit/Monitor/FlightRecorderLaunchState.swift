import Foundation
import SQLite3

extension FlightRecorder {
    /// Loaded baselines survive retention: their change time can be months old
    /// while the job is still unchanged. Ended, unloaded jobs can age out.
    static let launchStateTables = """
        CREATE TABLE IF NOT EXISTS launch_job_state (label TEXT NOT NULL, domain TEXT NOT NULL, time REAL NOT NULL,
            loaded INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (label, domain)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS launch_job_reads (id INTEGER PRIMARY KEY, domain TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS launch_job_reads_domain ON launch_job_reads (domain, start, end);
        CREATE INDEX IF NOT EXISTS launch_job_reads_end ON launch_job_reads (end);
        """

    func launchJobStates() throws(FlightRecorderError) -> [LaunchHistoryKey: LaunchHistoryState] {
        // The actor owns the connection; text is copied before stepping and the statement is finalized here.
        let statement = unsafe try Self.prepare("SELECT payload FROM launch_job_state", on: database)
        defer { unsafe sqlite3_finalize(statement) }
        var result: [LaunchHistoryKey: LaunchHistoryState] = [:]
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let text = unsafe Self.text(statement, 0) else { throw .sqlite("Missing launch job state") }
            let state: LaunchHistoryState
            do {
                state = try JSONDecoder().decode(LaunchHistoryState.self, from: Data(text.utf8))
            } catch {
                throw .sqlite(error.localizedDescription)
            }
            result[state.key] = state
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        return result
    }

    /// Each domain's latest watched moment from any copy, read once at the first read.
    func launchJobLastReads() throws(FlightRecorderError) -> [String: Date] {
        // The actor owns the connection; domain text is copied before stepping and the statement is finalized here.
        let statement = unsafe try Self.prepare("SELECT domain, MAX(end) FROM launch_job_reads GROUP BY domain", on: database)
        defer { unsafe sqlite3_finalize(statement) }
        var result: [String: Date] = [:]
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let domain = unsafe Self.text(statement, 0) {
                result[domain] = unsafe Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            }
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        return result
    }

    func writeLaunchStates(_ states: [LaunchHistoryState]) throws(FlightRecorderError) {
        guard !states.isEmpty else { return }
        // The actor owns the live connection; bound strings are copied and this statement is finalized after its batch.
        let statement = unsafe try Self.prepare("""
            INSERT INTO launch_job_state (label, domain, time, loaded, payload) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(label, domain) DO UPDATE SET time = excluded.time, loaded = excluded.loaded, payload = excluded.payload
                WHERE excluded.time > launch_job_state.time
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        for state in states {
            let payload: Data
            do { payload = try JSONEncoder().encode(state) } catch { throw .sqlite(error.localizedDescription) }
            unsafe sqlite3_reset(statement)
            unsafe sqlite3_clear_bindings(statement)
            unsafe Self.bind(state.key.label, to: statement, at: 1)
            unsafe Self.bind(state.key.domain, to: statement, at: 2)
            unsafe sqlite3_bind_double(statement, 3, state.time.timeIntervalSince1970)
            unsafe sqlite3_bind_int(statement, 4, state.loaded ? 1 : 0)
            unsafe Self.bind(String(decoding: payload, as: UTF8.self), to: statement, at: 5)
            guard unsafe sqlite3_step(statement) == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        }
    }

    func writeLaunchReads(_ changes: [LaunchHistoryReadChange]) throws(FlightRecorderError) {
        // IDs are kept per app copy, so two copies never extend each other's
        // open interval. Querying coverage unions their overlapping intervals.
        for change in changes {
            let row = launchWriter.readRows[change.domain]
            let sql = change.extends && row != nil ? "UPDATE launch_job_reads SET end = ?3 WHERE id = ?4"
                : "INSERT INTO launch_job_reads (domain, start, end) VALUES (?1, ?2, ?3)"
            // The actor owns the connection; SQLite copies the domain and this statement is finalized after the write.
            let statement = unsafe try Self.prepare(sql, on: database)
            defer { unsafe sqlite3_finalize(statement) }
            if change.extends, let row {
                unsafe sqlite3_bind_int64(statement, 4, row)
            } else {
                unsafe Self.bind(change.domain, to: statement, at: 1)
                unsafe sqlite3_bind_double(statement, 2, change.interval.start.timeIntervalSince1970)
            }
            unsafe sqlite3_bind_double(statement, 3, change.interval.end.timeIntervalSince1970)
            guard unsafe sqlite3_step(statement) == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
            if !change.extends || row == nil { launchWriter.readRows[change.domain] = unsafe sqlite3_last_insert_rowid(database) }
        }
    }

    public func launchJobCoverage(domain: String, from start: Date, to end: Date) throws(FlightRecorderError)
        -> [LaunchHistoryInterval] {
        guard try keepsLaunchJobHistory() else { return [] }
        // The actor owns the connection; dates are copied into values and this statement is finalized here.
        let statement = unsafe try Self.prepare("""
            SELECT start, end FROM launch_job_reads WHERE domain = ?1 AND end >= ?2 AND start <= ?3 ORDER BY start, end
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe Self.bind(domain, to: statement, at: 1)
        unsafe sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
        var intervals: [LaunchHistoryInterval] = []
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            let first = unsafe Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let last = unsafe Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            intervals.append(LaunchHistoryInterval(start: max(start, first), end: min(end, last)))
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        return LaunchHistoryCoverage.merged(intervals)
    }

    /// Read together on the recorder actor, so an event query cannot race a
    /// coverage update from this copy. The CLI unions coverage for matching domains.
    public func launchJobHistory(label: String, domain: String? = nil, from start: Date, to end: Date) throws(FlightRecorderError)
        -> LaunchHistoryReport {
        let events = try launchJobEvents(label: label, domain: domain, from: start, to: end)
        var domains = Set(events.map(\.key.domain))
        if let domain { domains = [domain] } else if try keepsLaunchJobHistory() {
            // A stable job can have no events in this range but still have a baseline.
            // The actor owns the connection; domain strings are copied before stepping and the statement is finalized here.
            let statement = unsafe try Self.prepare("SELECT domain FROM launch_job_state WHERE label = ?", on: database)
            defer { unsafe sqlite3_finalize(statement) }
            unsafe Self.bind(label, to: statement, at: 1)
            var status = unsafe sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let found = unsafe Self.text(statement, 0) { domains.insert(found) }
                status = unsafe sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        }
        var intervals: [LaunchHistoryInterval] = []
        for domain in domains { intervals += try launchJobCoverage(domain: domain, from: start, to: end) }
        return LaunchHistoryReport(coverage: LaunchHistoryCoverage.merged(intervals), events: events)
    }

    func pruneLaunchState(before date: Date) throws(FlightRecorderError) {
        // The actor owns the connection; each statement is finalized before returning.
        for sql in ["DELETE FROM launch_job_reads WHERE end < ?1", "UPDATE launch_job_reads SET start = ?1 WHERE start < ?1",
                    "DELETE FROM launch_job_state WHERE loaded = 0 AND time < ?1"] {
            let statement = unsafe try Self.prepare(sql, on: database)
            defer { unsafe sqlite3_finalize(statement) }
            unsafe sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            guard unsafe sqlite3_step(statement) == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        }
    }
}
