import Foundation

/// The `KeepAlive` key.
public enum LaunchKeepAlive: Sendable, Codable, Hashable {
    case never
    /// Restarted whenever it exits.
    case always
    /// Kept running only while these conditions hold, such as `SuccessfulExit` or `NetworkState`.
    case conditional([String])
}

/// One `StartCalendarInterval` entry. Missing fields match any value, as in cron.
public struct CalendarInterval: Sendable, Codable, Hashable, CustomStringConvertible {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    /// 0 and 7 are Sunday.
    public var weekday: Int?
    public var month: Int?

    public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }

    init(_ dictionary: [String: Any]) {
        self.init(minute: dictionary["Minute"] as? Int, hour: dictionary["Hour"] as? Int, day: dictionary["Day"] as? Int,
                  weekday: dictionary["Weekday"] as? Int, month: dictionary["Month"] as? Int)
    }

    /// "Daily at 04:17", "Hourly at :30", "Sundays at 03:15", "Every minute".
    public var description: String {
        let when: String
        if let month, let day {
            when = "\(Self.monthName(month)) \(day)"
        } else if let day {
            when = "Day \(day) of each month"
        } else if let weekday {
            when = Self.weekdayName(weekday) + "s" + (month.map { " in \(Self.monthName($0))" } ?? "")
        } else if let month {
            when = "Every day in \(Self.monthName(month))"
        } else if hour != nil {
            when = "Daily"
        } else if minute != nil {
            when = "Hourly"
        } else {
            return "Every minute"
        }
        switch (hour, minute) {
        case let (hour?, minute?): return "\(when) at \(Self.pad(hour)):\(Self.pad(minute))"
        case let (hour?, nil): return "\(when), each minute from \(Self.pad(hour)):00 to \(Self.pad(hour)):59"
        case let (nil, minute?): return when == "Hourly" ? "Hourly at :\(Self.pad(minute))" : "\(when), hourly at :\(Self.pad(minute))"
        case (nil, nil): return "\(when), every minute"
        }
    }

    private static func pad(_ value: Int) -> String {
        value < 10 && value >= 0 ? "0\(value)" : String(value)
    }

    private static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names.indices.contains(weekday % 7) ? names[weekday % 7] : "Day \(weekday)"
    }

    private static func monthName(_ month: Int) -> String {
        let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                     "November", "December"]
        return names.indices.contains(month - 1) ? names[month - 1] : "Month \(month)"
    }
}

/// The main reason a job starts, for sorting and the "Launches" column.
public enum LaunchTiming: Int, Sendable, Codable, Hashable, CaseIterable, Comparable {
    case keepAlive
    case atLoad
    case interval
    case calendar
    case fileChange
    case conditional
    case onDemand
    case unknown

