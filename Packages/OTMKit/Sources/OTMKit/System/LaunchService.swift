import Foundation

/// What launchd knows about one loaded job right now, from `launchctl print`:
/// whether it's running, how often it has started, and why the last time.
public struct LaunchServiceInfo: Sendable, Hashable {
    /// launchd's word for it: "running", "not running", "waiting" and so on.
    public var state: String?
    public var pid: Int32?
    /// Starts since the domain was set up: since boot for a daemon, since
    /// login for an agent.
    public var runs: Int?
    /// What set off the current run, such as "ipc (socket)" or "inferred program".
    public var startReason: String?
    /// Why the last run ended, beyond its exit code (an idle exit, say).
    public var lastExitReason: String?
    /// The signal that ended the last run, as launchd words it ("Terminated: 15").
    public var lastSignal: String?
    /// How macOS schedules it: interactive, adaptive, standard or background.
    public var priority: LaunchPriority?
    /// Seconds between runs, for a job on a timer.
    public var runInterval: Int?
    /// launchd's flags for the job, such as "runatload" or "supports transactions".
    public var properties: [String] = []

    public init() {}

    public var isRunning: Bool { pid != nil }

    /// `runs` in words. launchd counts from when the job's domain was set up:
    /// your login for an agent, startup for a daemon.
    public static func describe(runs: Int, scope: LaunchItemScope) -> String {
        let since = scope == .daemon ? "since startup" : "since login"
        return switch runs {
        case ...0: "Not \(since)"
        case 1: "Once \(since)"
        default: "\(runs) times \(since)"
        }
    }

    /// What started the current run, in words; launchd's own term otherwise.
    public static func describe(startReason: String) -> String {
        switch startReason {
        case "speculative": "Loading: it runs at load or is kept alive"
        case "ipc (socket)": "A connection to its socket"
        case "ipc (mach)": "A request to its service"
        case "non-ipc demand": "A direct start, such as launchctl kickstart"
        case let reason where reason.hasPrefix("event"): "A system event it watches for"
        case let reason where reason.hasPrefix("interval"): "Its timer"
        default: startReason
        }
    }

    /// launchd's exit reasons in words; unknown ones lose their prefix and
    /// underscores ("OS_REASON_CODESIGNING" reads "Codesigning").
    public static func describe(exitReason: String) -> String {
        let known = [
            "JETSAM_REASON_MEMORY_IDLE_EXIT": "Quit while idle, to free memory",
            "JETSAM_REASON_MEMORY_HIGHWATER": "Went over its memory limit",
            "JETSAM_REASON_MEMORY_PERPROCESSLIMIT": "Went over its memory limit",
            "JETSAM_REASON_MEMORY_VMPAGESHORTAGE": "Ended to relieve memory pressure",
            "JETSAM_REASON_MEMORY_VNODE": "Ended to free file handles",
        ]
        if let text = known[exitReason] { return text }
        var words = Substring(exitReason)
        for prefix in ["JETSAM_REASON_", "OS_REASON_"] where words.hasPrefix(prefix) {
            words = words.dropFirst(prefix.count)
        }
        let text = words.replacingOccurrences(of: "_", with: " ").lowercased()
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The top-level `key = value` lines of `launchctl print <service>`.
    /// Nested blocks (environment, sockets, coalitions) are indented further
    /// and skipped.
    public static func parse(_ output: String) -> LaunchServiceInfo {
        var info = LaunchServiceInfo()
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t"),
                  let separator = line.range(of: " = ") else { continue }
            let key = line[line.index(after: line.startIndex)..<separator.lowerBound]
            let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != "{" else { continue }
            switch key {
            case "state": info.state = value
            case "pid": info.pid = Int32(value)
            case "runs": info.runs = Int(value)
            case "immediate reason": info.startReason = value
            case "last exit reason": info.lastExitReason = value
            case "last terminating signal": info.lastSignal = value
            case "spawn type": info.priority = LaunchPriority(spawnType: value)
            case "run interval": info.runInterval = Int(value.split(separator: " ").first ?? "")
            case "properties":
                info.properties = value.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: break
            }
        }
        return info
    }
}

/// launchd's spawn type: how much CPU and I/O priority the job gets.
public enum LaunchPriority: String, Sendable, Hashable {
    case interactive, adaptive, standard, background

    /// From `spawn type = daemon (3)`. launchd calls the default "daemon".
    init?(spawnType: String) {
        switch spawnType.split(separator: " ").first {
        case "interactive": self = .interactive
        case "adaptive": self = .adaptive
        case "daemon": self = .standard
        case "background": self = .background
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .interactive: "Interactive"
        case .adaptive: "Adaptive"
        case .standard: "Standard"
        case .background: "Background"
        }
    }

    public var explanation: String {
        switch self {
        case .interactive: "Runs at the priority of the app you're using."
        case .adaptive: "Background priority, raised while an app is waiting on it."
        case .standard: "Normal priority for a background job."
        case .background: "Throttled: gets CPU and disk time only when the Mac is otherwise idle."
        }
    }
}

extension Launchctl {
    /// launchd's current view of one job, or nil when it isn't loaded.
    /// Daemons are read from the system domain, agents from your session;
    /// reading either needs no administrator.
    public static func service(_ label: String, scope: LaunchItemScope, uid: uid_t = getuid()) -> LaunchServiceInfo? {
        let target = scope == .daemon ? "system/\(label)" : "gui/\(uid)/\(label)"
        guard let result = CommandRunner.execute("/bin/launchctl", ["print", target], capture: .output, timeout: 5),
              result.status == 0 else { return nil }
        return LaunchServiceInfo.parse(result.text)
    }
}
