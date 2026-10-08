import Foundation
import SQLite3

/// Job observations are separate from recording-file events: a replay carries none.
extension FlightRecorder {
    static let launchJobTables = """
        CREATE TABLE IF NOT EXISTS launch_job_events (id INTEGER PRIMARY KEY, label TEXT NOT NULL, domain TEXT NOT NULL,
            time REAL NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS launch_job_events_job ON launch_job_events (label, domain, time);
        CREATE INDEX IF NOT EXISTS launch_job_events_time ON launch_job_events (time);
        CREATE UNIQUE INDEX IF NOT EXISTS launch_job_events_once ON launch_job_events (label, domain, kind, CAST(time AS INTEGER));
        """ + launchStateTables

    public func keepsLaunchJobHistory() throws(FlightRecorderError) -> Bool {
        // The connection is owned by this actor; the helper finalizes its statement.
        unsafe try Self.hasTable("launch_job_events", database)
    }

    public func appendLaunchJobEvents(_ events: [LaunchHistoryEvent]) throws(FlightRecorderError) {
        guard !events.isEmpty else { return }
        try writeLaunchHistory(events)
    }

    func writeLaunchHistory(_ events: [LaunchHistoryEvent], states: [LaunchHistoryState] = [],
                            reads: [LaunchHistoryReadChange] = []) throws(FlightRecorderError) {
        // Coverage, baselines and events commit together; a failed write advances none of them.
        // The actor owns the live connection, and SQLite borrows no pointers beyond these calls.
        let rows = launchWriter.readRows
        unsafe try Self.execute("BEGIN IMMEDIATE", on: database)
        do throws(FlightRecorderError) {
            try insertLaunchEvents(events)
            try writeLaunchStates(states)
            try writeLaunchReads(reads)
            unsafe try Self.execute("COMMIT", on: database)
        } catch {
            unsafe sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            launchWriter.readRows = rows
            throw error
        }
    }

