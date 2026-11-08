import Foundation
import SQLite3

extension FlightRecorder {
    static let processMemoryTables = """
        CREATE TABLE IF NOT EXISTS process_memory (lifetime INTEGER NOT NULL, time REAL NOT NULL, footprint INTEGER NOT NULL,
            measure TEXT NOT NULL, edges INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (lifetime, time)) WITHOUT ROWID;
        """

    static func migrateProcessMemory(_ handle: OpaquePointer) throws(FlightRecorderError) {
        // The migration transaction owns the connection; column checks finalize their statements before ALTER.
        unsafe try execute(processMemoryTables, on: handle)
        let columns = [("peak_footprint", "INTEGER"), ("peak_footprint_time", "REAL"), ("peak_footprint_measure", "TEXT")]
        for (column, type) in columns where unsafe try !hasColumn(column, in: "process_lifetimes", handle) {
            unsafe try execute("ALTER TABLE process_lifetimes ADD COLUMN \(column) \(type)", on: handle)
        }
        if unsafe try !hasColumn("memory", in: "process_watches", handle) {
            unsafe try execute("ALTER TABLE process_watches ADD COLUMN memory INTEGER NOT NULL DEFAULT 0", on: handle)
        }
    }

    /// Read-only callers may still have schema 6. Unknown memory is never
    /// backfilled from busy figures with another measure or cadence.
    func keepsProcessMemory() throws(FlightRecorderError) -> Bool {
        // The actor owns the connection for this table check.
        unsafe try Self.hasTable("process_memory", database)
    }

    static let memoryGrowthSQL = """
        (SELECT CASE WHEN COUNT(DISTINCT measure) = 1 THEN
            (SELECT footprint FROM process_memory WHERE lifetime = l.id ORDER BY time DESC LIMIT 1) -
            (SELECT footprint FROM process_memory WHERE lifetime = l.id ORDER BY time LIMIT 1) END
         FROM process_memory WHERE lifetime = l.id)
        """

