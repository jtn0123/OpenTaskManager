import Foundation
import OSLog
import OTMKit

/// The page and background scheduler share one watch, and database writes stay off the main actor.
actor ConnectionHistoryWorker {
    struct Reading: Sendable {
        let snapshot: ConnectionSnapshot
        let watch: ConnectionWatch
        let listeners: ListenerReading
    }
    var listenerRecorder: FlightRecorder?
    var listenerReader = ListenerIdentityReader()
    var listenerDebounce = ListenerDebounce()
    private var watch = ConnectionWatch(maximumSpacing: 121)
    private var history = ConnectionHistoryTracker()
    private var lastSpacing: TimeInterval = 3
    /// After a start or a stop, the first walk looks up stored rows it can carry on.
    private var looksForStoredRows = true
    private static let log = Logger(subsystem: "OpenTaskManager", category: "ConnectionHistory")

    func read(recorder: FlightRecorder?, spacing: TimeInterval, processes: [ProcessIdentity: ConnectionProcess],
              reviewsListeners: Bool = true) async -> Reading {
        let snapshot = ConnectionSampler.sample()
        watch.maximumSpacing = max(spacing, lastSpacing) * 2 + 1
        lastSpacing = spacing
        watch.observe(snapshot.connections, at: snapshot.time)
        var next = history
        var metadata = snapshot.processes
        for (identity, process) in processes {
            metadata[identity] = ConnectionProcess(name: process.name, path: process.path ?? metadata[identity]?.path,
                                                   user: process.user)
        }
        var resumable: [String: ConnectionLifetime] = [:]
        if let recorder, looksForStoredRows {
            // One indexed lookup per start, by the keys of the sockets open now.
            let keys = watch.open.compactMap(\.connection.historyKey)
            do { resumable = try await recorder.resumableConnections(keys: keys) } catch {
                Self.log.error("Socket history lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let listeners = await readListeners(snapshot, processes: metadata, recorder: recorder,
                                            maximumSpacing: watch.maximumSpacing, enabled: reviewsListeners)
        let batch = next.observe(watch, at: snapshot.time, spacing: spacing, hidden: snapshot.hiddenProcesses,
                                 unreadable: snapshot.unreadablePIDs, processes: metadata, resumable: resumable)
        if let recorder {
            do {
                try await recorder.appendConnections(batch)
                history = next
                looksForStoredRows = false
            } catch { Self.log.error("Socket history write failed: \(error.localizedDescription, privacy: .public)") }
        }
        Self.log.debug("Socket walk: wall \(snapshot.duration, privacy: .public) s, thread CPU \(snapshot.cpuDuration, privacy: .public) s")
        return Reading(snapshot: snapshot, watch: watch, listeners: listeners)
    }

    func stop(recorder: FlightRecorder?) async {
        listenerDebounce.stop()
        var next = history
        let batch = next.stop()
        if let recorder {
            do {
                try await recorder.appendConnections(batch)
                history = next
                looksForStoredRows = true
            } catch { Self.log.error("Socket history end failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
