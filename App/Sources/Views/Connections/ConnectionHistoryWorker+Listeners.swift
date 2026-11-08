import Foundation
import OTMKit

extension ConnectionHistoryWorker {
    struct ListenerReading: Sendable {
        var review: ListenerReview?
        var unreadable = 0
        var newChanges = 0
        var error: String?
    }

    /// Listener review remains available with recording off, in the same database but outside record retention.
    private func recorderForListeners(_ recorder: FlightRecorder?) throws -> FlightRecorder {
        if let recorder { listenerRecorder = recorder; return recorder }
        if let listenerRecorder { return listenerRecorder }
        let opened = try FlightRecorder(url: FlightRecorder.defaultURL)
        listenerRecorder = opened
        return opened
    }

    func readListeners(_ snapshot: ConnectionSnapshot, processes: [ProcessIdentity: ConnectionProcess],
                       recorder: FlightRecorder?, maximumSpacing: TimeInterval, enabled: Bool) async -> ListenerReading {
        guard enabled else { return ListenerReading() }
        let reading = listenerReader.read(snapshot, processes: processes)
        let confirmed = listenerDebounce.observe(reading.listeners, at: snapshot.time, maximumSpacing: maximumSpacing)
        do {
            let persistence = try recorderForListeners(recorder)
            let update = try await persistence.observeListeners(reading.listeners, confirmed: confirmed, at: snapshot.time)
            return ListenerReading(review: update.review, unreadable: reading.unreadableProcesses, newChanges: update.newChanges)
        } catch {
            return ListenerReading(unreadable: reading.unreadableProcesses, error: error.localizedDescription)
        }
    }

    func acceptListeners(_ identities: Set<ListenerIdentity>) async throws -> ListenerReview? {
        let recorder = try recorderForListeners(nil)
        return try await recorder.acceptListeners(identities)
    }
}
