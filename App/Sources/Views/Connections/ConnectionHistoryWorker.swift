import Foundation
import OSLog
import OTMKit

/// The page and background scheduler share one watch, and database writes stay off the main actor.
actor ConnectionHistoryWorker {
    struct Reading: Sendable {
        let snapshot: ConnectionSnapshot
        let watch: ConnectionWatch
    }
    private var watch = ConnectionWatch(maximumSpacing: 121)
    private var history = ConnectionHistoryTracker()
    private var lastSpacing: TimeInterval = 3
    private static let log = Logger(subsystem: "OpenTaskManager", category: "ConnectionHistory")

    func read(recorder: FlightRecorder?, spacing: TimeInterval, processes: [ProcessIdentity: ConnectionProcess]) async -> Reading {
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
        let batch = next.observe(watch, at: snapshot.time, spacing: spacing, hidden: snapshot.hiddenProcesses,
                                 unreadable: snapshot.unreadablePIDs, processes: metadata)
        if let recorder {
            do {
                try await recorder.appendConnections(batch)
                history = next
            } catch { Self.log.error("Socket history write failed: \(error.localizedDescription, privacy: .public)") }
        }
        Self.log.debug("Socket walk: wall \(snapshot.duration, privacy: .public) s, thread CPU \(snapshot.cpuDuration, privacy: .public) s")
        return Reading(snapshot: snapshot, watch: watch)
    }

    func stop(recorder: FlightRecorder?) async {
        var next = history
        let batch = next.stop()
        if let recorder {
            do {
                try await recorder.appendConnections(batch)
                history = next
            } catch { Self.log.error("Socket history end failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
