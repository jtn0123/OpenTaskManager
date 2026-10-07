import Darwin
import Foundation
@testable import OTMKit
import Testing

/// The process inspector's deeper figures: identity across PID reuse,
/// ancestry, per-thread CPU and counter rates.
struct ProcessDiagnosisTests {
    private static let early = Date(timeIntervalSince1970: 1_000)
    private static let late = Date(timeIntervalSince1970: 2_000)

    private func process(_ pid: Int32, parent: Int32 = 1, name: String? = nil, started: Date? = early) -> ProcessSample {
        ProcessSample(
            pid: pid, parentPID: parent, responsiblePID: pid, uid: 501, userName: "me", name: name ?? "proc\(pid)",
            executablePath: nil, state: .sleeping, nice: 0, startTime: started, isTranslated: false, isRestricted: false,
            cpuPercent: 0, cpuTime: 0, memory: 0, residentMemory: 0, threadCount: 1,
            diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0
        )
    }

    private func thread(_ id: UInt64, cpu: Double, name: String? = nil, state: ThreadRunState = .waiting,
                        priority: Int32 = 31) -> ThreadSample {
        ThreadSample(id: id, name: name, userTime: cpu * 0.75, systemTime: cpu * 0.25, state: state,
                     priority: priority, basePriority: 31, policy: .timesharing)
    }

    // MARK: Identity

    @Test func aReusedPIDIsAnotherProcess() {
        let first = process(500, started: Self.early)
        let later = process(500, started: Self.late)
        #expect(first.identity != later.identity)
        #expect(first.identity == process(500, started: Self.early).identity)
        #expect(first.identity.find(in: [later]) == nil, "the PID now belongs to a later process")
        #expect(later.identity.find(in: [process(7), later])?.startTime == Self.late)
    }

    @Test func startTimesConvertOneWay() {
        let micro: Int64 = 1_759_840_000_123_456
        #expect(ProcessIdentity.startTime(microseconds: micro) == ProcessIdentity.startTime(microseconds: micro))
        #expect(ProcessIdentity.startTime(microseconds: micro) != ProcessIdentity.startTime(microseconds: micro + 1))
        #expect(ProcessIdentity.startTime(microseconds: 0) == nil, "no start time read")
    }

    // MARK: Ancestry

    @Test func ancestryRunsFromLaunchdDownToTheProcess() {
        let processes = [
            process(1, parent: 0, name: "launchd"), process(194, parent: 1, name: "loginwindow"),
            process(407, parent: 194, name: "Finder"), process(900, parent: 407, name: "helper"),
        ]
        let ancestry = ProcessAncestry.build(for: processes[3], in: processes)
        #expect(ancestry.chain.map(\.pid) == [1, 194, 407, 900])
        #expect(ancestry.ancestors.map(\.pid) == [1, 194, 407])
        #expect(ancestry.gap == nil)
        #expect(ProcessAncestry.build(for: processes[0], in: processes).chain.map(\.pid) == [1], "launchd's parent is the kernel")
    }

    @Test func ancestryStopsAtAParentThatIsGoneOrYounger() {
        let missing = ProcessAncestry.build(for: process(900, parent: 444), in: [process(1, parent: 0), process(900, parent: 444)])
        #expect(missing.chain.map(\.pid) == [900])
        #expect(missing.gap == .notListed(444))

        // PID 444 now belongs to a process that started after its supposed child.
        let processes = [process(444, started: Self.late), process(900, parent: 444, started: Self.early)]
        let replaced = ProcessAncestry.build(for: processes[1], in: processes)
        #expect(replaced.chain.map(\.pid) == [900])
        #expect(replaced.gap == .replaced(444))
        #expect(replaced.gap?.pid == 444)
    }

    @Test func ancestrySurvivesLoopsAndLongChains() {
        let loop = [process(10, parent: 11), process(11, parent: 10)]
        #expect(ProcessAncestry.build(for: loop[0], in: loop).chain.map(\.pid) == [11, 10])

        let long = (2...100).map { process(Int32($0), parent: Int32($0 - 1)) }
        let chain = ProcessAncestry.build(for: long.last!, in: long, limit: 8).chain
        #expect(chain.count == 8)
        #expect(chain.last?.pid == 100)
    }

