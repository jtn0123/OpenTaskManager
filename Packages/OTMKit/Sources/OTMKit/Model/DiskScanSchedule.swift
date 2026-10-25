import Foundation

public enum DiskScanCadence: String, Sendable, Codable, CaseIterable {
    case daily, weekly

    public var title: String { rawValue.capitalized }
    public var days: Int { self == .daily ? 1 : 7 }
}

/// The last refusal belongs to a check, not to a sampling tick or a deadline.
/// Optional on a schedule so older saved preferences still decode unchanged.
public struct DiskScanScheduleRefusal: Sendable, Codable, Equatable {
    public let reason: String
    public let checkedAt: Date

    public init(reason: String, checkedAt: Date) {
        self.reason = reason
        self.checkedAt = checkedAt
    }

    public func checkedText(time: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> String {
        "Last checked: " + time(checkedAt)
    }
}

/// The due time stays put until an attempt finishes, so sleep never loses a run.
public struct DiskScanSchedule: Sendable, Codable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public var cadence: DiskScanCadence
    public var hour: Int
    public var minute: Int
    public var dueAt: Date
    /// The last finished attempt, including a scope that could not be read.
    public var lastRun: Date?
    public var lastResult: String?
    public var lastRefusal: DiskScanScheduleRefusal?

    public init(path: String, cadence: DiskScanCadence, hour: Int = 2, minute: Int = 0, now: Date,
                calendar: Calendar = .current) {
        self.path = path
        self.cadence = cadence
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        dueAt = calendar.nextDate(after: now, matching: DateComponents(hour: self.hour, minute: self.minute),
                                  matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    public mutating func finish(at now: Date, result: String, calendar: Calendar = .current) {
        lastRun = now
        lastResult = result
        lastRefusal = nil
        let day = calendar.startOfDay(for: now)
        let nextDay = calendar.date(byAdding: .day, value: cadence.days, to: day) ?? now.addingTimeInterval(86_400)
        dueAt = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: nextDay) ?? nextDay
    }

    /// Editing a preference keeps the last attempt visible; saving unchanged fields keeps a missed deadline too.
    public func preservingHistory(from previous: DiskScanSchedule?, calendar: Calendar = .current) -> Self {
        guard let previous, previous.path == path else { return self }
        var updated = self
        updated.lastRun = previous.lastRun
        updated.lastResult = previous.lastResult
        updated.lastRefusal = previous.lastRefusal
        if previous.cadence == cadence && previous.hour == hour && previous.minute == minute {
            updated.dueAt = previous.dueAt
        } else if let lastRun = previous.lastRun {
            updated.finish(at: lastRun, result: previous.lastResult ?? "Never run", calendar: calendar)
            updated.lastRefusal = previous.lastRefusal
        }
        return updated
    }

    public var overdueReason: String {
        lastRefusal?.reason ?? legacyRefusal?.reason ?? "Waits until the Mac is idle for 2 minutes"
    }

    public var lastCheckedText: String { (lastRefusal ?? legacyRefusal)?.checkedText() ?? "Last checked: not recorded" }

    /// Older schedules kept scope failures as the last finished attempt.
    /// A successful scan's result never explains why an overdue scan waits.
    private var legacyRefusal: DiskScanScheduleRefusal? {
        guard let lastResult, let lastRun,
              [DiskScanScheduleSafety.permissionNeeded, "Folder unavailable", "Not mounted"].contains(lastResult) else { return nil }
        return DiskScanScheduleRefusal(reason: lastResult, checkedAt: lastRun)
    }

    /// A refusal changes history while the same attempt is in flight. An
    /// edit to the scope's deadline must still keep that old attempt apart.
    public func hasSameDeadline(as other: Self) -> Bool {
        path == other.path && cadence == other.cadence && hour == other.hour && minute == other.minute && dueAt == other.dueAt
    }

    public func status(at now: Date) -> String {
        let time = dueAt.formatted(date: .abbreviated, time: .shortened)
        return dueAt <= now ? "Due since \(time)" : "Next due \(time)"
    }
}

/// A small Codable list stored as a JSON string so AppStorage can observe it.
public struct DiskScanSchedules: RawRepresentable, Sendable, Codable, Equatable {
    public static let limit = 40
    public var entries: [DiskScanSchedule]

    public init(_ entries: [DiskScanSchedule] = []) { self.entries = Array(entries.prefix(Self.limit)) }

    public init?(rawValue: String) {
        guard let entries = try? JSONDecoder().decode([DiskScanSchedule].self, from: Data(rawValue.utf8)),
              entries.count <= Self.limit, Set(entries.map(\.path)).count == entries.count,
              entries.allSatisfy({ $0.path.hasPrefix("/") && (0...23).contains($0.hour) && (0...59).contains($0.minute) }) else {
            return nil
        }
        self.entries = entries
    }

