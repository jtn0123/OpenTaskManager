import Foundation

/// A process as its PID and when it started. macOS gives a PID to a new
/// process once the old one has ended, so anything kept about a process from
/// one sample to the next (its graphs, a selection, the counters its rates
/// come from) is keyed by this: a later process with the same PID is another
/// process, and starts with nothing.
public struct ProcessIdentity: Hashable, Sendable, Codable, CustomStringConvertible {
    public let pid: Int32
    /// When the process started; nil where it couldn't be read. Such a
    /// process matches only another without one.
    public let startTime: Date?

    public init(pid: Int32, startTime: Date?) {
        self.pid = pid
        self.startTime = startTime
    }

    public var description: String {
        "PID \(pid)" + (startTime.map { " started \($0.timeIntervalSince1970)" } ?? "")
    }

    /// A start time as the kernel gives it, in microseconds since 1970,
    /// converted the one way everywhere, so readings of a process compare equal.
    public static func startTime(microseconds: Int64) -> Date? {
        microseconds > 0 ? Date(timeIntervalSince1970: Double(microseconds) / 1_000_000) : nil
    }

    /// This process in `processes`, or nil once it has ended, even when a
    /// later process has its PID.
    public func find(in processes: [ProcessSample]) -> ProcessSample? {
        processes.first { $0.pid == pid && $0.startTime == startTime }
    }
}

extension ProcessSample {
    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: startTime)
    }
}
