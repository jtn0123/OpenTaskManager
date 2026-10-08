import Foundation

/// One bulk read of the two accessible domains. A missing domain failed to
/// read; an empty successful domain has no loaded jobs. No job is printed alone.
public struct LaunchJobReading: Sendable {
    public let time: Date
    public let domains: [String: [String: LaunchJobStatus]]
    public let systemOverrides: [String: Bool]
    public let wallSeconds: Double

    public init(time: Date, domains: [String: [String: LaunchJobStatus]], systemOverrides: [String: Bool] = [:], wallSeconds: Double = 0) {
        self.time = time
        self.domains = domains
        self.systemOverrides = systemOverrides
        self.wallSeconds = wallSeconds
    }
}

extension Launchctl {
    /// One fixed pair of bulk commands, independent of the number of jobs.
    /// `list` supplies this login session and `print system` supplies daemons.
    public static func jobReading(uid: uid_t = getuid()) -> LaunchJobReading {
        let start = ContinuousClock.now
        var domains: [String: [String: LaunchJobStatus]] = [:]
        var overrides: [String: Bool] = [:]
        if let user = CommandRunner.execute("/bin/launchctl", ["list"], capture: .output, timeout: 5),
           user.status == 0, user.text.hasPrefix("PID") {
            domains["gui/\(uid)"] = parseList(user.text)
        }
        if let system = CommandRunner.execute("/bin/launchctl", ["print", "system"], capture: .output, timeout: 5),
           system.status == 0, system.text.contains("services = {") {
            domains["system"] = parseServices(system.text)
            overrides = parseDisabled(system.text)
        }
        let duration = start.duration(to: .now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        return LaunchJobReading(time: .now, domains: domains, systemOverrides: overrides, wallSeconds: seconds)
    }
}

public struct LaunchItemInventory: Sendable {
    public let items: [LaunchItem]
    public let reading: LaunchJobReading
}

extension LaunchItems {
    public static func inventory(directories: [LaunchDirectory] = LaunchDirectory.standard(), uid: uid_t = getuid()) -> LaunchItemInventory {
        currentInventory(directories.flatMap { read($0) }, uid: uid)
    }

    public static func currentInventory(_ items: [LaunchItem], uid: uid_t = getuid()) -> LaunchItemInventory {
        let reading = Launchctl.jobReading(uid: uid)
        let overrides = Launchctl.userOverrides(uid: uid)
        let correlated = correlate(items, userJobs: reading.domains["gui/\(uid)"] ?? [:],
                                   systemJobs: reading.domains["system"] ?? [:], userOverrides: overrides,
                                   systemOverrides: reading.systemOverrides)
        let result = zip(items, correlated).map { old, new in
            reading.domains[LaunchHistoryKey(old, uid: uid).domain] == nil ? old : new
        }
        return LaunchItemInventory(items: result, reading: reading)
    }
}