    // MARK: Threads

    @Test func threadCPUComesFromTheChangeInCPUTime() {
        let identity = process(407).identity
        var tracker = ThreadActivityTracker()
        let first = tracker.update([thread(1, cpu: 10), thread(2, cpu: 4)], of: identity, at: 100)
        #expect(first.allSatisfy { $0.cpuPercent == nil }, "nothing to compare the first reading with")

        let second = tracker.update([thread(1, cpu: 10.5), thread(2, cpu: 4), thread(3, cpu: 0.25)], of: identity, at: 102)
        let cpu = Dictionary(uniqueKeysWithValues: second.map { ($0.id, $0.cpuPercent) })
        #expect(cpu[1] == 25, "half a second over two seconds")
        #expect(cpu[2] == 0)
        #expect(cpu[3] == 12.5, "a new thread spent all its time since the last reading")
    }

    @Test func threadCPUIsClampedAndStartsAfreshForANewProcess() {
        let identity = process(407, started: Self.early).identity
        var tracker = ThreadActivityTracker()
        _ = tracker.update([thread(1, cpu: 10)], of: identity, at: 100)
        let odd = tracker.update([thread(1, cpu: 9)], of: identity, at: 101)
        #expect(odd.first?.cpuPercent == 0, "CPU time never runs backwards into a negative figure")
        let jitter = tracker.update([thread(1, cpu: 10.2)], of: identity, at: 102)
        #expect(jitter.first?.cpuPercent == 100, "no thread uses more than one core")

        let reused = tracker.update([thread(1, cpu: 50)], of: process(407, started: Self.late).identity, at: 103)
        #expect(reused.first?.cpuPercent == nil, "the PID's new process has no history with the old one's threads")
        #expect(tracker.process?.startTime == Self.late)
    }

    @Test func threadsSortBusiestFirstWithTiesByID() {
        let rows = [
            ThreadActivity(thread: thread(30, cpu: 1, name: "b"), cpuPercent: 5),
            ThreadActivity(thread: thread(10, cpu: 9, name: nil, state: .running, priority: 47), cpuPercent: 5),
            ThreadActivity(thread: thread(20, cpu: 3, name: "a"), cpuPercent: 40),
            ThreadActivity(thread: thread(40, cpu: 0, name: "C"), cpuPercent: nil),
        ]
        #expect(ThreadActivitySort.sorted(rows, by: .cpu, ascending: false).map(\.id) == [20, 10, 30, 40])
        #expect(ThreadActivitySort.sorted(rows, by: .cpuTime, ascending: false).map(\.id) == [10, 20, 30, 40])
        #expect(ThreadActivitySort.sorted(rows, by: .name, ascending: true).map(\.id) == [20, 30, 40, 10],
                "unnamed threads after the named ones")
        #expect(ThreadActivitySort.sorted(rows, by: .name, ascending: false).map(\.id) == [40, 30, 20, 10])
        #expect(ThreadActivitySort.sorted(rows, by: .state, ascending: false).first?.id == 10, "running first")
        #expect(ThreadActivitySort.sorted(rows, by: .priority, ascending: false).first?.id == 10)
        #expect(ThreadActivitySort.sorted(rows, by: .id, ascending: true).map(\.id) == [10, 20, 30, 40])

