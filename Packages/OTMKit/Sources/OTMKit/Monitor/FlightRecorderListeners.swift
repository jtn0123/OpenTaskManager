import Foundation
import SQLite3

extension FlightRecorder {
    static let listenerTables = """
        CREATE TABLE IF NOT EXISTS listener_review (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL);
        """

    /// Older databases read as unset without being migrated by a read-only CLI.
    public func listenerReview() throws(FlightRecorderError) -> ListenerReview? {
        // The actor owns the handle; the statement is finalized after copying its text.
        guard unsafe try Self.hasTable("listener_review", database) else { return nil }
        let statement = unsafe try Self.prepare("SELECT payload FROM listener_review WHERE id = 1", on: database)
        defer { unsafe sqlite3_finalize(statement) }
        let result = unsafe sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let text = unsafe Self.text(statement, 0) else {
            throw unsafe .sqlite(String(cString: sqlite3_errmsg(database)))
        }
        do { return try JSONDecoder().decode(ListenerReview.self, from: Data(text.utf8)) } catch {
            throw .sqlite(error.localizedDescription)
        }
    }

    /// Read and merge under one lock, so another app copy's acceptance is never overwritten by a stale walk.
    public func observeListeners(_ listeners: [ListenerObservation], confirmed: [ListenerObservation],
                                 at time: Date) throws(FlightRecorderError) -> (review: ListenerReview, newChanges: Int) {
        var newChanges = 0
        let review = try updateListenerReview { stored in
            var review = stored ?? ListenerReview(baseline: ListenerBaseline(listeners: Set(listeners.map(\.identity)), at: time))
            if stored != nil { review.record(confirmed, at: time) }
            newChanges = review.changes.count - (stored?.changes.count ?? 0)
            return review
        }
        guard let review else { throw .sqlite("Listener baseline could not be set") }
        return (review, newChanges)
    }

    public func acceptListeners(_ identities: Set<ListenerIdentity>, at time: Date = .now) throws(FlightRecorderError) -> ListenerReview? {
        try updateListenerReview { stored in
            guard var review = stored else { return nil }
            review.accept(identities, at: time)
            return review
        }
    }

    private func updateListenerReview(_ update: (ListenerReview?) -> ListenerReview?) throws(FlightRecorderError) -> ListenerReview? {
        // SQLite owns this live actor's handle and copies the bound payload before the string borrow ends.
        unsafe try Self.execute("BEGIN IMMEDIATE", on: database)
        do throws(FlightRecorderError) {
            let stored = try listenerReview()
            let result = update(stored)
            if let review = result, review != stored { try writeListenerReview(review) }
            unsafe try Self.execute("COMMIT", on: database)
            return result
        } catch {
            unsafe sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func writeListenerReview(_ review: ListenerReview) throws(FlightRecorderError) {
        let payload: Data
        do { payload = try JSONEncoder().encode(review) } catch { throw .sqlite(error.localizedDescription) }
        // The actor owns the handle and finalizes this statement; SQLite copies the bound text.
        let statement = unsafe try Self.prepare("INSERT OR REPLACE INTO listener_review VALUES (1, ?)", on: database)
        defer { unsafe sqlite3_finalize(statement) }
        unsafe Self.bind(String(decoding: payload, as: UTF8.self), to: statement, at: 1)
        guard unsafe sqlite3_step(statement) == SQLITE_DONE else {
            throw unsafe .sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }
}
