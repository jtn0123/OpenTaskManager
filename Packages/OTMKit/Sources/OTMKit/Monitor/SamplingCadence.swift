import Foundation

/// A slow source keeps a baseline even when nobody shows it. Time is
/// monotonic seconds, so changing the wall clock cannot delay a read.
public struct SamplingCadence: Sendable {
    public let idleInterval: TimeInterval
    public private(set) var lastRead: TimeInterval?
    private let primingReads: Int
    private var reads = 0

    public init(idleInterval: TimeInterval = 5, primingReads: Int = 1) {
        self.idleInterval = idleInterval
        self.primingReads = max(primingReads, 1)
    }

    /// Live consumers need every tick; otherwise the last reading is held.
    /// A required read can serve a recorder without changing the live demand.
    /// Rate sources take two priming reads before holding a measured value.
    public mutating func shouldRead(at time: TimeInterval, live: Bool, required: Bool = false) -> Bool {
        guard reads < primingReads || live || required || lastRead.map({ time - $0 >= idleInterval }) ?? true else { return false }
        reads = min(reads + 1, primingReads)
        lastRead = time
        return true
    }
}

/// More than one window or card can show a source. One leaving must not
/// slow the source while another still shows it.
public struct SamplingDemand: Sendable {
    public enum Source: Sendable, Hashable {
        case sensors, restrictedProcesses, users, sensorTable, menuBarIcon
    }

    private var counts: [Source: Int] = [:]

    public init() {}

    public func contains(_ source: Source) -> Bool { counts[source, default: 0] > 0 }

    public mutating func add(_ source: Source) { counts[source, default: 0] += 1 }

    public mutating func remove(_ source: Source) {
        counts[source] = max(counts[source, default: 0] - 1, 0)
    }
}
