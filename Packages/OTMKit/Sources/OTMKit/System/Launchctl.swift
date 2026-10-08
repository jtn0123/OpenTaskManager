import Foundation

/// How a launchd job last ended, as `launchctl` reports it.
public enum LaunchExitStatus: Sendable, Codable, Hashable, CustomStringConvertible {
    /// An exit code, or the negated number of the signal that killed the job.
    case code(Int32)
    /// A short reason launchd prints in place of a code, such as `pe` for `(pe)`.
    case reason(String)

    public var description: String {
        switch self {
        case .code(0):
            return "Exited normally (0)"
        case let .code(code) where code < 0:
            let name = Self.signalName(-code).map { " (\($0))" } ?? ""
            return "Killed by signal \(-code)\(name)"
        case let .code(code):
            return "Exited with code \(code)"
        case .reason("pe"):
            return "Asked to exit while idle, to free memory"
        case .reason("jt"):
            return "Ended by the system for using too much memory"
        case let .reason(reason):
            return "Ended for reason \"\(reason)\""
        }
    }

    /// "SIGSEGV" for 11; nil for a signal without a common name.
    public static func signalName(_ signal: Int32) -> String? {
        signalNames[signal].map { "SIG\($0)" }
    }

    private static let signalNames: [Int32: String] = [
        1: "HUP", 2: "INT", 3: "QUIT", 4: "ILL", 5: "TRAP", 6: "ABRT", 7: "EMT", 8: "FPE",
        9: "KILL", 10: "BUS", 11: "SEGV", 12: "SYS", 13: "PIPE", 14: "ALRM", 15: "TERM",
    ]
}

/// One job launchd has loaded, from `launchctl list` or `launchctl print`.
public struct LaunchJobStatus: Sendable, Codable, Hashable {
    public let label: String
    /// Set while the job is running.
    public let pid: Int32?
    /// Nil when launchd has no exit to report.
    public let lastExit: LaunchExitStatus?

    public init(label: String, pid: Int32?, lastExit: LaunchExitStatus?) {
        self.label = label
        self.pid = pid
        self.lastExit = lastExit
    }
}

/// Reads launchd's view of its jobs through `/bin/launchctl`, which needs no
/// special rights for the listings used here.
public enum Launchctl {
    /// Jobs in your own session, keyed by label.
    public static func userJobs() -> [String: LaunchJobStatus] {
        run(["list"]).map(parseList) ?? [:]
    }

    /// The system domain's daemons and its enable/disable overrides. One
    /// `launchctl print system` call carries both.
    public static func systemDomain() -> (jobs: [String: LaunchJobStatus], overrides: [String: Bool]) {
        guard let output = run(["print", "system"]) else { return ([:], [:]) }
        return (parseServices(output), parseDisabled(output))
    }

    /// Overrides recorded by `launchctl enable` and `disable` for your session.
    public static func userOverrides(uid: uid_t = getuid()) -> [String: Bool] {
        run(["print-disabled", "gui/\(uid)"]).map(parseDisabled) ?? [:]
    }

    // MARK: Parsing

    /// Parses `launchctl list`: a header, then one tab-separated row per job
    /// with the PID ("-" when it isn't running), the last exit status and the label.
    public static func parseList(_ output: String) -> [String: LaunchJobStatus] {
        var jobs: [String: LaunchJobStatus] = [:]
        for line in output.split(separator: "\n") {
            guard let fields = leadingFields(line, count: 3) else { continue }
            let pid = Int32(fields[0])
            // The header ("PID Status Label") has neither a number nor a dash.
            guard pid != nil || fields[0] == "-" else { continue }
            add(LaunchJobStatus(label: String(fields[2]), pid: pid.flatMap { $0 > 0 ? $0 : nil },
                                lastExit: exitStatus(fields[1])), to: &jobs)
        }
        return jobs
    }

    /// Parses the `services = { … }` block of `launchctl print <domain>`, where
    /// each row is the PID (0 when not running), the last exit and the label.
    public static func parseServices(_ output: String) -> [String: LaunchJobStatus] {
        var jobs: [String: LaunchJobStatus] = [:]
        for line in lines(inBlock: "services", of: output) {
            guard let fields = leadingFields(line, count: 3), let pid = Int32(fields[0]) else { continue }
            add(LaunchJobStatus(label: String(fields[2]), pid: pid > 0 ? pid : nil, lastExit: exitStatus(fields[1])), to: &jobs)
        }
        return jobs
    }

    /// Parses the `disabled services = { … }` block of `launchctl print` or
    /// `launchctl print-disabled`: `"label" => disabled` (true) or `=> enabled`
    /// (false). Older systems print `true` and `false` instead.
    public static func parseDisabled(_ output: String) -> [String: Bool] {
        var overrides: [String: Bool] = [:]
        for line in lines(inBlock: "disabled services", of: output) {
            guard let arrow = line.range(of: " => ") else { continue }
            var label = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            if label.count >= 2, label.hasPrefix("\""), label.hasSuffix("\"") {
                label = String(label.dropFirst().dropLast())
            }
            switch line[arrow.upperBound...].trimmingCharacters(in: .whitespaces) {
            case "disabled", "true": overrides[label] = true
            case "enabled", "false": overrides[label] = false
            default: continue
            }
        }
        return overrides
    }

    static func exitStatus<S: StringProtocol>(_ field: S) -> LaunchExitStatus? {
        if field == "-" || field.isEmpty { return nil }
        if let code = Int32(field) { return .code(code) }
        var reason = Substring(field)
        if reason.count >= 2, reason.hasPrefix("("), reason.hasSuffix(")") {
            reason = reason.dropFirst().dropLast()
        }
        return .reason(String(reason))
    }

    /// The rows inside a top-level `name = {` block, up to its closing brace.
    private static func lines(inBlock name: String, of output: String) -> [Substring] {
        var rows: [Substring] = []
        var inside = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("= {") {
                inside = trimmed == "\(name) = {"
            } else if trimmed == "}" {
                inside = false
            } else if inside {
                rows.append(line)
            }
        }
        return rows
    }

    /// Splits off `count - 1` whitespace-separated fields and returns the
    /// rest of the line, trimmed, as the last one, so a label may contain spaces.
    private static func leadingFields(_ line: Substring, count: Int) -> [Substring]? {
        var fields: [Substring] = []
        var rest = line.drop { $0.isWhitespace }
        while fields.count < count - 1 {
            guard let end = rest.firstIndex(where: \.isWhitespace) else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...].drop { $0.isWhitespace }
        }
        while rest.last?.isWhitespace == true { rest = rest.dropLast() }
        guard !rest.isEmpty else { return nil }
        return fields + [rest]
    }

    /// A label can show up twice (in the GUI and background sessions); keep the running one.
    private static func add(_ job: LaunchJobStatus, to jobs: inout [String: LaunchJobStatus]) {
        if jobs[job.label]?.pid == nil { jobs[job.label] = job }
    }

    /// Runs `launchctl` for its exit status and error text, for calls that change something.
    static func execute(_ arguments: [String]) -> (status: Int32, error: String) {
        guard let result = CommandRunner.execute("/bin/launchctl", arguments, capture: .errors, timeout: 15) else {
            return (-1, "launchctl couldn't run or didn't finish.")
        }
        return (result.status, result.text)
    }

    private static func run(_ arguments: [String]) -> String? {
        guard let result = CommandRunner.execute("/bin/launchctl", arguments, capture: .output, timeout: 10),
              result.status == 0 else { return nil }
        return result.text
    }
}
