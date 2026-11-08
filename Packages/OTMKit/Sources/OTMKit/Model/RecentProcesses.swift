import Foundation

/// The last sample of a process no longer seen on a subsequent walk. This
/// records an observation window, not an exact exit time or an exit reason.
public struct RecentlyEndedProcess: Sendable, Equatable, Identifiable {
    public let process: ProcessSample
    public let firstSeen: Date
    public let lastSeen: Date
    public let missingAt: Date
    public let observedUptime: TimeInterval
    public var id: ProcessIdentity { process.identity }

    public var lifetime: ProcessLifetime {
        ProcessLifetime(id: 0, identity: id, name: process.name, path: process.executablePath,
                        user: process.userName, isRestricted: process.isRestricted,
                        firstSeen: firstSeen, lastSeen: lastSeen, ended: missingAt)
    }
}

/// A bounded, session-only list, independent of flight recording. Every
/// baseline and retained entry uses PID + start time, never PID alone.
public struct RecentProcesses: Sendable {
    public static let retention: TimeInterval = 60
    public static let capacity = 200

    private struct Seen: Sendable {
        let process: ProcessSample
        let firstSeen: Date
        let lastSeen: Date
    }

    public private(set) var entries: [RecentlyEndedProcess] = []
    private var previous: [ProcessIdentity: Seen] = [:]
    private var lastUptime: TimeInterval?
    private var previousDate: Date?
    private var previousStep: TimeInterval = 1
    private var previousUID: UInt32?

    public init() {}

    /// nil samples mean processes weren't read. An empty walk is also
    /// treated as unavailable: a real walk must at least contain OTM itself.
    /// A scope or cadence gap resets the baseline instead of inventing exits.
    public mutating func update(_ samples: [ProcessSample]?, at date: Date, uptime: TimeInterval,
                                step: TimeInterval, userID: UInt32? = nil) {
        expire(at: uptime)
        if let userID { entries.removeAll { $0.process.uid != userID } }
        guard uptime.isFinite, step.isFinite, step > 0, let samples, !samples.isEmpty else {
            resetBaseline()
            return
        }
        // Ignore duplicate/out-of-order deliveries rather than comparing an
        // older sample against a newer one (Refresh can overlap sampling).
        if let lastUptime, uptime <= lastUptime { return }
        if let previousDate, date <= previousDate {
            resetBaseline()
            return
        }
        let continuous = lastUptime.map { uptime - $0 <= max(step, previousStep) * 1.5 + 0.1 } ?? false
        let sameScope = previousUID == userID
        let old = previous
        var current: [ProcessIdentity: Seen] = [:]
        var byPID: [Int32: ProcessIdentity] = [:]
        current.reserveCapacity(samples.count)
        for process in samples where userID == nil || process.uid == userID {
            let identity = process.identity
            current[identity] = Seen(process: process, firstSeen: old[identity]?.firstSeen ?? date, lastSeen: date)
            byPID[process.pid] = identity
        }
        // A reappearing identity retracts a transient omission, and can never
        // inherit controls or details from a previous process with that PID.
        entries.removeAll { current[$0.id] != nil }
        if continuous, sameScope {
            var ended: [RecentlyEndedProcess] = []
            for (identity, seen) in old where current[identity] == nil {
                // Permission changes can add or remove the start time of the
                // same PID. That is not enough evidence of an ended process.
                if let currentID = byPID[identity.pid], identity.startTime == nil || currentID.startTime == nil { continue }
                ended.append(RecentlyEndedProcess(process: seen.process, firstSeen: seen.firstSeen, lastSeen: seen.lastSeen,
                                                   missingAt: date, observedUptime: uptime))
            }
            if !ended.isEmpty {
                let replaced = Set(ended.map(\.id))
                entries.removeAll { replaced.contains($0.id) }
                entries += ended
                entries.sort {
                    if $0.observedUptime != $1.observedUptime { return $0.observedUptime > $1.observedUptime }
                    if $0.process.pid != $1.process.pid { return $0.process.pid < $1.process.pid }
                    return ($0.id.startTime ?? .distantPast) > ($1.id.startTime ?? .distantPast)
                }
                if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
            }
        }
        previous = current
        lastUptime = uptime
        previousDate = date
        previousStep = step
        previousUID = userID
    }

    public mutating func expire(at uptime: TimeInterval) {
        guard uptime.isFinite else { return }
        entries.removeAll { uptime - $0.observedUptime >= Self.retention || uptime < $0.observedUptime }
    }

    /// A pause, unread interval or a scope change isn't an observed exit.
    public mutating func resetBaseline() {
        previous.removeAll(keepingCapacity: true)
        lastUptime = nil
        previousDate = nil
    }

    /// Clearing the list doesn't forget live identities or rediscover old exits.
    public mutating func clear() { entries.removeAll(keepingCapacity: true) }
}
