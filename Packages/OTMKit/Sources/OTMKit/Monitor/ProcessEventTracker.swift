import Foundation

/// Finds busy background processes starting and exiting by comparing one
/// update's process list with the next, for the flight recorder's events.
///
/// Apps are left out: NSWorkspace tells their launches and quits as they
/// happen. And a process only counts once it has been busy, using at least
/// `busyPercent` of one core in an update, so the dozens of idle helpers
/// launchd starts and stops on demand don't bury the ones that coincide with
/// a spike. Its start time is its own (exact) when the system says it; its
/// exit is only known to lie between two updates, so it's approximate.
/// Those of one name within `window` seconds of each other make one event
/// with a count, held back until the window has passed: a build's compiler
/// runs, say.
public struct ProcessEventTracker: Sendable {
    /// Percent of one core (Activity Monitor's scale) a process must use in
    /// an update to count as busy.
    public static let busyPercent = 25.0
    /// Seconds over which events of one kind and name fold into one.
    public static let window: TimeInterval = 10

    /// One process, by PID and start time, so a recycled PID is another.
    private struct Key: Hashable {
        let pid: Int32
        let start: Double?
    }

    private struct Tracked {
        let name: String
        /// Running at the first update, or after a pause: its start wasn't seen.
        let preexisting: Bool
        /// When it was first seen, for a start time the system didn't give.
        let firstSeen: Date
        var busy = false
    }

    private var tracked: [Key: Tracked] = [:]
    private var lastUpdate: Date?
    /// Events found but held back, to fold in more of the same.
    private var pending: [HistoryEvent] = []

    public init() {}

    /// Takes one update's processes at `time`, leaving out those in `skipping`
    /// (the apps NSWorkspace reports), and returns the events whose window
    /// has passed, oldest first. After a pause longer than `window` (updates
    /// stopped, or the Mac slept) it starts afresh: what exited meanwhile
    /// can't be placed in time, and only a process whose own start time
    /// falls in the pause counts as started.
    public mutating func update(_ processes: [ProcessSample], skipping apps: Set<Int32>, at time: Date) -> [HistoryEvent] {
        let previous = lastUpdate
        let fresh = previous.map { time.timeIntervalSince($0) > Self.window || time < $0 } ?? true
        lastUpdate = time
        if fresh { tracked.removeAll(keepingCapacity: true) }

        var found: [HistoryEvent] = []
        var seen = Set<Key>()
        seen.reserveCapacity(processes.count)
        for process in processes {
            let key = Key(pid: process.pid, start: process.startTime?.timeIntervalSince1970)
            if apps.contains(process.pid) {
                // One that only now counts as an app (its policy settled
                // after it launched) is dropped, never taken for an exit.
                tracked[key] = nil
                continue
            }
            seen.insert(key)
            var entry = tracked[key] ?? Tracked(name: process.name, preexisting: fresh && !Self.started(process, after: previous),
                                                firstSeen: time)
            if !entry.busy, process.cpuPercent >= Self.busyPercent {
                entry.busy = true
                if !entry.preexisting {
                    // The system's own start time is exact; failing that, it
                    // began some time before it was first seen.
                    let start = process.startTime.flatMap { $0 <= time ? $0 : nil }
                    found.append(HistoryEvent(time: start ?? entry.firstSeen, kind: .processStarted, name: entry.name,
                                              isApproximate: start == nil))
                }
            }
            tracked[key] = entry
        }
        if !fresh, let previous {
            // Gone since the last update: it exited somewhere in between.
            let exit = previous.addingTimeInterval(time.timeIntervalSince(previous) / 2)
            for (key, entry) in tracked where !seen.contains(key) {
                if entry.busy {
                    found.append(HistoryEvent(time: exit, kind: .processExited, name: entry.name, isApproximate: true))
                }
                tracked[key] = nil
            }
        }

        guard !found.isEmpty || !pending.isEmpty else { return [] }
        pending = HistoryEvent.merged((pending + found).sorted { $0.time < $1.time }, within: Self.window)
        let due = pending.filter { time.timeIntervalSince($0.time) >= Self.window }
        pending.removeAll { time.timeIntervalSince($0.time) >= Self.window }
        return due
    }

    /// Whether `process` says it started after `time` (and there was such a time).
    private static func started(_ process: ProcessSample, after time: Date?) -> Bool {
        guard let time, let start = process.startTime else { return false }
        return start > time
    }

    /// The events still held back, for when recording stops.
    public mutating func flush() -> [HistoryEvent] {
        defer { pending = [] }
        return pending
    }
}
