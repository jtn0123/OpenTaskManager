import Foundation
@testable import OTMKit
import Testing

/// An agent from a minimal property list, loaded with `pid` and `lastExit`
/// unless `loaded` is false, and disabled with launchctl when `disabled` is.
private func agent(pid: Int32? = nil, lastExit: LaunchExitStatus? = nil, loaded: Bool = true,
                   disabled: Bool = false) -> LaunchItem {
    let data = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>Label</key><string>com.apple.peakpowermanagerd</string></dict></plist>
    """.utf8)
    var item = LaunchItems.item(plist: data, path: "/System/Library/LaunchDaemons/com.apple.peakpowermanagerd.plist",
                                scope: .daemon)
    if loaded { item.job = LaunchJobStatus(label: item.label, pid: pid, lastExit: lastExit) }
    if disabled { item.disabledOverride = true }
    return item
}

/// The status as the Startup page builds it, from launchd's last exit alone.
private func status(_ item: LaunchItem) -> LaunchItemStatus {
    LaunchItemStatus(item: item, health: LaunchJobWatch().health(of: item))
}

struct LaunchItemStatusTests {
    /// The case that read "Failed" in the table and "Loaded · Not running"
    /// over the details: launchd has it loaded, and its last run failed.
    @Test func aLoadedJobWhoseLastRunFailedSaysFailedNotLoaded() {
        let failed = status(agent(lastExit: .code(1)))
        #expect(failed.execution == .failed(code: 1))
        #expect(failed.title == "Failed")
        #expect(failed.detail == "exit code 1")
        #expect(failed.summary == "Failed · exit code 1")
        #expect(failed.registration.title == "Loaded")
        #expect(failed.needsAttention)
        #expect(failed.explanation == "Nothing is running now, and its last run exited with code 1.")
    }

    /// Every combination the model has gives one execution label, and
    /// registration never takes its place: "Loaded" is only ever the
    /// registration's word.
    @Test func everyCombinationKeepsRegistrationApartFromExecution() {
        let healths: [LaunchJobHealth] = [.healthy, .failed(code: 1), .crashed(signal: 11), .restarting(count: 3)]
        for loaded in [true, false] {
            for disabled in [true, false] {
                for pid in [Int32(77), nil] {
                    for health in healths {
                        let item = agent(pid: pid, loaded: loaded, disabled: disabled)
                        let status = LaunchItemStatus(item: item, health: health)
                        #expect(status.registration == .init(isLoaded: loaded, isDisabled: disabled))
                        #expect(!status.title.contains("Loaded"))
                        #expect(status.needsAttention == health.needsAttention)
                        #expect(status.execution == expected(health: health, pid: loaded ? pid : nil,
                                                             loaded: loaded, disabled: disabled))
                    }
                }
            }
        }
    }

    private func expected(health: LaunchJobHealth, pid: Int32?, loaded: Bool, disabled: Bool) -> LaunchItemStatus.Execution {
        if case let .restarting(count) = health { return .restarting(count: count) }
        if let pid { return .running(pid: pid) }
        switch health {
        case let .crashed(signal): return .crashed(signal: signal)
        case let .failed(code): return .failed(code: code)
        default: return disabled ? .disabled : loaded ? .notRunning : .notLoaded
        }
    }

    @Test func titlesAndDetailsForEachState() {
        let running = status(agent(pid: 4673))
        #expect(running.summary == "Running · PID 4673")
        #expect(running.registration.title == "Loaded")
        #expect(!running.needsAttention)

        // Running again after a crash: Running, marked as needing a look.
        let again = status(agent(pid: 4673, lastExit: .code(-11)))
        #expect(again.title == "Running")
        #expect(again.needsAttention)
        #expect(again.explanation.contains("after a run that crashed or failed"))

        let crashed = status(agent(lastExit: .code(-11)))
        #expect(crashed.summary == "Crashed · SIGSEGV")
        #expect(crashed.registration.title == "Loaded")
        #expect(LaunchItemStatus(execution: .crashed(signal: 30), registration: .init(isLoaded: true, isDisabled: false),
                                 needsAttention: true).detail == "signal 30")

        let restarting = LaunchItemStatus(item: agent(pid: 9), health: .restarting(count: 4))
        #expect(restarting.summary == "Restarting · 4 times in 15 min")

        let idle = status(agent(lastExit: .code(0)))
        #expect(idle.summary == "Not running")
        #expect(idle.registration.title == "Loaded")

        // An idle exit or a stop isn't a failure.
        #expect(status(agent(lastExit: .code(-9))).summary == "Not running")

        #expect(status(agent(disabled: true)).summary == "Disabled")
        #expect(status(agent(disabled: true)).registration.title == "Loaded")
        #expect(status(agent(loaded: false, disabled: true)).registration.title == "Not loaded")
        #expect(status(agent(loaded: false)).summary == "Not loaded")
        #expect(status(agent(loaded: false)).registration.title == "Not loaded")
        // Disabled while its process still runs: Running, and still loaded.
        let stillRunning = status(agent(pid: 12, disabled: true))
        #expect(stillRunning.title == "Running")
        #expect(stillRunning.registration.title == "Loaded")
        #expect(stillRunning.registration.isDisabled)
        #expect(stillRunning.registration.explanation
            == "launchd still holds the job, but it's disabled, so launchd won't start it again.")
    }

    @Test func sortsRunningFirstThenTroubleThenQuiet() {
        let statuses = [
            status(agent(loaded: false)),
            status(agent(disabled: true)),
            status(agent()),
            status(agent(lastExit: .code(1))),
            status(agent(lastExit: .code(-6))),
            LaunchItemStatus(item: agent(), health: .restarting(count: 3)),
            status(agent(pid: 900)),
            status(agent(pid: 20)),
        ]
        #expect(statuses.sorted().map(\.summary) == [
            "Running · PID 20", "Running · PID 900", "Restarting · 3 times in 15 min", "Crashed · SIGABRT",
            "Failed · exit code 1", "Not running", "Disabled", "Not loaded",
        ])
    }

    @Test func namesSignals() {
        #expect(LaunchExitStatus.signalName(11) == "SIGSEGV")
        #expect(LaunchExitStatus.signalName(6) == "SIGABRT")
        #expect(LaunchExitStatus.signalName(40) == nil)
        #expect(LaunchExitStatus.code(-11).description == "Killed by signal 11 (SIGSEGV)")
    }
}
