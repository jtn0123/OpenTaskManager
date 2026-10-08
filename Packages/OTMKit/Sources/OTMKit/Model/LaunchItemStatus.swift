import Foundation

/// A startup item's status in two parts that never mix: what its job is
/// doing (`execution`), the one label both the Startup table's Status column
/// and the details' header show, and whether launchd holds the job at all
/// (`registration`), which the header gives on a line of its own.
///
/// "Loaded" is registration, not something a job does, so it never stands in
/// for the job's state: a loaded job whose last run exited with an error is
/// "Failed · exit code 1" in the row and the header alike, with "Loaded"
/// beside it in the header.
public struct LaunchItemStatus: Hashable, Sendable, Comparable {
    /// What the job is doing, or why nothing runs.
    public enum Execution: Hashable, Sendable {
        case running(pid: Int32)
        /// Seen restarting this many times within `LaunchJobWatch.flappingWindow`,
        /// after failing or though it's kept alive. Running or not at the moment.
        case restarting(count: Int)
        /// Not running, and its last run was ended by this signal: a crash.
        case crashed(signal: Int32)
        /// Not running, and its last run exited with this code.
        case failed(code: Int32)
        /// Loaded and waiting for whatever launches it; its last run, if any, ended cleanly.
        case notRunning
        /// Turned off, so launchd won't start it.
        case disabled
        /// launchd hasn't loaded its property list, so nothing starts it.
        case notLoaded
    }

    /// Whether launchd holds the job, and whether it's turned off.
    public struct Registration: Hashable, Sendable {
        public let isLoaded: Bool
        public let isDisabled: Bool

        public init(isLoaded: Bool, isDisabled: Bool) {
            self.isLoaded = isLoaded
            self.isDisabled = isDisabled
        }

        /// "Loaded" or "Not loaded". Disabled is the execution's word while
        /// nothing runs, and the details say what disabled it.
        public var title: String { isLoaded ? "Loaded" : "Not loaded" }

        /// What that means, for a tooltip.
        public var explanation: String {
            switch (isLoaded, isDisabled) {
            case (true, false): "launchd has loaded its property list, so whatever launches the job can start it."
            case (true, true): "launchd still holds the job, but it's disabled, so launchd won't start it again."
            case (false, true): "Disabled, so launchd doesn't load it or start it."
            case (false, false): "launchd hasn't loaded its property list, so nothing starts it."
            }
        }
    }

    public let execution: Execution
    public let registration: Registration
    /// The job needs a look. Also set while it runs again after a run that
    /// crashed or failed, which `execution` alone doesn't say.
    public let needsAttention: Bool

    public init(execution: Execution, registration: Registration, needsAttention: Bool) {
        self.execution = execution
        self.registration = registration
        self.needsAttention = needsAttention
    }

    /// The status of `item`, whose job looks as `health` says. A crash or
    /// failure names the state only while nothing runs: a job running again
    /// says Running, marked as needing a look. Restarting wins over both.
    public init(item: LaunchItem, health: LaunchJobHealth) {
        let registration = Registration(isLoaded: item.job != nil, isDisabled: item.isDisabled)
        let execution: Execution = switch (health, item.pid) {
        case let (.restarting(count), _): .restarting(count: count)
        case let (_, pid?): .running(pid: pid)
        case let (.crashed(signal), nil): .crashed(signal: signal)
        case let (.failed(code), nil): .failed(code: code)
        case (.healthy, nil): item.isDisabled ? .disabled : registration.isLoaded ? .notRunning : .notLoaded
        }
        self.init(execution: execution, registration: registration, needsAttention: health.needsAttention)
    }

    /// The state in a word or two: "Running", "Failed", "Not running".
    public var title: String {
        switch execution {
        case .running: "Running"
        case .restarting: "Restarting"
        case .crashed: "Crashed"
        case .failed: "Failed"
        case .notRunning: "Not running"
        case .disabled: "Disabled"
        case .notLoaded: "Not loaded"
        }
    }

    /// What goes with the title where there's room: "PID 501",
    /// "exit code 1", "SIGSEGV", "3 times in 15 min".
    public var detail: String? {
        switch execution {
        // Interpolated as a string, so the PID isn't grouped like a quantity.
        case let .running(pid): "PID \(pid)"
        case let .restarting(count): "\(count) times in \(Int(LaunchJobWatch.flappingWindow / 60)) min"
        case let .crashed(signal): LaunchExitStatus.signalName(signal) ?? "signal \(signal)"
        case let .failed(code): "exit code \(code)"
        case .notRunning, .disabled, .notLoaded: nil
        }
    }

    /// The detail in a narrow column, where the full one doesn't fit:
    /// "exit 1", "SEGV", "3×". Nil for a PID, which the details give, so a
    /// running job's cell says just "Running" there. Where even this doesn't
    /// fit, the cell's tooltip (`summary`) keeps it.
    public var compactDetail: String? {
        switch execution {
        case let .restarting(count): "\(count)×"
        case let .crashed(signal): LaunchExitStatus.signalName(signal).map { String($0.dropFirst(3)) } ?? "signal \(signal)"
        case let .failed(code): "exit \(code)"
        case .running, .notRunning, .disabled, .notLoaded: nil
        }
    }

    /// Title and detail in one line: "Failed · exit code 1".
    public var summary: String {
        [title, detail].compactMap(\.self).joined(separator: " · ")
    }

    /// What the state means, for a tooltip.
    public var explanation: String {
        switch execution {
        case let .running(pid):
            needsAttention ? "Its process (PID \(pid)) is running now, after a run that crashed or failed."
                : "launchd started it, and its process (PID \(pid)) is running now."
        case let .restarting(count):
            "Seen starting again \(count) times in the last \(Int(LaunchJobWatch.flappingWindow / 60)) minutes, "
                + "after runs that crashed or failed, or though launchd keeps it alive."
        case .crashed:
            "Nothing is running now, and its last run crashed (\(detail ?? "a signal"))."
        case let .failed(code):
            "Nothing is running now, and its last run exited with code \(code)."
        case .notRunning:
            "Nothing is running now. launchd starts it whenever something launches it (see Launches)."
        case .disabled:
            "Disabled: launchd won't start it until it's enabled again."
        case .notLoaded:
            "launchd hasn't loaded this property list, so nothing starts it."
        }
    }

    /// Running first, then the troubled states, then the quiet ones; running
    /// jobs by PID.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.rank, lhs.pid) < (rhs.rank, rhs.pid)
    }

    private var rank: Int {
        switch execution {
        case .running: 0
        case .restarting: 1
        case .crashed: 2
        case .failed: 3
        case .notRunning: 4
        case .disabled: 5
        case .notLoaded: 6
        }
    }

    private var pid: Int32 {
        if case let .running(pid) = execution { return pid }
        return 0
    }
}
