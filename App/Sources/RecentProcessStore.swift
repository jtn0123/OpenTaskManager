import Foundation
import Observation
import OTMKit

/// Hidden sampling keeps the baseline without publishing UI changes.
@Observable
@MainActor
final class RecentProcessStore {
    struct SampleTime {
        let date: Date
        let uptime: TimeInterval
    }

    private(set) var entries: [RecentlyEndedProcess] = []
    @ObservationIgnored private var tracker = RecentProcesses()

    func update(_ samples: [ProcessSample]?, at time: SampleTime,
                step: TimeInterval, userID: UInt32?, publishes: Bool) {
        tracker.update(samples, at: time.date, uptime: time.uptime, step: step, userID: userID)
        if publishes { publish() }
    }

    func expire(at uptime: TimeInterval, publishes: Bool) {
        tracker.expire(at: uptime)
        if publishes { publish() }
    }

    func resetBaseline() { tracker.resetBaseline() }

    func clear() {
        tracker.clear()
        publish()
    }

    private func publish() {
        if entries != tracker.entries { entries = tracker.entries }
    }
}
