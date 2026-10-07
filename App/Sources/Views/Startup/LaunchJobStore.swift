import Foundation
import Observation
import OTMKit

/// What OpenTaskManager has seen of launchd's jobs this session
/// (`LaunchJobWatch` in OTMKit). It outlives the Startup page, so restarts
/// count from the page's first read however often it's left and reopened,
/// but it learns only from that page's reads of launchd's list: when it
/// opens, on Refresh, and every `readInterval` while it's on screen.
@MainActor
@Observable
final class LaunchJobStore {
    /// launchd's shortest wait before starting a job that keeps ending again
    /// (its default ThrottleInterval), so a job stuck restarting is seen with
    /// a new process at nearly every read.
    static let readInterval: Duration = .seconds(10)

    private(set) var watch = LaunchJobWatch()

    /// Notes a read of launchd's list. Each running job's process start comes
    /// from the latest sample, one pass over it, so a PID launchd has handed
    /// to another process isn't taken for the same run.
    func observe(_ items: [LaunchItem], processes: [ProcessSample]) {
        let pids = Set(items.compactMap(\.pid))
        var starts: [Int32: Date] = [:]
        for process in processes where pids.contains(process.pid) {
            starts[process.pid] = process.startTime
        }
        watch.observe(items, startTimes: starts, at: .now)
    }
}
