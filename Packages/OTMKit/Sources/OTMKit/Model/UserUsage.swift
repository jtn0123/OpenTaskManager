import Foundation

/// What a set of processes uses right now, summed. Fields that only some
/// processes report (power, GPU) are nil when none of them do, so a user
/// whose processes macOS hides shows "unknown" rather than zero.
public struct UsageTotals: Sendable, Hashable {
    public var processCount = 0
    /// Processes macOS only reveals through `ps`: CPU and resident memory.
    public var restrictedCount = 0
    /// Where 100 is one fully busy core, as for `ProcessSample.cpuPercent`.
    public var cpuPercent = 0.0
    /// The sum of each process's memory: its footprint when it can be read,
    /// its resident size when it's restricted. Pages shared between processes
    /// count once per process, so this isn't memory the user holds exclusively.
    public var memory: UInt64 = 0
    public var powerWatts: Double?
    /// 0...1 per GPU; several busy processes can add up past 1.
    public var gpuFraction: Double?
    public var threads = 0

    public init() {}

    /// True when every process is restricted, so only CPU and memory are known.
    public var isRestricted: Bool { processCount > 0 && restrictedCount == processCount }

    /// True when at least one process reported resident size instead of footprint.
    public var includesResidentMemory: Bool { restrictedCount > 0 }

    mutating func add(_ process: ProcessSample) {
        processCount += 1
        if process.isRestricted { restrictedCount += 1 }
        cpuPercent += process.cpuPercent
        memory += process.memory
        threads += process.threadCount
        if let watts = process.powerWatts { powerWatts = (powerWatts ?? 0) + watts }
        if let gpu = process.gpuFraction { gpuFraction = (gpuFraction ?? 0) + gpu }
    }

    mutating func add(_ other: UsageTotals) {
        processCount += other.processCount
        restrictedCount += other.restrictedCount
        cpuPercent += other.cpuPercent
        memory += other.memory
        threads += other.threads
        if let watts = other.powerWatts { powerWatts = (powerWatts ?? 0) + watts }
        if let gpu = other.gpuFraction { gpuFraction = (gpuFraction ?? 0) + gpu }
    }
}

/// One user's processes and what they use right now.
public struct UserUsage: Sendable, Identifiable, Hashable {
    public var id: UInt32 { uid }
    public let uid: UInt32
    /// The login name ("root", "_windowserver"), or the uid when it has no account.
    public let name: String
    public var totals = UsageTotals()

    public init(uid: UInt32, name: String) {
        self.uid = uid
        self.name = name
    }

    public var isSystemAccount: Bool { Self.isSystemAccount(uid: uid) }

    /// macOS gives root and the daemons' accounts (`_windowserver`,
    /// `_spotlight`) uids below 500 and starts people at 501. `nobody` is -2,
    /// which arrives here as a large unsigned number.
    public static func isSystemAccount(uid: UInt32) -> Bool {
        uid < 500 || Int32(bitPattern: uid) < 0
    }
}

public enum UserUsageBuilder {
    /// Totals per uid, in display order (see `ordered`).
    public static func build(_ processes: [ProcessSample], consoleUID: UInt32? = nil) -> [UserUsage] {
        var byUID: [UInt32: UserUsage] = [:]
        for process in processes {
            byUID[process.uid, default: UserUsage(uid: process.uid, name: process.userName)].totals.add(process)
        }
        return ordered(Array(byUID.values), consoleUID: consoleUID)
    }

    /// The CPU and memory graphs stay continuous while the page is hidden.
    /// Avoid names, display ordering and the totals no graph uses then.
    public static func historyTotals(_ processes: [ProcessSample]) -> [UInt32: UsageTotals] {
        var totals: [UInt32: UsageTotals] = [:]
        for process in processes {
            totals[process.uid, default: UsageTotals()].cpuPercent += process.cpuPercent
            totals[process.uid, default: UsageTotals()].memory += process.memory
        }
        return totals
    }

    /// A stable order, so cards don't jump around as load changes: the
    /// signed-in user, then other people by name, then system accounts with
    /// root first and the rest by name.
    public static func ordered(_ users: [UserUsage], consoleUID: UInt32?) -> [UserUsage] {
        func rank(_ user: UserUsage) -> Int {
            if user.uid == consoleUID { return 0 }
            if !user.isSystemAccount { return 1 }
            return user.uid == 0 ? 2 : 3
        }
        return users.sorted { lhs, rhs in
            let left = rank(lhs)
            let right = rank(rhs)
            if left != right { return left < right }
            // Leading underscores would otherwise sort every daemon account together, apart from the rest.
            let order = displayKey(lhs.name).localizedStandardCompare(displayKey(rhs.name))
            return order == .orderedSame ? lhs.uid < rhs.uid : order == .orderedAscending
        }
    }

    /// The sum over several users, for a collapsed group's header.
    public static func total(_ users: [UserUsage]) -> UsageTotals {
        var totals = UsageTotals()
        users.forEach { totals.add($0.totals) }
        return totals
    }

    /// The user's busiest processes: most CPU first, then most memory, so an
    /// idle user still lists their biggest processes.
    public static func topProcesses(of uid: UInt32, in processes: [ProcessSample], count: Int) -> [ProcessSample] {
        let mine = processes.filter { $0.uid == uid }
        return Array(mine.sorted { lhs, rhs in
            if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
            if lhs.memory != rhs.memory { return lhs.memory > rhs.memory }
            return lhs.pid < rhs.pid
        }.prefix(max(count, 0)))
    }

    private static func displayKey(_ name: String) -> String {
        name.hasPrefix("_") ? String(name.dropFirst()) : name
    }
}
