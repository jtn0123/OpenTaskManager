import Foundation

// The stored choices live beside their keys so defaults have the same type as their callers.

public enum AppsFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case thirdParty = "Third party"
    case appStore = "App Store"
    case apple = "Apple"
    case intel = "Intel only"
    case running = "Running"

    public var id: String { rawValue }
}

public enum StartupFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case thirdParty = "Third party"
    case apple = "Apple"
    case running = "Running"
    case agents = "Agents"
    case daemons = "Daemons"
    case problems = "Problems"

    public var id: String { rawValue }
}

public enum DriversFilter: String, CaseIterable, Sendable, Identifiable {
    case thirdParty = "Third party"
    case apple = "Apple"
    case all = "All"

    public var id: String { rawValue }
}

public enum CPUGraphScale: String, CaseIterable, Sendable {
    case auto
    case full
}

public enum GroupMemberSort: String, CaseIterable, Sendable {
    case cpu, memory, name, pid
}

public enum HistoryRange: Int, CaseIterable, Sendable, Identifiable {
    case hour = 3_600
    case sixHours = 21_600
    case day = 86_400
    case week = 604_800

    public var id: Int { rawValue }
}

public enum HistoryHardwareChart: String, CaseIterable, Sendable, Identifiable {
    case cores
    case eachCore
    case clocks
    case media
    case temperatures
    case fans
    case power

    public var id: String { rawValue }
}

public enum ProcessColumn: String, CaseIterable, Sendable {
    case name, pid, cpu, memory, power, gpu, neuralMemory, disk, threads, topTier, wakeups, user, kind
}

public enum ConnectionColumn: String, CaseIterable, Sendable {
    case process, pid, transport = "protocol", local, remote, state, age, scope
}

public enum UpdateSpeed: Double, CaseIterable, Sendable, Identifiable {
    case fast = 0.5
    case normal = 1
    case slow = 2
    case verySlow = 5

    public var id: Double { rawValue }
}

public enum SystemReportFormat: String, CaseIterable, Sendable {
    case markdown, json
}