    /// Stored steps, including the preceding anchor for the range. Edges
    /// distinguish a stopped watch from a steady process between readings.
    public func processMemory(_ lifetime: ProcessLifetime, from start: Date = .distantPast,
                              to end: Date = .distantFuture) throws(FlightRecorderError) -> [ProcessMemoryStep] {
        // The actor owns the connection; copied column values outlive the finalized statement.
        guard try keepsProcessMemory() else { return [] }
        let statement = unsafe try Self.prepare("""
            SELECT time, footprint, measure, edges FROM process_memory WHERE lifetime = ?1 AND time <= ?3
            AND time >= COALESCE((SELECT MAX(time) FROM process_memory WHERE lifetime = ?1 AND time <= ?2), ?2)
            ORDER BY time
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_int64(statement, 1, lifetime.id)
        unsafe sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        unsafe sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
        var steps: [ProcessMemoryStep] = []
        while unsafe sqlite3_step(statement) == SQLITE_ROW {
            guard let measure = unsafe Self.text(statement, 2).flatMap(ProcessMemoryMeasure.init(rawValue:)) else { continue }
            steps.append(unsafe ProcessMemoryStep(time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                                                  footprint: UInt64(clamping: sqlite3_column_int64(statement, 1)), measure: measure,
                                                  edges: Int(sqlite3_column_int(statement, 3))))
        }
        return steps
    }

    /// Exact recorded stretches for this lifetime, independent of chart
    /// buckets. Coarse buckets must never lend a reading to an unwatched gap.
    public func processMemoryCoverage(_ lifetime: ProcessLifetime, from start: Date,
                                      to end: Date) throws(FlightRecorderError) -> [ClosedRange<Date>] {
        // The actor owns the connection; each record time is copied before stepping again.
        guard try keepsProcessMemory() else { return [] }
        let statement = unsafe try Self.prepare("""
            SELECT time FROM records WHERE time >= ?1 AND time <= ?2 AND
            EXISTS (SELECT 1 FROM process_watches w WHERE w.memory = 1 AND w.started <= records.time AND w.last >= records.time)
            ORDER BY time
            """, on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe sqlite3_bind_double(statement, 1, max(start, lifetime.firstSeen).timeIntervalSince1970)
        let upper = min(end, lifetime.ended ?? lifetime.lastSeen)
        unsafe sqlite3_bind_double(statement, 2, upper.timeIntervalSince1970 + recordSpan)
        var coverage: [ClosedRange<Date>] = []
        var previous: Date?
        while unsafe sqlite3_step(statement) == SQLITE_ROW {
            let time = unsafe Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let lower = max(start, lifetime.firstSeen, time.addingTimeInterval(-recordSpan))
            let clipped = min(time, upper)
            guard lower <= clipped else { continue }
            if let previous, time.timeIntervalSince(previous) <= recordSpan * HistoryGap.spacing, let last = coverage.last {
                coverage[coverage.count - 1] = last.lowerBound...clipped
            } else {
                coverage.append(lower...clipped)
            }
            previous = time
        }
        return coverage
    }

    func pruneProcessMemory(before date: Date) throws(FlightRecorderError) {
        // The actor owns the connection; SQL clips one held anchor per lifetime at the retention boundary.
        guard try keepsProcessMemory() else { return }
        for sql in [
            """
            INSERT OR IGNORE INTO process_memory (lifetime, time, footprint, measure, edges)
            SELECT m.lifetime, ?1, m.footprint, m.measure, 1 FROM process_memory m
            WHERE m.time = (SELECT MAX(time) FROM process_memory WHERE lifetime = m.lifetime AND time < ?1)
                AND (m.edges & 2) = 0 AND EXISTS (SELECT 1 FROM process_lifetimes l WHERE l.id = m.lifetime)
            """,
            "DELETE FROM process_memory WHERE time < ?1 OR lifetime NOT IN (SELECT id FROM process_lifetimes)",
        ] {
            let statement = unsafe try Self.prepare(sql, on: database)
            defer { unsafe sqlite3_finalize(statement) }
            unsafe sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            guard unsafe sqlite3_step(statement) == SQLITE_DONE else { throw unsafe .sqlite(String(cString: sqlite3_errmsg(database))) }
        }
    }
}

extension ProcessHistoryWriter {
    func memory(_ updates: [ProcessMemoryUpdate], on handle: OpaquePointer) throws(FlightRecorderError) {
        // The caller's transaction owns the connection; both prepared statements are reused and finalized here.
        let insert = unsafe try FlightRecorder.prepare("""
            INSERT INTO process_memory (lifetime, time, footprint, measure, edges) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (lifetime, time) DO UPDATE SET footprint = excluded.footprint,
                measure = excluded.measure, edges = process_memory.edges | excluded.edges
            """, on: handle)
        defer { unsafe sqlite3_finalize(insert) }
        let peak = unsafe try FlightRecorder.prepare("""
            UPDATE process_lifetimes SET peak_footprint = ?1, peak_footprint_time = ?2, peak_footprint_measure = ?3
            WHERE id = ?4 AND (peak_footprint IS NULL OR peak_footprint < ?1 OR peak_footprint_measure != ?3)
            """, on: handle)
        defer { unsafe sqlite3_finalize(peak) }
        for update in updates {
            guard let row = unsafe try row(for: update.identity, on: handle) else { continue }
            if let step = update.step {
                unsafe sqlite3_reset(insert)
                unsafe sqlite3_bind_int64(insert, 1, row)
                unsafe sqlite3_bind_double(insert, 2, step.time.timeIntervalSince1970)
                unsafe sqlite3_bind_int64(insert, 3, Int64(clamping: step.footprint))
                unsafe FlightRecorder.bind(step.measure.rawValue, to: insert, at: 4)
                unsafe sqlite3_bind_int(insert, 5, Int32(step.edges))
                unsafe try Self.step(insert, on: handle)
            }
            if let figure = update.peak {
                unsafe sqlite3_reset(peak)
                unsafe sqlite3_bind_int64(peak, 1, Int64(clamping: figure.footprint))
                unsafe sqlite3_bind_double(peak, 2, figure.time.timeIntervalSince1970)
                unsafe FlightRecorder.bind(figure.measure.rawValue, to: peak, at: 3)
                unsafe sqlite3_bind_int64(peak, 4, row)
                unsafe try Self.step(peak, on: handle)
            }
        }
    }
}
