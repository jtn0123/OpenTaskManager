import Observation
import OTMKit

/// Users' graphs keep the preceding minute even while the page is hidden.
/// The display totals and their name ordering only matter while it is shown.
@Observable
@MainActor
final class UserUsageStore {
    private(set) var users: [UserUsage] = []
    private(set) var histories: [UInt32: UserHistory] = [:]

    func ingest(_ processes: [ProcessSample], interval: Double, live: Bool) {
        if live { users = UserUsageBuilder.build(processes) }
        guard interval > 0 else { return }
        let totals = live ? Dictionary(uniqueKeysWithValues: users.map { ($0.uid, $0.totals) })
            : UserUsageBuilder.historyTotals(processes)
        var previous = histories
        histories = [:]
        var next: [UInt32: UserHistory] = [:]
        for (uid, totals) in totals {
            // Remove the old ring before appending, so it grows in place.
            var history = previous.removeValue(forKey: uid) ?? UserHistory()
            history.append(totals)
            next[uid] = history
        }
        histories = next
    }
}
