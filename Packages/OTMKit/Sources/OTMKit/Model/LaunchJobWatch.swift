import Foundation

// MARK: Exits

public extension LaunchExitStatus {
    /// Signals that mean the program crashed, rather than being asked to
    /// stop. launchd ends idle jobs with SIGKILL and stops them with SIGTERM,
    /// so those two say nothing about the job.
    static let crashSignals: Set<Int32> = [SIGILL, SIGTRAP, SIGABRT, SIGEMT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS]

    /// The signal that crashed the run, if one did.
    var crashSignal: Int32? {
        guard case let .code(code) = self, code < 0, Self.crashSignals.contains(-code) else { return nil }
        return -code
    }

    /// The code the run exited with, when it says it failed (anything but 0).
    var failureCode: Int32? {
        guard case let .code(code) = self, code > 0 else { return nil }
        return code
    }

    /// The run crashed or exited with an error. An idle exit, a stop and a
    /// memory-pressure kill aren't failures of the job.
    var isFailure: Bool { crashSignal != nil || failureCode != nil }

    /// What a conventional exit code means: the BSD `sysexits` codes, which
    /// launchd itself uses (78 when it can't set the job up), and the shell's
    /// 126 and 127. Nil for a code with no common meaning.
    static func meaning(ofCode code: Int32) -> String? {
        switch code {
        case 64: "EX_USAGE: it was started with arguments it doesn't accept"
        case 65: "EX_DATAERR: its input was malformed"
        case 66: "EX_NOINPUT: an input file was missing or unreadable"
        case 67: "EX_NOUSER: a user it needs doesn't exist"
        case 68: "EX_NOHOST: a host it needs couldn't be found"
        case 69: "EX_UNAVAILABLE: a service it needs isn't available"
        case 70: "EX_SOFTWARE: an internal error"
        case 71: "EX_OSERR: a system error, such as being unable to start a process"
        case 72: "EX_OSFILE: a system file was missing or wrong"
        case 73: "EX_CANTCREAT: it couldn't create a file it writes"
        case 74: "EX_IOERR: a read or write failed"
        case 75: "EX_TEMPFAIL: a temporary failure; a later run may work"
        case 76: "EX_PROTOCOL: another program answered in a way it didn't expect"
        case 77: "EX_NOPERM: it isn't allowed to do something it needs"
        case 78: "EX_CONFIG: a setup problem, such as a program or file it can't find or isn't allowed to open"
        case 126: "its program couldn't be run"
        case 127: "its program wasn't found"
        default: nil
        }
    }

    /// What a crash signal says about the program, in plain words. Nil for
    /// a signal that isn't a crash (`crashSignals`).
    static func meaning(ofSignal signal: Int32) -> String? {
        switch signal {
        case SIGSEGV: "a bad memory access, reading or writing memory it doesn't own, usually a bug in the program"
        case SIGBUS: "a bad memory access, often to a file mapped into memory that changed or went away"
        case SIGABRT: "it stopped itself on finding something wrong, such as a failed check or a fatal error"
        case SIGTRAP: "a failed runtime check, such as an unexpected nil or an index out of range in Swift code"
        case SIGILL: "an illegal instruction, often a runtime check that stopped it on purpose"
        case SIGFPE: "an arithmetic error, such as dividing by zero"
        case SIGSYS: "a system call that doesn't exist or isn't allowed"
        case SIGEMT: "an emulation trap, rare on a Mac"
        default: nil
        }
    }
}

// MARK: Watching jobs

/// A launchd job as OpenTaskManager follows it from one read to the next:
/// its label, and the scope its property list is in.
public struct LaunchJobKey: Hashable, Sendable {
    public let label: String
    public let scope: LaunchItemScope

    public init(label: String, scope: LaunchItemScope) {
        self.label = label
        self.scope = scope
    }

    public init(_ item: LaunchItem) {
        self.init(label: item.label, scope: item.scope)
    }
}

/// One process launchd ran for a job.
public struct LaunchJobInstance: Hashable, Sendable {
    public let pid: Int32
    /// When the process started, from the process list; nil when the list
    /// didn't have it (yet, or because system processes are left out).
    public let started: Date?

    public init(pid: Int32, started: Date?) {
        self.pid = pid
        self.started = started
    }

    /// The same process: the same PID and, when both start times are known,
    /// the same start, since macOS hands a PID out again once it's free.
    func isSame(as other: LaunchJobInstance) -> Bool {
        guard pid == other.pid else { return false }
        guard let started, let otherStarted = other.started else { return true }
        return abs(started.timeIntervalSince(otherStarted)) < 1
    }
}

