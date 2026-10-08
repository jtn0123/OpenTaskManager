import Foundation
import Observation
import OTMKit
import os

/// What OpenTaskManager has seen of launchd's jobs this session
/// (`LaunchJobWatch` in OTMKit). It outlives the Startup page, so restarts
/// count from the page's first read however often it's left and reopened.
/// The flight recorder also keeps a timeline from these reads and one bulk
/// read a minute while the page isn't reading. Only the page publishes counts.
@MainActor
@Observable
final class LaunchJobStore {
    /// launchd's shortest wait before starting a job that keeps ending again
    /// (its default ThrottleInterval), so a job stuck restarting is seen with
    /// a new process at nearly every read.
    static let readInterval: Duration = .seconds(10)

    private(set) var watch = LaunchJobWatch()
    /// Published after a page observation is saved, so the inspector can't
    /// query before the write and leave its newest events out until Refresh.
    private(set) var historyRead: Date?
    @ObservationIgnored private var lastHistoryRead: ContinuousClock.Instant?
    @ObservationIgnored private var historyReadInFlight = false
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    private static let logger = Logger(subsystem: "OpenTaskManager", category: "LaunchJobHistory")

    func sampleHistory(recorder: FlightRecorder?, enabled: Bool, processes: [ProcessSample]) {
        guard enabled, let recorder, !historyReadInFlight,
              lastHistoryRead.map({ $0.duration(to: .now) >= .seconds(60) }) ?? true else { return }
        lastHistoryRead = .now
        historyReadInFlight = true
        Task {
            let reading = await Task.detached(priority: .utility) { Launchctl.jobReading() }.value
            historyReadInFlight = false
            #if DEBUG
            Self.logger.debug("Launch job bulk read: \(reading.wallSeconds, privacy: .public) s; \(reading.domains.count) domains")
            #endif
            save(reading, recorder: recorder, starts: Self.startTimes(reading, processes: processes))
        }
    }

    func observe(_ inventory: LaunchItemInventory, processes: [ProcessSample], recorder: FlightRecorder?, configurationsRead: Bool) {
        let read = inventory.reading
        let items = inventory.items.filter { read.domains[LaunchHistoryKey($0).domain] != nil }
        observe(items, processes: processes)
        lastHistoryRead = .now
        guard let recorder else { return }
        let starts = Self.startTimes(read, processes: processes)
        save(read, recorder: recorder, items: configurationsRead ? inventory.items : nil, starts: starts, publish: true)
    }

    private static func startTimes(_ reading: LaunchJobReading, processes: [ProcessSample]) -> [Int32: Date] {
        let pids = Set(reading.domains.values.flatMap { $0.values.compactMap(\.pid) })
        return Dictionary(processes.filter { pids.contains($0.pid) }.compactMap { process in
            process.startTime.map { (process.pid, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    func waitForHistoryWrite() async { await pendingWrite?.value }

    private func save(_ reading: LaunchJobReading, recorder: FlightRecorder, items: [LaunchItem]? = nil,
                      starts: [Int32: Date] = [:], publish: Bool = false) {
        let previous = pendingWrite
        pendingWrite = Task {
            await previous?.value
            do {
                try await recorder.observeLaunchJobs(reading, items: items, starts: starts)
                if publish, historyRead.map({ $0 < reading.time }) ?? true { historyRead = reading.time }
            } catch {
                Self.logger.error("Couldn't save launch job history: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

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