    public var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Storage's one line: how many, the soonest deadline, and how many need a hand.
    public func summary(at now: Date, waiting: Int = 0) -> String {
        guard let next = entries.min(by: { $0.dueAt < $1.dueAt }) else { return "" }
        let name = (next.path as NSString).lastPathComponent
        let time = next.dueAt.formatted(date: .abbreviated, time: .shortened)
        var parts = [entries.count == 1 ? "Automatic scan" : "\(entries.count) automatic scans",
                     next.dueAt <= now ? "\(name) due since \(time)" : "\(name) next due \(time)"]
        if waiting > 0 { parts.append("\(waiting) waiting") }
        let denied = entries.count { $0.lastResult == DiskScanScheduleSafety.permissionNeeded }
        if denied > 0 { parts.append(denied == 1 ? "1 needs permission" : "\(denied) need permission") }
        return parts.joined(separator: " · ")
    }
}

/// No system reads here: the app supplies these only when its timer fires.
public struct DiskScanEligibility: Sendable {
    public var power: BenchmarkPowerSource?
    public var charge: Double?
    public var lowPowerMode: Bool
    public var thermal: ThermalState
    public var idleSeconds: Double
    public var anotherScanRunning: Bool

    public init(power: BenchmarkPowerSource?, charge: Double?, lowPowerMode: Bool, thermal: ThermalState,
                idleSeconds: Double, anotherScanRunning: Bool) {
        self.power = power
        self.charge = charge
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.idleSeconds = idleSeconds
        self.anotherScanRunning = anotherScanRunning
    }

    public func refusal(now: Date, schedule: DiskScanSchedule, runNow: Bool = false) -> String? {
        if !runNow && now < schedule.dueAt { return "Not due yet" }
        if anotherScanRunning { return "Another scan is running" }
        if lowPowerMode { return "Low Power Mode" }
        if thermal == .serious || thermal == .critical { return "Thermal pressure" }
        if power == nil { return "Power source unavailable" }
        if power == .battery {
            guard let charge, charge.isFinite, charge >= 0.3 else { return "Battery below 30% or unavailable" }
        }
        if !idleSeconds.isFinite || idleSeconds < 120 { return "Waiting for two minutes without input" }
        return nil
    }

    /// A single wakeup for the whole list, and none for an empty list.
    public static func nextCheck(_ schedules: [DiskScanSchedule], now: Date, pendingRunNow: Bool = false) -> Date? {
        guard let earliest = schedules.map(\.dueAt).min() else { return nil }
        if pendingRunNow || earliest <= now { return now.addingTimeInterval(15 * 60) }
        return earliest
    }
}

/// Refuse both protected folders and their parents before any directory walk.
public enum DiskScanScheduleSafety {
    public static let explanation = "Desktop, Documents, Downloads and other apps’ containers cannot be scanned automatically "
        + "because a background scan must never ask for privacy permission. Choose a folder outside them and their parents."
    public static let permissionNeeded = "Permission needed: open Storage and scan it once by hand"

    public static func refusal(path: String, home: String) -> String? {
        let path = (path as NSString).standardizingPath
        let homes = [home, "/Users/Shared"]
        let protected = homes.flatMap { home in
            ["Desktop", "Documents", "Downloads", "Library/Containers", "Library/Group Containers"].map {
                (home as NSString).appendingPathComponent($0)
            }
        }
        if protected.contains(where: { overlaps(path, $0) }) { return explanation }
        // Other users' protected folders are private too, even when this app has Full Disk Access.
        let parts = path.split(separator: "/").map(String.init)
        if let users = parts.firstIndex(of: "Users"), parts.count > users + 1 {
            let parts = Array(parts.dropFirst(users))
            if parts.count == 2 { return explanation }
            if ["Desktop", "Documents", "Downloads"].contains(parts[2]) { return explanation }
            if parts[2] == "Library" && (parts.count == 3 || ["Containers", "Group Containers"].contains(parts[3])) {
                return explanation
            }
        }
        if overlaps(path, "/System/Volumes/Data/Users") { return explanation }
        return nil
    }

    private static func overlaps(_ first: String, _ second: String) -> Bool {
        first == second || first == "/" || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }

    /// "Scanned 4.2 GB · 3 folders unreadable": a scan's result, with what it couldn't read.
    public static func scannedText(_ summary: DiskScanSummary) -> String {
        let unreadable = summary.unreadableFolders
        return "Scanned \(Format.bytes(summary.allocatedSize))"
            + (unreadable > 0 ? " · \(unreadable) \(unreadable == 1 ? "folder" : "folders") unreadable" : "")
    }

    /// Growth counts only between scans that could read the same number of
    /// folders: a folder readable now and not before would look like growth.
    public static func bigGrowth(before: DiskScanSummary, after: DiskScanSummary) -> Bool {
        guard before.scope == after.scope, before.unreadableFolders == after.unreadableFolders,
              after.allocatedSize > before.allocatedSize else { return false }
        let growth = after.allocatedSize - before.allocatedSize
        return Double(growth) > max(5_000_000_000, Double(before.allocatedSize) * 0.1)
    }
}

/// Optional provenance has its own version; absent means a manual scan.
public struct DiskScanScheduledOrigin: Sendable, Codable, Equatable {
    public let version: Int
    public let cadence: DiskScanCadence

    public init(cadence: DiskScanCadence, version: Int = 1) {
        self.version = version
        self.cadence = cadence
    }
}