/// A new process seen for a job that already had one.
public struct LaunchJobRestart: Hashable, Sendable {
    /// When the new process started, or when it was first seen if its start isn't known.
    public let date: Date
    /// How the run before it ended, as launchd reported once the new one ran.
    public let previousExit: LaunchExitStatus?
    /// A restart that says something's wrong: the run before crashed or
    /// failed, or the job is meant to stay alive and ended anyway. An
    /// on-demand job starting again after a clean or idle exit isn't.
    public let isTroubled: Bool

    public init(date: Date, previousExit: LaunchExitStatus?, isTroubled: Bool) {
        self.date = date
        self.previousExit = previousExit
        self.isTroubled = isTroubled
    }
}

/// What OpenTaskManager has seen of one job this session.
public struct LaunchJobRecord: Hashable, Sendable {
    /// The first read that found it loaded.
    public let firstSeen: Date
    /// The last process seen for it. Kept while the job waits between runs,
    /// so its next one counts as a restart; cleared when it's unloaded.
    public fileprivate(set) var instance: LaunchJobInstance?
    /// Every restart seen.
    public fileprivate(set) var restartCount = 0
    /// The latest restarts, oldest first, at most `LaunchJobWatch.keptRestarts`.
    public fileprivate(set) var recentRestarts: [LaunchJobRestart] = []

    public init(firstSeen: Date) {
        self.firstSeen = firstSeen
    }

    public var lastRestart: LaunchJobRestart? { recentRestarts.last }

    fileprivate mutating func add(_ restart: LaunchJobRestart) {
        restartCount += 1
        recentRestarts.append(restart)
        if recentRestarts.count > LaunchJobWatch.keptRestarts { recentRestarts.removeFirst() }
    }

    /// The restarts in words, for the details: "Restarted 3 times since
    /// 09:12, the last at 09:20". `time` formats a clock time.
    public func restartSummary(time: (Date) -> String) -> String {
        let since = "since \(time(firstSeen))"
        guard let last = lastRestart else { return "None seen \(since)" }
        return restartCount == 1 ? "Once \(since), at \(time(last.date))"
            : "\(restartCount) times \(since), the last at \(time(last.date))"
    }
}

/// Follows launchd's jobs between reads of its list, to count restarts.
///
/// Each read gives every loaded job's PID, as launchd reports it; the process
/// list adds when that process started. A job whose process differs from the
/// one seen before has restarted. Only what launchd says is counted, and only
/// at reads: restarts between two reads count once at most.
public struct LaunchJobWatch: Sendable {
    /// Troubled restarts within `flappingWindow` that make a job "restarting".
    public static let flappingCount = 3
    public static let flappingWindow: TimeInterval = 15 * 60
    static let keptRestarts = 20

    public private(set) var records: [LaunchJobKey: LaunchJobRecord] = [:]
    /// The first read this session.
    public private(set) var since: Date?
    /// The latest read, which `health(of:)` measures its window back from.
    public private(set) var lastRead: Date?

    public init() {}

    public func record(for item: LaunchItem) -> LaunchJobRecord? {
        records[LaunchJobKey(item)]
    }

    /// Notes one read of launchd's list. `startTimes` is the process list's
    /// start time for each PID it has.
    public mutating func observe(_ items: [LaunchItem], startTimes: [Int32: Date], at date: Date) {
        if since == nil { since = date }
        lastRead = date
        for item in items where !item.isMissingLabel {
            let key = LaunchJobKey(item)
            guard let job = item.job else {
                // Unloaded: once it's loaded again, its first run isn't a restart.
                if records[key]?.instance != nil { records[key]?.instance = nil }
                continue
            }
            var record = records[key] ?? LaunchJobRecord(firstSeen: date)
            if let pid = job.pid {
                let process = LaunchJobInstance(pid: pid, started: startTimes[pid])
                if let before = record.instance, !process.isSame(as: before) {
                    let troubled = job.lastExit?.isFailure == true || item.triggers.keepAlive == .always
                    record.add(LaunchJobRestart(date: process.started ?? date, previousExit: job.lastExit, isTroubled: troubled))
                }
                // Also keeps a start time the process list had only later.
                if record.instance != process { record.instance = process }
            }
            if records[key] != record { records[key] = record }
        }
    }

    /// Whether the job needs a look: seen restarting again and again, or
    /// its last run crashed or failed. Restarting wins, as it says more.
    public func health(of item: LaunchItem) -> LaunchJobHealth {
        guard let job = item.job else { return .healthy }
        if let record = record(for: item), let lastRead {
            let troubled = record.recentRestarts.filter {
                $0.isTroubled && lastRead.timeIntervalSince($0.date) <= Self.flappingWindow
            }
            if troubled.count >= Self.flappingCount { return .restarting(count: troubled.count) }
        }
        if let signal = job.lastExit?.crashSignal { return .crashed(signal: signal) }
        if let code = job.lastExit?.failureCode { return .failed(code: code) }
        return .healthy
    }
}

