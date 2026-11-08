import Foundation
@testable import OTMKit
import Testing

@MainActor
struct RecentProcessStoreTests {
    private func process(_ pid: Int32) -> ProcessSample {
        ProcessSample(pid: pid, parentPID: 1, responsiblePID: pid, uid: 501, userName: "test", name: "Process \(pid)",
                      executablePath: nil, state: .running, nice: 0, startTime: nil, isTranslated: false, isRestricted: false,
                      cpuPercent: 0, cpuTime: 0, memory: 0, residentMemory: 0, threadCount: 1,
                      diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0)
    }

    private func add(_ store: RecentProcessStore, _ processes: [ProcessSample], time: Double, visible: Bool) {
        store.update(processes, at: .init(date: Date(timeIntervalSince1970: time), uptime: time),
                     step: 1, userID: nil, publishes: visible)
    }

    @Test func hiddenTicksRetainEndsWithoutPublishingAndCatchUpWhenVisible() {
        let store = RecentProcessStore()
        add(store, [process(1), process(2)], time: 100, visible: false)
        add(store, [process(1)], time: 101, visible: false)
        #expect(store.entries.isEmpty)
        add(store, [process(1)], time: 102, visible: true)
        #expect(store.entries.map(\.id.pid) == [2])
    }

    @Test func expiryAndClearWorkWithoutAnotherProcessSample() {
        let store = RecentProcessStore()
        add(store, [process(1), process(2)], time: 100, visible: true)
        add(store, [process(1)], time: 101, visible: true)
        #expect(store.entries.count == 1)
        store.expire(at: 161, publishes: true)
        #expect(store.entries.isEmpty)
        add(store, [process(1), process(3)], time: 162, visible: true)
        add(store, [process(1)], time: 163, visible: true)
        store.clear()
        #expect(store.entries.isEmpty)
        add(store, [process(1)], time: 164, visible: true)
        #expect(store.entries.isEmpty)
    }
}
