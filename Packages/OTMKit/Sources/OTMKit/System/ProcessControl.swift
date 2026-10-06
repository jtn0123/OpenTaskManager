import Darwin
import Foundation

public enum ProcessControlError: Error, Equatable, LocalizedError {
    /// The process belongs to root or another user; retry with administrator rights.
    case permissionDenied
    case noSuchProcess
    case failed(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Permission denied. This process belongs to another user or the system."
        case .noSuchProcess: "The process is no longer running."
        case let .failed(code): String(cString: strerror(code))
        }
    }

    static func fromErrno(_ code: Int32 = errno) -> ProcessControlError {
        switch code {
        case EPERM, EACCES: .permissionDenied
        case ESRCH: .noSuchProcess
        default: .failed(errno: code)
        }
    }
}

public enum ProcessSignal: Int32, CaseIterable, Sendable, Identifiable {
    case terminate = 15
    case kill = 9
    case interrupt = 2
    case hangUp = 1
    case quit = 3
    case stop = 17
    case `continue` = 19
    case user1 = 30
    case user2 = 31

    public var id: Int32 { rawValue }

    public var name: String {
        switch self {
        case .terminate: "Terminate (SIGTERM)"
        case .kill: "Kill (SIGKILL)"
        case .interrupt: "Interrupt (SIGINT)"
        case .hangUp: "Hang Up (SIGHUP)"
        case .quit: "Quit (SIGQUIT)"
        case .stop: "Suspend (SIGSTOP)"
        case .continue: "Resume (SIGCONT)"
        case .user1: "User 1 (SIGUSR1)"
        case .user2: "User 2 (SIGUSR2)"
        }
    }
}

public enum ProcessControl {
    public static func send(_ signal: ProcessSignal, to pid: Int32) throws(ProcessControlError) {
        guard pid > 0 else { throw .permissionDenied }
        guard Darwin.kill(pid, signal.rawValue) == 0 else { throw .fromErrno() }
    }

    /// Sets the nice value (-20 highest priority … 20 lowest). Raising
    /// priority (lowering nice) needs root.
    public static func setNice(_ value: Int32, for pid: Int32) throws(ProcessControlError) {
        let clamped = min(max(value, -20), 20)
        guard setpriority(PRIO_PROCESS, id_t(pid), clamped) == 0 else { throw .fromErrno() }
    }

    /// Shell command equivalent of `send`, for running with administrator rights.
    public static func shellCommand(for signal: ProcessSignal, pids: [Int32]) -> String {
        "/bin/kill -\(signal.rawValue) " + pids.map(String.init).joined(separator: " ")
    }

    public static func shellCommand(nice: Int32, pid: Int32) -> String {
        "/usr/bin/renice \(min(max(nice, -20), 20)) -p \(pid)"
    }
}
