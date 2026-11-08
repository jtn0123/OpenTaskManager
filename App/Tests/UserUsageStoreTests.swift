import Foundation
@testable import OTMKit
import Testing

@MainActor
struct UserUsageStoreTests {
    @Test func hiddenUsersKeepHistoryWithoutPublishingDisplayTotals() throws {
        let store = UserUsageStore(historyCapacity: 3)
        store.ingest([process(uid: 501, cpu: 10, memory: 100)], interval: 1, live: true)
        let displayed = store.users
        store.ingest([process(uid: 501, cpu: 20, memory: 200)], interval: 1, live: false)
        #expect(store.users == displayed)
        let history = try #require(store.histories[501])
        #expect(history.cpu.values == [10, 20])
        #expect(history.memory.values == [100, 200])
        store.ingest([process(uid: 501, cpu: 30, memory: 300)], interval: 1, live: true)
        #expect(store.users.first?.totals.cpuPercent == 30)
        #expect(store.histories[501]?.cpu.values == [10, 20, 30])
    }

    @Test(arguments: [0.0, -1.0])
    func nonPositiveIntervalsRefreshVisibleTotalsWithoutAddingHistory(interval: Double) {
        let store = UserUsageStore(historyCapacity: 3)
        store.ingest([process(uid: 501, cpu: 10, memory: 100)], interval: 1, live: true)
        store.ingest([process(uid: 501, cpu: 20, memory: 200)], interval: interval, live: true)
        #expect(store.users.first?.totals.cpuPercent == 20)
        #expect(store.histories[501]?.cpu.values == [10])
        store.ingest([], interval: interval, live: false)
        #expect(store.users.first?.totals.cpuPercent == 20)
        #expect(store.histories[501]?.memory.values == [100])
    }

    @Test func endedUsersLeaveHistoryAndReturningUsersStartFresh() {
        let store = UserUsageStore(historyCapacity: 3)
        store.ingest([process(uid: 501, cpu: 10, memory: 100), process(uid: 502, cpu: 20, memory: 200)], interval: 1, live: false)
        store.ingest([process(uid: 502, cpu: 30, memory: 300)], interval: 1, live: false)
        #expect(store.histories[501] == nil)
        #expect(store.histories[502]?.cpu.values == [20, 30])
        store.ingest([process(uid: 501, cpu: 40, memory: 400)], interval: 1, live: false)
        #expect(store.histories[501]?.cpu.values == [40])
        #expect(store.histories[502] == nil)
        store.ingest([], interval: 1, live: true)
        #expect(store.users.isEmpty)
        #expect(store.histories.isEmpty)
    }

    private func process(uid: UInt32, cpu: Double, memory: UInt64) -> ProcessSample {
        ProcessSample(
            pid: Int32(uid), parentPID: 1, responsiblePID: Int32(uid), uid: uid, userName: "user\(uid)",
            name: "process", executablePath: nil, state: .running, nice: 0, startTime: nil,
            isTranslated: false, isRestricted: false, cpuPercent: cpu, cpuTime: 0,
            memory: memory, residentMemory: memory, threadCount: 1, diskReadRate: 0,
            diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0
        )
    }
}
