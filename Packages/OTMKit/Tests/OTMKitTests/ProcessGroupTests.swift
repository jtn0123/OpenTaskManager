import Foundation
@testable import OTMKit
import Testing

struct ProcessGroupTests {
    private static let me: UInt32 = 501

    /// `started` counts seconds from a fixed moment; nil leaves it unknown.
    private func process(
        _ pid: Int32, parent: Int32 = 1, responsible: Int32? = nil, name: String? = nil, started: Double? = 0,
        cpu: Double = 0, memory: UInt64 = 0, threads: Int = 1, restricted: Bool = false
    ) -> ProcessSample {
        ProcessSample(
            pid: pid, parentPID: parent, responsiblePID: responsible ?? pid, uid: restricted ? 0 : Self.me,
            userName: restricted ? "root" : "me", name: name ?? "proc\(pid)", executablePath: nil,
            state: .sleeping, nice: 0, startTime: started.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) },
            isTranslated: false, isRestricted: restricted,
            cpuPercent: cpu, cpuTime: 0, memory: memory, residentMemory: memory, threadCount: threads,
            diskReadRate: restricted ? 0 : 10, diskWriteRate: restricted ? 0 : 1, diskReadTotal: 0, diskWriteTotal: 0
        )
    }

    /// Safari, its helpers, and a helper's helper; Terminal and a shell
    /// that runs a build.
    private var sample: [ProcessSample] {
        [
            process(1, parent: 0, name: "launchd", restricted: true),
            process(100, name: "Safari", started: 10, cpu: 10, memory: 100, threads: 20),
            process(101, parent: 1, responsible: 100, name: "Safari Web Content", started: 11, cpu: 30, memory: 300, threads: 8),
            process(102, parent: 1, responsible: 100, name: "Safari Networking", started: 12, cpu: 5, memory: 50, threads: 4),
            process(103, parent: 1, responsible: 101, name: "Web Content's helper", started: 13, cpu: 1, memory: 10),
            process(200, name: "Terminal", started: 20, cpu: 2, memory: 20),
            process(201, parent: 200, responsible: 200, name: "login", started: 21),
            process(202, parent: 201, responsible: 200, name: "zsh", started: 22, cpu: 1),
            process(203, parent: 202, responsible: 200, name: "make", started: 23, cpu: 4),
        ]
    }

    private func ids(_ members: [ProcessGroupMember]) -> [Int32] {
        members.map(\.process.pid)
    }

    // MARK: Membership

    @Test func groupedMembersSayWhoIsResponsibleForThem() throws {
        let rows = ProcessTreeBuilder.build(sample, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me)
        let node = try #require(ProcessTreeBuilder.node(for: 100, in: rows))
        let group = try #require(ProcessGroup(node: node, mode: .grouped))
        #expect(group.root.pid == 100)
        #expect(Set(ids(group.members)) == [100, 101, 102, 103])
        #expect(group.members.first?.reason == .root)
        let reasons = Dictionary(uniqueKeysWithValues: group.members.map { ($0.process.pid, $0.reason) })
        #expect(reasons[101] == .responsible)
        #expect(reasons[102] == .responsible)
        #expect(reasons[103] == .responsibleThrough(pid: 101), "a helper's helper comes in through the helper")
        #expect(reasons[103]?.via == 101)
        let depths = Dictionary(uniqueKeysWithValues: group.members.map { ($0.process.pid, $0.depth) })
        #expect(depths == [100: 0, 101: 1, 102: 1, 103: 2])
    }

    @Test func treeMembersSayWhoStartedThem() throws {
        let node = try #require(ProcessTreeBuilder.subtree(of: sample[5].identity, in: sample))
        let group = try #require(ProcessGroup(node: node, mode: .tree))
        #expect(ids(group.members) == [200, 201, 202, 203], "each process before those it started")
        #expect(group.members.map(\.reason) == [.root, .child, .startedBy(pid: 201), .startedBy(pid: 202)])
        #expect(group.members.map(\.depth) == [0, 1, 2, 3])
        #expect(group.members.map(\.reason.via) == [nil, nil, 201, 202])
    }

    @Test func aSubtreeIsTheRowTreeShows() throws {
        let tree = ProcessTreeBuilder.build(sample, mode: .tree, appPIDs: [], currentUID: Self.me)
        for process in sample {
            let row = try #require(ProcessTreeBuilder.node(for: process.pid, in: tree))
            let subtree = try #require(ProcessTreeBuilder.subtree(of: process.identity, in: sample))
            #expect(subtree.totals == row.totals, "PID \(process.pid)")
            #expect(subtree.children.map(\.id) == row.children.map(\.id), "PID \(process.pid)")
        }
    }

    @Test func findsTheGroupTheTableNestsWithoutASearch() throws {
        let grouped = try #require(ProcessGroup.find(sample[1].identity, in: sample, mode: .grouped))
        let rows = ProcessTreeBuilder.build(sample, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me, filter: "networking")
        let filteredRow = try #require(ProcessTreeBuilder.node(for: 100, in: rows))
        #expect(filteredRow.children.map(\.id) == [102], "the table's search keeps one helper")
        #expect(grouped.members.count == 4, "the group is the whole app's")
        #expect(grouped.figures.processCount == 4)

        let tree = try #require(ProcessGroup.find(sample[6].identity, in: sample, mode: .tree))
        #expect(ids(tree.members) == [201, 202, 203])

        #expect(ProcessGroup.find(sample[1].identity, in: sample, mode: .flat) == nil, "Flat nests nothing")
        #expect(ProcessGroup.find(sample[2].identity, in: sample, mode: .grouped) == nil, "a helper heads no group of its own")
    }

    @Test func noGroupForASectionRowOrInFlat() throws {
        let rows = ProcessTreeBuilder.build(sample, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me)
        let section = try #require(rows.first)
        #expect(ProcessGroup(node: section, mode: .grouped) == nil)
        let row = try #require(ProcessTreeBuilder.node(for: 100, in: rows))
        #expect(ProcessGroup(node: row, mode: .flat) == nil)
    }

    // MARK: Identity

    @Test func membershipFollowsStartTimes() {
        // The helper ended: the next sample hasn't got it, so neither has the group.
        var later = sample.filter { $0.pid != 102 }
        #expect(ProcessGroup.find(sample[1].identity, in: later, mode: .grouped)?.members.map(\.process.pid).contains(102) == false)

        // A later process took the helper's PID; it isn't Safari's.
        later.append(process(102, parent: 1, name: "something else", started: 50))
        let group = ProcessGroup.find(sample[1].identity, in: later, mode: .grouped)
        #expect(group.map { Set(ids($0.members)) } == [100, 101, 103])

        // Safari quit and a later process took its PID: Safari's group is gone.
        let replaced = sample.map { $0.pid == 100 ? process(100, name: "newcomer", started: 60) : $0 }
        #expect(ProcessGroup.find(sample[1].identity, in: replaced, mode: .grouped) == nil)
    }

    @Test func helpersOfAnEndedAppDontJoinTheProcessGivenItsPID() throws {
        // Safari quit, leaving its helpers a moment, and a later process took PID 100.
        let replaced = sample.map { $0.pid == 100 ? process(100, name: "newcomer", started: 60) : $0 }
        let rows = ProcessTreeBuilder.build(replaced, mode: .grouped, appPIDs: [], currentUID: Self.me)
        let newcomer = try #require(ProcessTreeBuilder.node(for: 100, in: rows))
        #expect(newcomer.children.isEmpty, "they started before it, so it can't be responsible for them")
        #expect(ProcessTreeBuilder.node(for: 101, in: rows)?.children.map(\.id) == [103], "each heads its own row again")

        // Unknown start times can't tell, so they group as before.
        let unknown = sample.map { process($0.pid, parent: $0.parentPID, responsible: $0.responsiblePID, started: nil) }
        let unknownRows = ProcessTreeBuilder.build(unknown, mode: .grouped, appPIDs: [], currentUID: Self.me)
        #expect(ProcessTreeBuilder.node(for: 100, in: unknownRows)?.children.count == 3)
    }

    // MARK: Figures

    @Test func addsUpTheMembersFigures() throws {
        let group = try #require(ProcessGroup.find(sample[1].identity, in: sample, mode: .grouped))
        let figures = group.figures
        #expect(figures.cpuPercent == 46)
        #expect(figures.memory == 460, "summed footprints")
        #expect(figures.threads == 33)
        #expect(figures.processCount == 4)
        #expect(figures.diskReadRate == 40)
        #expect(figures.diskWriteRate == 4)
        #expect(figures.restrictedCount == 0)
        #expect(figures.isDiskRead)
        #expect(figures.gpuFraction == nil, "no member has a GPU reading")
        #expect(figures.powerWatts == nil, "no member has a power reading: missing, not 0 W")
    }

    @Test func leavesUnreadFiguresOutOfTheSums() {
        var members = [
            process(10, cpu: 5, memory: 100),
            process(11, responsible: 10, cpu: 1, memory: 50, restricted: true),
            process(12, responsible: 10, cpu: 2, memory: 25),
        ]
        members[0].gpuTime = 1
        members[0].gpuFraction = 0.25
        members[2].powerWatts = 0
        members[0].powerWatts = 1.5
        let figures = ProcessGroupFigures(members)
        #expect(figures.cpuPercent == 8)
        #expect(figures.memory == 175)
        #expect(figures.restrictedCount == 1)
        #expect(figures.diskReadRate == 20, "the restricted member's disk isn't known")
        #expect(figures.gpuFraction == 0.25)
        #expect(figures.powerWatts == 1.5)
        #expect(ProcessGroupFigures([process(1, restricted: true)]).isDiskRead == false)
        #expect(ProcessGroupFigures([members[2]]).powerWatts == 0, "a measured 0 W is a reading")
    }

    // MARK: Order

    @Test func sortsMembersAsTheTableSortsRows() throws {
        let group = try #require(ProcessGroup.find(sample[1].identity, in: sample, mode: .grouped))
        #expect(ids(group.members(sortedBy: .cpu, ascending: false)) == [101, 100, 102, 103])
        #expect(ids(group.members(sortedBy: .memory, ascending: true)) == [103, 102, 100, 101])
        #expect(ids(group.members(sortedBy: .pid, ascending: true)) == [100, 101, 102, 103])
        #expect(ids(group.members(sortedBy: .name, ascending: true)) == [100, 102, 101, 103])
        // Figures that read the same keep PID order.
        let even = ProcessGroup.find(sample[5].identity, in: sample, mode: .grouped)
        #expect(even.map { ids($0.members(sortedBy: .cpu, ascending: false, cpuStep: 10)) } == [200, 201, 202, 203])
    }

    @Test func endsTheFurthestFirstAndTheRootLast() throws {
        let tree = try #require(ProcessGroup.find(sample[5].identity, in: sample, mode: .tree))
        #expect(ids(tree.endingPlan(ownPID: 999).targets) == [203, 202, 201, 200])
        let grouped = try #require(ProcessGroup.find(sample[1].identity, in: sample, mode: .grouped))
        let plan = grouped.endingPlan(ownPID: 999)
        #expect(ids(plan.targets) == [103, 101, 102, 100])
        #expect(plan.leftAlone.isEmpty)
    }

    @Test func leavesOthersProcessesAndItselfAlone() throws {
        let processes = [
            process(1, parent: 0, name: "launchd", restricted: true),
            process(50, parent: 1, name: "shell"),
            process(51, parent: 50, name: "sudo", restricted: true),
            process(52, parent: 50, name: "OpenTaskManager"),
            process(53, parent: 50, name: "make"),
        ]
        let group = try #require(ProcessGroup.find(processes[1].identity, in: processes, mode: .tree))
        let plan = group.endingPlan(ownPID: 52)
        #expect(ids(plan.targets) == [53, 50], "only your own, and never the app itself")
        #expect(ids(plan.leftAlone) == [51, 52])

        let launchd = try #require(ProcessGroup.find(processes[0].identity, in: processes, mode: .tree))
        let session = launchd.endingPlan(ownPID: 52)
        #expect(session.targets.isEmpty, "launchd's branch is the whole session")
        #expect(session.leftAlone.count == processes.count)
    }

    // MARK: Ending

    @Test func revalidatesEachTargetJustBeforeActing() {
        let running = ProcessIdentity(pid: 10, startTime: Date(timeIntervalSince1970: 100))
        let replaced = ProcessIdentity(pid: 11, startTime: Date(timeIntervalSince1970: 100))
        let ended = ProcessIdentity(pid: 12, startTime: Date(timeIntervalSince1970: 100))
        let now: [Int32: ProcessIdentity] = [
            10: running,
            11: ProcessIdentity(pid: 11, startTime: Date(timeIntervalSince1970: 200)),
            // A process that joined after the list was shown isn't in it, so it's never reached.
            13: ProcessIdentity(pid: 13, startTime: Date(timeIntervalSince1970: 300)),
        ]
        let result = ProcessGroupEnding.revalidate([running, replaced, ended, running]) { now[$0] }
        #expect(result.live == [running], "listed once, though confirmed twice")
        #expect(result.gone == [replaced, ended])
    }
}
