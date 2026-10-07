import Foundation

/// What `launchctl` said when a switch failed.
public struct LaunchControlError: Error, Sendable, Equatable {
    public let message: String
}

/// Turning a startup item off and on, and starting or stopping its job.
/// Only third-party agents are controlled, and only in your own session,
/// which needs no administrator: daemons run outside any session, and
/// Apple's agents are part of macOS.
public enum LaunchControl {
    public enum Action: Sendable {
        case disable, enable
        /// Start it now, stop it and start it again, or ask it to quit. A
        /// job that launchd keeps alive comes straight back after a stop.
        case start, restart, stop
    }

    /// Why an item can't be switched from here, or nil when it can.
    public static func restriction(for item: LaunchItem) -> String? {
        if item.isMissingLabel || item.isUnreadable { return "launchd can't load this property list, so there's nothing to switch." }
        if item.scope == .daemon { return "Daemons run outside your session, so switching one needs an administrator." }
        if item.publisher == .apple { return "Apple's agents are part of macOS, so OpenTaskManager leaves them alone." }
        return nil
    }

    /// The `launchctl` calls for an action, in order. Disabling also unloads
    /// the job, so it stops now as well as at the next login; enabling loads
    /// it again, so it doesn't wait for one.
    public static func commands(_ action: Action, for item: LaunchItem, uid: uid_t) -> [[String]] {
        let domain = "gui/\(uid)"
        let service = "\(domain)/\(item.label)"
        return switch action {
        case .disable: [["disable", service], ["bootout", service]]
        case .enable: [["enable", service], ["bootstrap", domain, item.plistPath]]
        case .start: [["kickstart", service]]
        case .restart: [["kickstart", "-k", service]]
        case .stop: [["kill", "SIGTERM", service]]
        }
    }

    /// Runs an action. The override is what lasts, so only that first call
    /// decides success: unloading a job that isn't loaded, or loading one
    /// that already is, fails harmlessly.
    public static func perform(_ action: Action, for item: LaunchItem, uid: uid_t = getuid()) throws(LaunchControlError) {
        if let reason = restriction(for: item) { throw LaunchControlError(message: reason) }
        let calls = commands(action, for: item, uid: uid)
        for (index, arguments) in calls.enumerated() {
            let result = Launchctl.execute(arguments)
            if index == 0, result.status != 0 {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LaunchControlError(message: detail.isEmpty ? "launchctl \(arguments[0]) failed with status \(result.status)." : detail)
            }
        }
    }
}