        // 0.3% and 0.2% both read 0% in whole steps of 1: thread ID decides.
        let idle = [
            ThreadActivity(thread: thread(2, cpu: 0), cpuPercent: 0.2),
            ThreadActivity(thread: thread(1, cpu: 0), cpuPercent: 0.3),
        ]
        #expect(ThreadActivitySort.sorted(idle, by: .cpu, ascending: false).map(\.id) == [1, 2])
        #expect(ThreadActivitySort.sorted(idle, by: .cpu, ascending: false, cpuStep: 1).map(\.id) == [1, 2])
        let reversed = [idle[1], idle[0]].map { ThreadActivity(thread: $0.thread, cpuPercent: $0.id == 1 ? 0.2 : 0.3) }
        #expect(ThreadActivitySort.sorted(reversed, by: .cpu, ascending: false).map(\.id) == [2, 1])
        #expect(ThreadActivitySort.sorted(reversed, by: .cpu, ascending: false, cpuStep: 1).map(\.id) == [1, 2])
    }

    @Test func threadSummaryCountsAndAddsUp() {
        let rows = [
            ThreadActivity(thread: thread(1, cpu: 1, state: .running), cpuPercent: 12.5),
            ThreadActivity(thread: thread(2, cpu: 1), cpuPercent: 0.5),
        ]
        let summary = ThreadSummary(rows)
        #expect(summary.count == 2)
        #expect(summary.running == 1)
        #expect(summary.cpuPercent == 13)
        #expect(ThreadSummary([ThreadActivity(thread: thread(1, cpu: 1), cpuPercent: nil)]).cpuPercent == nil)
        #expect(ThreadSummary([]).cpuPercent == 0)
    }

    @Test func kernelValuesMapToStatesAndPolicies() {
        #expect(ThreadRunState(kernelValue: 1) == .running)
        #expect(ThreadRunState(kernelValue: 3) == .waiting)
        #expect(ThreadRunState(kernelValue: 4) == .blocked)
        #expect(ThreadRunState(kernelValue: 99) == .unknown)
        #expect(SchedulingPolicy(kernelValue: 1) == .timesharing)
        #expect(SchedulingPolicy(kernelValue: 4) == .fifo)
        #expect(SchedulingPolicy(kernelValue: 0) == .unknown)
        #expect(ProcessReadFailure(errno: EPERM) == .denied)
        #expect(ProcessReadFailure(errno: ESRCH) == .ended)
        #expect(ProcessReadFailure(errno: EINVAL) == .unavailable)
    }

    // MARK: Counters

    private func diagnostics(_ identity: ProcessIdentity, at time: TimeInterval, faults: UInt64) -> ProcessDiagnostics {
        var reading = ProcessDiagnostics.unreadable(identity, at: time, because: .unavailable)
        reading.faults = .value(faults)
        reading.pageIns = .value(faults / 10)
        return reading
    }

    @Test func ratesNeedAnEarlierReadingOfTheSameProcess() {
        let identity = process(407).identity
        let now = diagnostics(identity, at: 12, faults: 1_500)
        #expect(ProcessRates(now, since: nil).faults == .unavailable)
        #expect(ProcessRates(now, since: diagnostics(identity, at: 10, faults: 500)).faults == .value(500))
        #expect(ProcessRates(now, since: diagnostics(identity, at: 10, faults: 500)).pageIns == .value(50))
        let other = process(407, started: Self.late).identity
        #expect(ProcessRates(now, since: diagnostics(other, at: 10, faults: 500)).faults == .unavailable,
                "another process with the PID")
        #expect(ProcessRates(now, since: diagnostics(identity, at: 10, faults: 9_000)).faults == .unavailable,
                "a counter that went down wrapped or was reset")
        #expect(ProcessRates(now, since: nil).contextSwitches == .unavailable, "not read in this test")
    }

    @Test func refusedReadingsStayRefusedFieldByField() {
        let identity = process(1).identity
        let refused = ProcessDiagnostics.unreadable(identity, at: 5, because: .denied)
        #expect(refused.footprint == .denied)
        #expect(refused.qos == .denied)
        #expect(ProcessRates(refused, since: refused).faults == .denied)
        #expect(ProcessDiagnostics.unreadable(identity, at: 5, because: .ended).peakFootprint == .unavailable)
        #expect(ProcessField<UInt64>.value(3).map { $0 * 2 } == .value(6))
        #expect(ProcessField<UInt64>.denied.value == nil)
    }

    @Test func countersShortenPastTenThousand() {
        #expect(Format.count(0) == "0")
        #expect(Format.count(9_999) == "9999")
        #expect(Format.count(10_000) == "10.0K")
        #expect(Format.count(123_456) == "123K")
        #expect(Format.count(999_499) == "999K")
        #expect(Format.count(999_500) == "1.00M", "never 1000K")
        #expect(Format.count(4_560_000) == "4.56M")
        #expect(Format.count(1_070_000_000) == "1.07B")
        #expect(Format.count(UInt64.max).hasSuffix("T"))
        #expect(Format.countRate(0) == "0/s")
        #expect(Format.countRate(2.345) == "2.3/s")
        #expect(Format.countRate(12_345.6) == "12.3K/s")
    }

    @Test func qosSharesAreFractionsOfTheTimeSpent() {
        let shares = QoSShare.shares([.utility: 1, .userInteractive: 3, .background: 0])
        #expect(shares.map(\.qos) == [.userInteractive, .utility])
        #expect(shares.map(\.fraction) == [0.75, 0.25])
        #expect(QoSShare.shares([:]).isEmpty)
    }

    // MARK: Sorting as shown

    @Test func figuresCompareAsTheTableShowsThem() {
        #expect(ShownFigure.bytes(35_110_000) == ShownFigure.bytes(35_140_000), "both read 33.5 MB")
        #expect(ShownFigure.bytes(35_100_000) < ShownFigure.bytes(35_300_000))
        #expect(ShownFigure.bytes(512) == 512)
        #expect(ShownFigure.bytes(0) == 0)
        #expect(ShownFigure.steps(0.04, step: 1.8) == ShownFigure.steps(0.6, step: 1.8), "both read 0.0% of 18 cores")
        #expect(ShownFigure.steps(0.04, step: 0) == 0.04, "no step compares exactly")
        #expect(ShownFigure.watts(0.0123) == ShownFigure.watts(0.0118), "both read 12 mW")
        #expect(ShownFigure.watts(12.34) == 12.3)
    }

    @Test func rowsThatReadTheSameKeepTheirPIDOrder() {
        var processes = [process(300), process(100), process(200), process(400)]
        processes[0].cpuPercent = 0.05
        processes[1].cpuPercent = 0.01
        processes[2].cpuPercent = 0.08
        processes[3].cpuPercent = 25
        let nodes = ProcessTreeBuilder.build(processes, mode: .flat, appPIDs: [])
        let shown = ProcessTreeBuilder.sort(nodes, by: .cpu, ascending: false, cpuStep: 1)
        #expect(shown.map(\.id) == [400, 100, 200, 300], "the idle three all read 0.0%")
        let exact = ProcessTreeBuilder.sort(nodes, by: .cpu, ascending: false)
        #expect(exact.map(\.id) == [400, 200, 300, 100])
    }

    // MARK: This machine

    @Test func readsThisProcessesCountersAndThreads() throws {
        let identity = try #require(ProcessDetailReader.identity(of: getpid()))
        #expect(identity.startTime != nil)
        let reading = ProcessDetailReader.diagnostics(identity)
        #expect((reading.footprint.value ?? 0) > 0)
        #expect((reading.peakFootprint.value ?? 0) >= (reading.footprint.value ?? 0))
        #expect((reading.resident.value ?? 0) > 0)
        #expect(reading.policy.value != nil)

        let threads = try ProcessDetailReader.threads(identity).get()
        #expect(!threads.isEmpty)
        #expect(Set(threads.map(\.id)).count == threads.count, "thread IDs are unique")
        #expect(threads.allSatisfy { $0.cpuTime >= 0 })

        // The same PID with another start time is a process that has ended.
        let ended = ProcessIdentity(pid: identity.pid, startTime: Date(timeIntervalSince1970: 1))
        #expect(ProcessDetailReader.diagnostics(ended).footprint == .unavailable)
        #expect(throws: ProcessReadFailure.ended) { try ProcessDetailReader.threads(ended).get() }
    }

    @Test func otherUsersProcessesAreRefusedWithoutRoot() throws {
        guard getuid() != 0, let launchd = ProcessDetailReader.identity(of: 1) else { return }
        #expect(ProcessDetailReader.diagnostics(launchd).faults == .denied)
        #expect(throws: ProcessReadFailure.denied) { try ProcessDetailReader.threads(launchd).get() }
    }
}
