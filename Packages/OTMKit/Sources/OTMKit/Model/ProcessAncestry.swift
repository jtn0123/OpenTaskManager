import Foundation

/// The processes that started a process, one parent at a time, up to launchd.
public struct ProcessAncestry: Sendable, Hashable {
    /// Why the walk stopped short of launchd.
    public enum Gap: Sendable, Hashable {
        /// The parent with this PID isn't in the sample: it ended between
        /// samples, or it isn't sampled (system processes switched off).
        case notListed(Int32)
        /// The PID belongs to a process younger than its supposed child: the
        /// real parent ended and a later process was given its PID.
        case replaced(Int32)

        public var pid: Int32 {
            switch self {
            case let .notListed(pid), let .replaced(pid): pid
            }
        }
    }

    /// From the oldest ancestor found down to the process itself, which is last.
    public let chain: [ProcessSample]
    /// Set when the walk stopped before reaching the top.
    public let gap: Gap?

    /// The ancestors alone, oldest first.
    public var ancestors: ArraySlice<ProcessSample> { chain.dropLast() }

    /// Walks `process`'s parents in `processes` (one sample's, by PID). Stops
    /// at launchd, whose parent is the kernel (PID 0), at a parent that's gone
    /// or younger than its child, at a loop, and after `limit` steps.
    public static func build(for process: ProcessSample, in processes: [Int32: ProcessSample], limit: Int = 32) -> ProcessAncestry {
        var chain = [process]
        var seen: Set<Int32> = [process.pid]
        var current = process
        var gap: Gap?
        while chain.count < limit {
            let parentPID = current.parentPID
            guard parentPID > 0, !seen.contains(parentPID) else { break }
            guard let parent = processes[parentPID] else {
                gap = .notListed(parentPID)
                break
            }
            guard startedNoLater(parent, than: current) else {
                gap = .replaced(parentPID)
                break
            }
            chain.append(parent)
            seen.insert(parentPID)
            current = parent
        }
        return ProcessAncestry(chain: chain.reversed(), gap: gap)
    }

    /// `build` over a sample's list.
    public static func build(for process: ProcessSample, in processes: [ProcessSample], limit: Int = 32) -> ProcessAncestry {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return build(for: process, in: byPID, limit: limit)
    }

    /// A parent can't start after its child; one that did took over an ended parent's PID.
    private static func startedNoLater(_ parent: ProcessSample, than child: ProcessSample) -> Bool {
        guard let parentStart = parent.startTime, let childStart = child.startTime else { return true }
        return parentStart <= childStart
    }
}