/// Whether a startup item's job looks troubled, from launchd's last exit
/// and the restarts seen this session.
public enum LaunchJobHealth: Hashable, Sendable {
    case healthy
    /// Its last run exited with this code.
    case failed(code: Int32)
    /// Its last run was ended by this signal, a crash.
    case crashed(signal: Int32)
    /// Seen restarting this many times within `LaunchJobWatch.flappingWindow`
    /// after failing, or though it's meant to stay alive.
    case restarting(count: Int)

    public var needsAttention: Bool { self != .healthy }

    /// A heading for the details. The state itself, which the table and the
    /// details' header share, is `LaunchItemStatus`.
    public var headline: String? {
        switch self {
        case .healthy: nil
        case .restarting: "Restarting again and again"
        case .crashed: "Its last run crashed"
        case .failed: "Its last run failed"
        }
    }

    /// What was seen, in a sentence or two. `record` is the job's restarts
    /// this session; `time` formats a clock time.
    public func explanation(for item: LaunchItem, record: LaunchJobRecord?, time: (Date) -> String) -> String? {
        let again = item.pid != nil ? " It's running again now." : ""
        switch self {
        case .healthy:
            return nil
        case let .crashed(signal):
            let meaning = LaunchExitStatus.meaning(ofSignal: signal) ?? "the program crashed"
            return "\(LaunchExitStatus.code(-signal).description): \(meaning).\(again)"
        case let .failed(code):
            let meaning = LaunchExitStatus.meaning(ofCode: code).map { " (\($0))" } ?? ""
            return "\(LaunchExitStatus.code(code).description)\(meaning).\(again)"
        case .restarting:
            guard let record, let last = record.lastRestart else { return nil }
            var text = "Restarted \(record.restartCount == 1 ? "once" : "\(record.restartCount) times") "
                + "since \(time(record.firstSeen)), the last at \(time(last.date))"
            if let exit = last.previousExit, exit.isFailure {
                text += ", after its run before ended: \(Self.inSentence(exit))."
            } else {
                text += "."
            }
            if item.triggers.keepAlive == .always {
                text += " launchd keeps it alive, so it starts again whenever it ends."
            }
            return text
        }
    }

    /// "killed by signal 11 (SIGSEGV)", to follow a colon mid-sentence.
    private static func inSentence(_ exit: LaunchExitStatus) -> String {
        let text = exit.description
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// The details' notice: what the status line over it ("Failed · exit
    /// code 1", `LaunchItemStatus`) can't say, or nil when it would only
    /// repeat it. A code with no common meaning gets none; a known code and a
    /// crash signal are put in plain words; a run that failed or crashed
    /// before the one running now, which the status line calls Running, and
    /// restarts seen again and again are told in full.
    public func notice(for item: LaunchItem, record: LaunchJobRecord?, time: (Date) -> String) -> LaunchJobNotice? {
        let isRunning = item.pid != nil
        switch self {
        case .healthy:
            return nil
        case let .failed(code) where !isRunning:
            return LaunchExitStatus.meaning(ofCode: code).map {
                LaunchJobNotice(headline: "What exit code \(code) means", text: Self.sentence($0))
            }
        case let .crashed(signal) where !isRunning:
            let name = LaunchExitStatus.signalName(signal) ?? "signal \(signal)"
            return LaunchJobNotice(headline: "What \(name) means",
                                   text: Self.sentence(LaunchExitStatus.meaning(ofSignal: signal) ?? "the program crashed"))
        case .failed, .crashed, .restarting:
            guard let headline, let text = explanation(for: item, record: record, time: time) else { return nil }
            return LaunchJobNotice(headline: headline, text: text)
        }
    }

    /// Whether the status line or the notice already gives the job's last
    /// exit, so a Last exit line in the details would only repeat it.
    public var tellsLastExit: Bool {
        switch self {
        case .failed, .crashed: true
        case .healthy, .restarting: false
        }
    }

    /// "Its program wasn't found." from "its program wasn't found".
    private static func sentence(_ phrase: String) -> String {
        phrase.prefix(1).uppercased() + phrase.dropFirst() + "."
    }
}

/// A heading and a sentence or two for the Startup details, under the status
/// line, about a job that needs a look (`LaunchJobHealth.notice`).
public struct LaunchJobNotice: Hashable, Sendable {
    public let headline: String
    public let text: String

    public init(headline: String, text: String) {
        self.headline = headline
        self.text = text
    }
}
