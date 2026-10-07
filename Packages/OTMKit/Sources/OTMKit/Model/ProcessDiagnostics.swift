import Foundation

/// One of a process's figures, or why there isn't one. macOS keeps most of
/// other users' and system processes' counters from anyone but an
/// administrator, so the inspector says so field by field.
public enum ProcessField<Value: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    case value(Value)
    /// macOS refused: another user's or a system process, which only an
    /// administrator (root) may read.
    case denied
    /// Not to be had: the process ended, or this macOS doesn't count it.
    case unavailable

    public var value: Value? {
        if case let .value(value) = self { return value }
        return nil
    }

    public func map<T>(_ transform: (Value) -> T) -> ProcessField<T> {
        switch self {
        case let .value(value): .value(transform(value))
        case .denied: .denied
        case .unavailable: .unavailable
        }
    }
}

/// Why reading a process failed.
public enum ProcessReadFailure: Error, Sendable, Hashable, Codable {
    /// macOS refused: another user's or a system process, which only an
    /// administrator (root) may read.
    case denied
    /// The process has ended, or its PID now belongs to a later process.
    case ended
    /// The call failed some other way.
    case unavailable

    /// The failure an `errno` from libproc stands for.
    public init(errno code: Int32) {
        switch code {
        case EPERM, EACCES: self = .denied
        case ESRCH: self = .ended
        default: self = .unavailable
        }
    }
}

/// A quality-of-service class: how urgent the process said its work was,
/// which steers the scheduler (and, on Apple silicon, which cores run it).
public enum QoSClass: String, Sendable, Codable, CaseIterable {
    case userInteractive, userInitiated, `default`, utility, background, maintenance, legacy

    public var title: String {
        switch self {
        case .userInteractive: "User interactive"
        case .userInitiated: "User initiated"
        case .default: "Default"
        case .utility: "Utility"
        case .background: "Background"
        case .maintenance: "Maintenance"
        case .legacy: "Legacy"
        }
    }
}

/// The part of a process's CPU time spent at one QoS class.
public struct QoSShare: Sendable, Hashable, Codable {
    public let qos: QoSClass
    public let seconds: Double
    /// Of the CPU time spent at any class, 0...1.
    public let fraction: Double

    /// The classes with any time, most first.
    public static func shares(_ seconds: [QoSClass: Double]) -> [QoSShare] {
        let total = seconds.values.filter { $0 > 0 }.reduce(0, +)
        guard total > 0 else { return [] }
        return QoSClass.allCases.compactMap { qos in
            guard let time = seconds[qos], time > 0 else { return nil }
            return QoSShare(qos: qos, seconds: time, fraction: time / total)
        }
        .sorted { $0.seconds > $1.seconds }
    }
}

/// Counters for one process beyond the table's figures, read for its
/// inspector. Counts are since the process started.
public struct ProcessDiagnostics: Sendable, Hashable, Codable {
    public let identity: ProcessIdentity
    /// When it was read, in seconds on a steady clock, for rates.
    public let time: TimeInterval
    public var footprint: ProcessField<UInt64>
    /// The most the footprint has been since the process started.
    public var peakFootprint: ProcessField<UInt64>
    public var resident: ProcessField<UInt64>
    /// Page faults: touches of memory that wasn't mapped in yet, most of them
    /// satisfied without the disk.
    public var faults: ProcessField<UInt64>
    /// Faults that had to read a page from disk: a file, or memory swapped out.
    public var pageIns: ProcessField<UInt64>
    public var copyOnWriteFaults: ProcessField<UInt64>
    public var contextSwitches: ProcessField<UInt64>
    /// BSD and Mach system calls together.
    public var systemCalls: ProcessField<UInt64>
    /// Mach messages sent and received.
    public var messages: ProcessField<UInt64>
    /// The task's base scheduling priority (31 for most processes).
    public var basePriority: ProcessField<Int32>
    public var policy: ProcessField<SchedulingPolicy>
    /// Threads running on a core as it was read.
    public var runningThreads: ProcessField<Int>
    /// CPU time by QoS class, most first.
    public var qos: ProcessField<[QoSShare]>

