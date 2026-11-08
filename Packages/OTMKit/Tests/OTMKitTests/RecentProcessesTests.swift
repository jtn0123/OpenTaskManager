import Foundation
@testable import OTMKit
import Testing

struct RecentProcessesTests {
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)

    private func process(_ pid: Int32, started: Double? = 10, uid: UInt32 = 501) -> ProcessSample {
        ProcessSample(pid: pid, parentPID: 1, responsiblePID: pid, uid: uid, userName: "test", name: "Process \(pid)",
                      executablePath: "/tmp/process-\(pid)", state: .running, nice: 0,
                      startTime: started.map { origin.addingTimeInterval($0) }, isTranslated: false, isRestricted: false,
                      cpuPercent: 12, cpuTime: 3, memory: 4096, residentMemory: 8192, threadCount: 1,
                      diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0)
    }

    private func update(_ tracker: inout RecentProcesses, _ processes: [ProcessSample]?, at time: Double,
                        step: Double = 1, uid: UInt32? = nil) {
        tracker.update(processes, at: origin.addingTimeInterval(time), uptime: time, step: step, userID: uid)
    }

    @Test func firstSampleDoesNotInventEndsAndAnEndKeepsTheLastSample() throws {
        var tracker = RecentProcesses()
        let keeper = process(1), leaving = process(2)
        update(&tracker, [keeper, leaving], at: 100)
        #expect(tracker.entries.isEmpty)
        var last = leaving
        last.cpuPercent = 22
        update(&tracker, [keeper, last], at: 101)
        update(&tracker, [keeper], at: 102)
        let entry = try #require(tracker.entries.first)
        #expect(entry.id == leaving.identity && entry.process.cpuPercent == 22)
        #expect(entry.process.memory == 4096 && entry.process.executablePath == leaving.executablePath)
        #expect(entry.firstSeen == origin.addingTimeInterval(100))
        #expect(entry.lastSeen == origin.addingTimeInterval(101))
        #expect(entry.missingAt == origin.addingTimeInterval(102))
        #expect(entry.lifetime.identity == leaving.identity)
        #expect(entry.lifetime.ended == entry.missingAt)
        update(&tracker, [keeper], at: 103)
        #expect(tracker.entries.count == 1, "an absent process isn't added every tick")
    }

    @Test func reusedPIDKeepsSeparateIdentitiesAndFrozenValues() throws {
        var tracker = RecentProcesses()
        let old = process(2, started: 10), replacement = process(2, started: 20), keeper = process(1)
        update(&tracker, [keeper, old], at: 100)
        update(&tracker, [keeper, replacement], at: 101)
        #expect(tracker.entries.map(\.id) == [old.identity])
        update(&tracker, [keeper], at: 102)
        #expect(tracker.entries.map(\.id) == [replacement.identity, old.identity])
        #expect(tracker.entries.last?.process.startTime == old.startTime)
    }

    @Test func transientOmissionIsRetractedWhenTheSameIdentityReturns() {
        var tracker = RecentProcesses()
        let keeper = process(1), returning = process(2)
        update(&tracker, [keeper, returning], at: 100)
        update(&tracker, [keeper], at: 101)
        #expect(tracker.entries.count == 1)
        update(&tracker, [keeper, returning], at: 102)
        #expect(tracker.entries.isEmpty)
    }

    @Test func permissionChangesDoNotLookLikePIDReuse() {
        for times: [Double?] in [[nil, 10], [10, nil]] {
            var tracker = RecentProcesses()
            update(&tracker, [process(1), process(2, started: times[0])], at: 100)
            update(&tracker, [process(1), process(2, started: times[1])], at: 101)
            #expect(tracker.entries.isEmpty)
        }
    }

    @Test func gapsUnreadWalksAndPausesDoNotInventEnds() {
        for missing in [false, true] {
            var tracker = RecentProcesses()
            update(&tracker, [process(1), process(2)], at: 100)
            if missing { update(&tracker, nil, at: 101) }
            update(&tracker, [process(1)], at: 110)
            #expect(tracker.entries.isEmpty)
        }
        var tracker = RecentProcesses()
        update(&tracker, [process(1), process(2)], at: 100)
        tracker.resetBaseline()
        update(&tracker, [process(1)], at: 101)
        #expect(tracker.entries.isEmpty)
        update(&tracker, [], at: 102)
        #expect(tracker.entries.isEmpty, "a failed empty enumeration is not every process exiting")
    }

    @Test func scopeChangesResetTheBaselineAndHideOtherUsersHistory() {
        var tracker = RecentProcesses()
        let own = process(1), other = process(2, uid: 0)
        update(&tracker, [own, other], at: 100)
        update(&tracker, [own], at: 101)
        #expect(tracker.entries.count == 1)
        update(&tracker, [own], at: 102, uid: 501)
        #expect(tracker.entries.isEmpty)
        update(&tracker, [own, other], at: 103)
        #expect(tracker.entries.isEmpty)
        update(&tracker, [own], at: 104, uid: 501)
        #expect(tracker.entries.isEmpty)
    }

    @Test func expirationUsesObservationTimeAndClearingDoesNotRepeatAnEnd() {
        var tracker = RecentProcesses()
        update(&tracker, [process(1), process(2)], at: 100)
        update(&tracker, [process(1)], at: 101)
        tracker.expire(at: 160.9)
        #expect(tracker.entries.count == 1)
        tracker.expire(at: 161)
        #expect(tracker.entries.isEmpty)
        update(&tracker, [process(1), process(3)], at: 162)
        update(&tracker, [process(1)], at: 163)
        #expect(tracker.entries.count == 1)
        tracker.clear()
        update(&tracker, [process(1)], at: 164)
        #expect(tracker.entries.isEmpty)
    }

    @Test func duplicateAndBackwardSamplesCannotCreateEnds() {
        var tracker = RecentProcesses()
        update(&tracker, [process(1), process(2)], at: 100)
        update(&tracker, [process(1)], at: 100)
        update(&tracker, [process(1)], at: 99)
        #expect(tracker.entries.isEmpty)
    }

    @Test func delayedOlderSampleCannotCreateAnEndAtItsDeliveryTime() {
        var tracker = RecentProcesses()
        update(&tracker, [process(1), process(2)], at: 100)
        tracker.update([process(1)], at: origin.addingTimeInterval(99), uptime: 101, step: 1)
        #expect(tracker.entries.isEmpty)
        update(&tracker, [process(1)], at: 102)
        #expect(tracker.entries.isEmpty)
    }

    @Test func aLargeBurstIsBoundedAndNewerEntriesComeFirst() {
        var tracker = RecentProcesses()
        let burst = (2...502).map { process(Int32($0)) }
        update(&tracker, [process(1)] + burst, at: 100)
        update(&tracker, [process(1)], at: 101)
        #expect(tracker.entries.count == RecentProcesses.capacity)
        #expect(tracker.entries.first?.id.pid == 2, "ties have deterministic order")
        update(&tracker, [process(1), process(900)], at: 102)
        update(&tracker, [process(1)], at: 103)
        #expect(tracker.entries.count == RecentProcesses.capacity)
        #expect(tracker.entries.first?.id.pid == 900)
    }
}