    private func insertLaunchEvents(_ events: [LaunchHistoryEvent]) throws(FlightRecorderError) {
        guard !events.isEmpty else { return }
        // The actor owns the live connection; bound strings are copied and this statement is finalized after its batch.
        let statement = unsafe try Self.prepare("""
            INSERT OR IGNORE INTO launch_job_events (label, domain, time, kind, payload) VALUES (?, ?, ?, ?, ?)
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        for event in events {
            let payload: Data
            do { payload = try JSONEncoder().encode(event) } catch { throw .sqlite(error.localizedDescription) }
            unsafe sqlite3_reset(statement)
            unsafe sqlite3_clear_bindings(statement)
            unsafe Self.bind(event.key.label, to: statement, at: 1)
            unsafe Self.bind(event.key.domain, to: statement, at: 2)
            unsafe sqlite3_bind_double(statement, 3, event.time.timeIntervalSince1970)
            unsafe Self.bind(event.kind.rawValue, to: statement, at: 4)
            unsafe Self.bind(String(decoding: payload, as: UTF8.self), to: statement, at: 5)
            guard unsafe sqlite3_step(statement) == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        }
    }

    /// Exact label matching; an omitted domain returns both agents and daemons.
    public func launchJobEvents(label: String, domain: String? = nil, from start: Date, to end: Date) throws(FlightRecorderError)
        -> [LaunchHistoryEvent] {
        guard try keepsLaunchJobHistory() else { return [] }
        // The actor owns the connection; column strings are copied before stepping and the statement is finalized here.
        let statement = unsafe try Self.prepare("""
            SELECT payload FROM launch_job_events WHERE label = ?1 AND (?2 = '' OR domain = ?2)
                AND time >= ?3 AND time <= ?4 ORDER BY time, id
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe Self.bind(label, to: statement, at: 1)
        unsafe Self.bind(domain ?? "", to: statement, at: 2)
        unsafe sqlite3_bind_double(statement, 3, start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 4, end.timeIntervalSince1970)
        return unsafe try Self.readLaunchEvents(statement, on: database)
    }

    func launchJobConfigurations() throws(FlightRecorderError) -> [LaunchHistoryKey: LaunchJobConfiguration] {
        // Only configuration changes are read at launch, not the week's entire timeline.
        // The actor owns the connection; copied payloads outlive this finalized statement.
        let statement = unsafe try Self.prepare("""
            SELECT payload FROM launch_job_events e WHERE kind = 'configuration' AND id =
                (SELECT id FROM launch_job_events WHERE label = e.label AND domain = e.domain AND kind = 'configuration'
                 ORDER BY time DESC, id DESC LIMIT 1)
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        let events = unsafe try Self.readLaunchEvents(statement, on: database)
        return Dictionary(events.compactMap { event in event.configuration.map { (event.key, $0) } }, uniquingKeysWith: { _, new in new })
    }

    func pruneLaunchJobs(before date: Date) throws(FlightRecorderError) {
        guard try keepsLaunchJobHistory() else { return }
        // The actor owns the live connection and finalizes this statement after the delete.
        let statement = unsafe try Self.prepare("DELETE FROM launch_job_events WHERE time < ?", on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        guard unsafe sqlite3_step(statement) == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        try pruneLaunchState(before: date)
    }

    private static func readLaunchEvents(_ statement: OpaquePointer, on handle: OpaquePointer) throws(FlightRecorderError)
        -> [LaunchHistoryEvent] {
        // The caller owns the connection and statement; each SQLite text value is copied before the next step.
        var events: [LaunchHistoryEvent] = []
        var status = unsafe sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let payload = unsafe Self.text(statement, 0) else { throw .sqlite("Missing launch job event") }
            do {
                events.append(try JSONDecoder().decode(LaunchHistoryEvent.self, from: Data(payload.utf8)))
            } catch {
                throw .sqlite(error.localizedDescription)
            }
            status = unsafe sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(handle))) }
        return events
    }
}

/// Baselines belong to the recorder actor; a failed write leaves them unchanged.
struct LaunchHistoryWriter: Sendable {
    var tracker = LaunchHistoryTracker()
    var configured = false
    var items: [LaunchHistoryKey: LaunchItem] = [:]
    var known: Set<LaunchHistoryKey> = []
    var states: [LaunchHistoryKey: LaunchHistoryState] = [:]
    var reads = LaunchHistoryReadTracker()
    var readRows: [String: Int64] = [:]
}

extension FlightRecorder {
    /// Reuses the baselines already loaded and updated by the bulk observation.
    /// The page needs their original times, without another query for every job.
    public func launchJobObservedStates() -> [LaunchHistoryKey: LaunchHistoryState] { launchWriter.states }

    /// Configuration reads have their own clock, so they don't invent a job-state read.
    public func observeLaunchConfiguration(_ item: LaunchItem, at time: Date) throws(FlightRecorderError) {
        guard item.hasFile, !item.isUnreadable, !item.isMissingLabel else { return }
        let key = LaunchHistoryKey(item)
        let configuration = LaunchJobConfiguration(item)
        let saved = try launchJobConfigurations()
        if saved[key] != configuration {
            let event = LaunchHistoryEvent(key: key, time: time, kind: .configuration,
                                           detail: saved[key] == nil ? "Configuration first read" : "Configuration changed · time unknown",
                                           configuration: configuration)
            try appendLaunchJobEvents([event])
        }
        launchWriter.items[key] = item
        launchWriter.tracker.noteConfiguration(configuration, for: key)
    }

    public func observeLaunchJobs(_ reading: LaunchJobReading, items scanned: [LaunchItem]? = nil,
                                  starts: [Int32: Date] = [:]) throws(FlightRecorderError) {
        var next = launchWriter
        if !next.configured {
            next.states = try launchJobStates()
            next.known.formUnion(next.states.keys)
            next.tracker.seedStates(next.states, lastReads: try launchJobLastReads())
            next.tracker.seedConfigurations(try launchJobConfigurations())
            next.configured = true
        }
        if let scanned {
            for item in scanned where item.hasFile && !item.isMissingLabel && !item.isUnreadable { next.items[LaunchHistoryKey(item)] = item }
        }
        for domain in next.reads.domains where reading.domains[domain] == nil {
            next.reads.interrupt(domain: domain, at: reading.time)
        }
        var events: [LaunchHistoryEvent] = []
        var states: [LaunchHistoryState] = []
        var reads: [LaunchHistoryReadChange] = []
        for (domain, jobs) in reading.domains {
            guard let change = next.reads.observe(domain: domain, at: reading.time) else { continue }
            reads.append(change)
            next.known.formUnion(jobs.keys.map { LaunchHistoryKey(label: $0, domain: domain) })
            let keys = next.known.filter { $0.domain == domain }.union(next.items.keys.filter { $0.domain == domain })
            for key in keys {
                let job = jobs[key.label]
                let saved = next.states[key]
                let started = job?.pid.flatMap { starts[$0] } ?? (saved?.pid == job?.pid ? saved?.started : nil)
                let snapshot = LaunchHistorySnapshot(key: key, time: reading.time, job: job, started: started,
                                                     configuration: next.items[key].map(LaunchJobConfiguration.init),
                                                     keepsAlive: next.items[key]?.triggers.keepAlive == .always)
                events += next.tracker.observe(snapshot, continuous: change.extends)
                if saved?.matches(snapshot) != true {
                    let state = LaunchHistoryState(snapshot)
                    states.append(state)
                    next.states[key] = state
                }
            }
        }
        guard !reads.isEmpty else { launchWriter = next; return }
        try writeLaunchHistory(events, states: states, reads: reads)
        next.readRows = launchWriter.readRows
        launchWriter = next
    }
}
