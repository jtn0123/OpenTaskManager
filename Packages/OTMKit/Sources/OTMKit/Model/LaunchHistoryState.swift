import Foundation

/// The last changed job state, not the last read. Unchanged sightings don't
/// move its time on or write another row, so it remains a useful bound at relaunch.
public struct LaunchHistoryState: Sendable, Codable, Hashable {
    public let key: LaunchHistoryKey
    public let time: Date
    public let loaded: Bool
    public let pid: Int32?
    public let started: Date?
    public let lastExit: LaunchExitStatus?

    public init(_ snapshot: LaunchHistorySnapshot) {
        key = snapshot.key
        time = snapshot.time
        loaded = snapshot.job != nil
        pid = snapshot.job?.pid
        started = snapshot.instance?.started
        lastExit = snapshot.job?.lastExit
    }

    public func matches(_ snapshot: LaunchHistorySnapshot) -> Bool {
        guard key == snapshot.key, loaded == (snapshot.job != nil), pid == snapshot.job?.pid,
              lastExit == snapshot.job?.lastExit else { return false }
        // A read without process start times doesn't erase a known identity.
        guard let current = snapshot.instance?.started else { return true }
        return started.map { abs(current.timeIntervalSince($0)) < 1 } ?? false
    }

    public var snapshot: LaunchHistorySnapshot {
        LaunchHistorySnapshot(key: key, time: time,
                              job: loaded ? LaunchJobStatus(label: key.label, pid: pid, lastExit: lastExit) : nil, started: started)
    }
}
