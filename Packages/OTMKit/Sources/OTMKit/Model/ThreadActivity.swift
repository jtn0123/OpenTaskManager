import Foundation

/// What a thread is doing, from the kernel's run state.
public enum ThreadRunState: String, Sendable, Codable, CaseIterable {
    case running
    /// Waiting for something: a lock, a message, a timer, work.
    case waiting
    /// Waiting where it can't be interrupted, usually for the disk.
    case blocked
    case stopped
    case halted
    case unknown

    /// `TH_STATE_*` from <sys/proc_info.h>.
    public init(kernelValue: Int32) {
        switch kernelValue {
        case 1: self = .running
        case 2: self = .stopped
        case 3: self = .waiting
        case 4: self = .blocked
        case 5: self = .halted
        default: self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .stopped: "Stopped"
        case .halted: "Halted"
        case .unknown: "Unknown"
        }
    }

    /// Order for sorting by state, most active first.
    var rank: Int {
        switch self {
        case .running: 0
        case .blocked: 1
        case .waiting: 2
        case .stopped: 3
        case .halted: 4
        case .unknown: 5
        }
    }
}

/// How the scheduler shares the CPU with a thread or task (`POLICY_*` in <mach/policy.h>).
public enum SchedulingPolicy: String, Sendable, Codable {
    /// The usual policy: priority rises and falls with how much CPU it uses.
    case timesharing
    /// Fixed priority, taking turns with equal ones.
    case roundRobin
    /// Fixed priority, running until it blocks.
    case fifo
    case unknown

    public init(kernelValue: Int32) {
        switch kernelValue {
        case 1: self = .timesharing
        case 2: self = .roundRobin
        case 4: self = .fifo
        default: self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .timesharing: "Time sharing"
        case .roundRobin: "Round robin"
        case .fifo: "Fixed (FIFO)"
        case .unknown: "Unknown"
        }
    }
}

/// One thread of a process as the kernel reports it.
public struct ThreadSample: Sendable, Hashable, Codable, Identifiable {
    /// The kernel's thread ID, unique until restart: the number `sample` and
    /// debuggers show for it.
    public let id: UInt64
    /// Its name, set by the process (`pthread_setname_np`); nil when it has none.
    public let name: String?
    /// CPU time in seconds since the thread started.
    public let userTime: Double
    public let systemTime: Double
    public let state: ThreadRunState
    /// Scheduling priority now (0 to 127; 31 is a normal user thread's) and
    /// the base it returns to.
    public let priority: Int32
    public let basePriority: Int32
    public let policy: SchedulingPolicy

    public init(id: UInt64, name: String?, userTime: Double, systemTime: Double, state: ThreadRunState,
                priority: Int32, basePriority: Int32, policy: SchedulingPolicy) {
        self.id = id
        self.name = name
        self.userTime = userTime
        self.systemTime = systemTime
        self.state = state
        self.priority = priority
        self.basePriority = basePriority
        self.policy = policy
    }

    public var cpuTime: Double { userTime + systemTime }
}

/// A thread with the CPU it used since the reading before.
public struct ThreadActivity: Sendable, Hashable, Identifiable, Codable {
    public var id: UInt64 { thread.id }
    public let thread: ThreadSample
    /// CPU over the interval, where 100 is one core, as for processes. nil
    /// on the first reading, which has nothing to compare with.
    public let cpuPercent: Double?

    public init(thread: ThreadSample, cpuPercent: Double?) {
        self.thread = thread
        self.cpuPercent = cpuPercent
    }
}

public enum ThreadSortKey: String, Sendable, CaseIterable {
    case cpu, cpuTime, name, id, state, priority

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .cpuTime: "CPU time"
        case .name: "Name"
        case .id: "Thread ID"
        case .state: "State"
        case .priority: "Priority"
        }
    }
}

/// Turns successive readings of one process's threads into CPU use per
/// thread. Keyed by the process's identity, so a PID taken over by a new
/// process starts afresh rather than comparing with the old one's threads.
public struct ThreadActivityTracker: Sendable {
    public private(set) var process: ProcessIdentity?
    private var previous: [UInt64: Double] = [:]
    private var previousTime: TimeInterval?

    public init() {}

    /// The threads read at `time` (seconds on a steady clock), with each
    /// one's CPU since the last call. A thread that wasn't there then started
    /// since, so all of its CPU time falls in the interval.
    public mutating func update(_ threads: [ThreadSample], of process: ProcessIdentity, at time: TimeInterval) -> [ThreadActivity] {
        if process != self.process {
            self.process = process
            previous = [:]
            previousTime = nil
        }
        let interval = previousTime.map { time - $0 } ?? 0
        let hasBaseline = previousTime != nil && interval > 0
        let rows = threads.map { thread in
            guard hasBaseline else { return ThreadActivity(thread: thread, cpuPercent: nil) }
            let spent = max(thread.cpuTime - (previous[thread.id] ?? 0), 0)
            // A thread can't use more than one core; timer jitter can say otherwise.
            return ThreadActivity(thread: thread, cpuPercent: min(spent / interval * 100, 100))
        }
        previous = Dictionary(threads.map { ($0.id, $0.cpuTime) }, uniquingKeysWith: { first, _ in first })
        previousTime = time
        return rows
    }

    public mutating func reset() {
        self = ThreadActivityTracker()
    }
}

public enum ThreadActivitySort {
    /// Rows in order of `key`, ties by thread ID, oldest first. Busiest first
    /// unless `ascending`; a row without a CPU figure yet counts as idle, and
    /// by name, unnamed threads come after the named ones either way. CPU
    /// compares in whole `cpuStep`s, the figure as shown (see `ShownFigure`),
    /// so threads that read the same don't swap places every reading.
    public static func sorted(_ rows: [ThreadActivity], by key: ThreadSortKey, ascending: Bool,
                              cpuStep: Double = 0) -> [ThreadActivity] {
        rows.sorted { lhs, rhs in
            if key == .name, (lhs.thread.name == nil) != (rhs.thread.name == nil) { return lhs.thread.name != nil }
            let order = compare(lhs, rhs, by: key, cpuStep: cpuStep)
            if order == .orderedSame { return lhs.thread.id < rhs.thread.id }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare(_ lhs: ThreadActivity, _ rhs: ThreadActivity, by key: ThreadSortKey,
                                cpuStep: Double) -> ComparisonResult {
        func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        switch key {
        case .cpu:
            return order(ShownFigure.steps(lhs.cpuPercent ?? 0, step: cpuStep), ShownFigure.steps(rhs.cpuPercent ?? 0, step: cpuStep))
        case .cpuTime: return order(lhs.thread.cpuTime, rhs.thread.cpuTime)
        case .name: return (lhs.thread.name ?? "").localizedCaseInsensitiveCompare(rhs.thread.name ?? "")
        case .id: return order(lhs.thread.id, rhs.thread.id)
        // Most active is "most" here, so the default descending order shows running threads first.
        case .state: return order(rhs.thread.state.rank, lhs.thread.state.rank)
        case .priority: return order(lhs.thread.priority, rhs.thread.priority)
        }
    }
}

/// The figures over a process's thread list.
public struct ThreadSummary: Sendable, Hashable {
    public var count = 0
    public var running = 0
    /// CPU over the interval summed over the threads, 100 = one core; nil on the first reading.
    public var cpuPercent: Double?

    public init(_ rows: [ThreadActivity]) {
        count = rows.count
        running = rows.filter { $0.thread.state == .running }.count
        let measured = rows.compactMap(\.cpuPercent)
        cpuPercent = measured.isEmpty && !rows.isEmpty ? nil : measured.reduce(0, +)
    }
}