    public func title(for scope: LaunchItemScope) -> String {
        switch self {
        case .keepAlive: "Keep alive"
        case .atLoad: scope == .daemon ? "At boot" : "At login"
        case .interval: "Interval"
        case .calendar: "Scheduled"
        case .fileChange: "On file change"
        case .conditional: "Conditional keep alive"
        case .onDemand: "On demand"
        case .unknown: "Unknown"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Everything in a property list that makes launchd start a job.
public struct LaunchTriggers: Sendable, Codable, Hashable {
    public var runAtLoad = false
    public var keepAlive = LaunchKeepAlive.never
    /// `StartInterval`, in seconds.
    public var startInterval: Int?
    public var calendar: [CalendarInterval] = []
    public var watchPaths: [String] = []
    public var queueDirectories: [String] = []
    public var startOnMount = false
    /// Started when another process reaches it through `MachServices`, `Sockets` or `LaunchEvents`.
    public var hasOnDemandEndpoints = false

    public init() {}

    init(plist: [String: Any]) {
        runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        if let conditions = plist["KeepAlive"] as? [String: Any] {
            keepAlive = conditions.isEmpty ? .never : .conditional(conditions.keys.sorted())
        } else if plist["KeepAlive"] as? Bool == true {
            keepAlive = .always
        }
        startInterval = plist["StartInterval"] as? Int
        if let one = plist["StartCalendarInterval"] as? [String: Any] {
            calendar = [CalendarInterval(one)]
        } else if let many = plist["StartCalendarInterval"] as? [[String: Any]] {
            calendar = many.map(CalendarInterval.init)
        }
        watchPaths = plist["WatchPaths"] as? [String] ?? []
        queueDirectories = plist["QueueDirectories"] as? [String] ?? []
        startOnMount = plist["StartOnMount"] as? Bool ?? false
        hasOnDemandEndpoints = ["MachServices", "Sockets", "LaunchEvents"].contains { key in
            (plist[key] as? [String: Any])?.isEmpty == false
        }
    }

    /// Starts as soon as launchd loads it. `SuccessfulExit` implies `RunAtLoad`,
    /// since the job has to run once before it can exit.
    public var startsWhenLoaded: Bool {
        switch keepAlive {
        case .always: true
        case let .conditional(conditions): runAtLoad || conditions.contains("SuccessfulExit")
        case .never: runAtLoad
        }
    }

    public var timing: LaunchTiming {
        if keepAlive == .always { return .keepAlive }
        if startsWhenLoaded { return .atLoad }
        if startInterval != nil { return .interval }
        if !calendar.isEmpty { return .calendar }
        if !watchPaths.isEmpty || !queueDirectories.isEmpty || startOnMount { return .fileChange }
        if case .conditional = keepAlive { return .conditional }
        return .onDemand
    }

    /// Short form for a table column: "At login", "Every hour", "Daily at 04:17".
    public func summary(for scope: LaunchItemScope) -> String {
        switch timing {
        case .interval: Self.every(startInterval ?? 0)
        case .calendar: calendar.count == 1 ? calendar[0].description : "\(calendar.count) schedules"
        case .fileChange where watchPaths.isEmpty && queueDirectories.isEmpty: "On volume mount"
        default: timing.title(for: scope)
        }
    }

    /// One line per trigger, for the detail pane.
    public func details(for scope: LaunchItemScope) -> [String] {
        var lines: [String] = []
        if runAtLoad {
            lines.append(scope == .daemon ? "At boot, as soon as launchd loads it" : "At login, as soon as launchd loads it")
        }
        switch keepAlive {
        case .always:
            lines.append("Kept alive: launchd restarts it whenever it exits")
        case let .conditional(conditions):
            let names = conditions.map { LaunchItems.words(in: $0).joined(separator: " ").lowercased() }
            lines.append("Kept alive depending on " + names.joined(separator: ", "))
        case .never:
            break
        }
        if let startInterval { lines.append(Self.every(startInterval)) }
        lines += calendar.map(\.description)
        lines += watchPaths.map { "When this changes: \($0)" }
        lines += queueDirectories.map { "When files arrive in \($0)" }
        if startOnMount { lines.append("When a volume mounts") }
        if hasOnDemandEndpoints { lines.append("On demand, when another process calls on it") }
        if lines.isEmpty { lines.append("Only when something starts it explicitly") }
        return lines
    }

    /// "Every hour", "Every 15 min", "Every 30 s".
    public static func every(_ seconds: Int) -> String {
        guard seconds > 0 else { return "On a timer" }
        func phrase(_ count: Int, _ one: String, _ unit: String) -> String {
            count == 1 ? "Every \(one)" : "Every \(count) \(unit)"
        }
        if seconds % 86_400 == 0 { return phrase(seconds / 86_400, "day", "days") }
        if seconds % 3600 == 0 { return phrase(seconds / 3600, "hour", "h") }
        if seconds % 60 == 0 { return phrase(seconds / 60, "minute", "min") }
        return phrase(seconds, "second", "s")
    }
}