    public init(identity: ProcessIdentity, time: TimeInterval, footprint: ProcessField<UInt64>, peakFootprint: ProcessField<UInt64>,
                resident: ProcessField<UInt64>, faults: ProcessField<UInt64>, pageIns: ProcessField<UInt64>,
                copyOnWriteFaults: ProcessField<UInt64>, contextSwitches: ProcessField<UInt64>, systemCalls: ProcessField<UInt64>,
                messages: ProcessField<UInt64>, basePriority: ProcessField<Int32>, policy: ProcessField<SchedulingPolicy>,
                runningThreads: ProcessField<Int>, qos: ProcessField<[QoSShare]>) {
        self.identity = identity
        self.time = time
        self.footprint = footprint
        self.peakFootprint = peakFootprint
        self.resident = resident
        self.faults = faults
        self.pageIns = pageIns
        self.copyOnWriteFaults = copyOnWriteFaults
        self.contextSwitches = contextSwitches
        self.systemCalls = systemCalls
        self.messages = messages
        self.basePriority = basePriority
        self.policy = policy
        self.runningThreads = runningThreads
        self.qos = qos
    }

    /// A reading with every field missing for the same reason.
    public static func unreadable(_ identity: ProcessIdentity, at time: TimeInterval, because failure: ProcessReadFailure) -> ProcessDiagnostics {
        func none<T>() -> ProcessField<T> { failure == .denied ? .denied : .unavailable }
        return ProcessDiagnostics(
            identity: identity, time: time, footprint: none(), peakFootprint: none(), resident: none(), faults: none(),
            pageIns: none(), copyOnWriteFaults: none(), contextSwitches: none(), systemCalls: none(), messages: none(),
            basePriority: none(), policy: none(), runningThreads: none(), qos: none()
        )
    }
}

/// Per-second rates of a process's counters between two readings.
public struct ProcessRates: Sendable, Hashable {
    public var faults: ProcessField<Double>
    public var pageIns: ProcessField<Double>
    public var contextSwitches: ProcessField<Double>
    public var systemCalls: ProcessField<Double>
    public var messages: ProcessField<Double>

    /// `current`'s rates since `previous`. Without an earlier reading of the
    /// same process (a PID taken over by another process doesn't count), a
    /// rate is unavailable; where `current` was refused, it's denied.
    public init(_ current: ProcessDiagnostics, since previous: ProcessDiagnostics?) {
        let earlier = previous?.identity == current.identity ? previous : nil
        let interval = earlier.map { current.time - $0.time } ?? 0
        func rate(_ counter: KeyPath<ProcessDiagnostics, ProcessField<UInt64>>) -> ProcessField<Double> {
            let now = current[keyPath: counter]
            guard case let .value(count) = now else { return now.map { Double($0) } }
            guard interval > 0, let before = earlier?[keyPath: counter].value, count >= before else { return .unavailable }
            return .value(Double(count - before) / interval)
        }
        faults = rate(\.faults)
        pageIns = rate(\.pageIns)
        contextSwitches = rate(\.contextSwitches)
        systemCalls = rate(\.systemCalls)
        messages = rate(\.messages)
    }
}

extension Format {
    /// A counter in at most four figures: "8421", then "12.3K", "4.56M",
    /// "1.07B". Page faults and system calls run into the billions.
    public static func count(_ value: UInt64) -> String {
        guard value >= 10_000 else { return String(value) }
        let suffixes = ["K", "M", "B", "T"]
        var scaled = Double(value) / 1_000
        var index = 0
        // Up a unit before rounding would show 1000 of this one.
        while scaled >= 999.5, index < suffixes.count - 1 {
            scaled /= 1_000
            index += 1
        }
        return fixed(scaled, scaled < 9.995 ? 2 : scaled < 99.95 ? 1 : 0) + suffixes[index]
    }

    /// A counter's rate: to one place under 10 a second, then as `count`.
    public static func countRate(_ perSecond: Double) -> String {
        guard perSecond.isFinite, perSecond > 0 else { return "0/s" }
        if perSecond < 9.95 { return fixed(perSecond, 1) + "/s" }
        return count(UInt64(perSecond.rounded())) + "/s"
    }
}
