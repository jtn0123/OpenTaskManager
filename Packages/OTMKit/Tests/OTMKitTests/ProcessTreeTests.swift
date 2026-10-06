@testable import OTMKit
import Testing

struct ProcessTreeTests {
    private static let me: UInt32 = 501

    private func process(
        _ pid: Int32, parent: Int32 = 1, responsible: Int32? = nil, uid: UInt32 = me,
        name: String? = nil, cpu: Double = 0, memory: UInt64 = 0
    ) -> ProcessSample {
        ProcessSample(
            pid: pid, parentPID: parent, responsiblePID: responsible ?? pid, uid: uid,
            userName: uid == 0 ? "root" : "me", name: name ?? "proc\(pid)", executablePath: nil,
            state: .sleeping, nice: 0, startTime: nil, isTranslated: false, isRestricted: false,
            cpuPercent: cpu, cpuTime: 0, memory: memory, residentMemory: memory, threadCount: 1,
            diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0
        )
    }

    private var sample: [ProcessSample] {
        [
            process(1, parent: 0, uid: 0, name: "launchd", cpu: 1),
            process(100, name: "Safari", cpu: 10, memory: 100),
            process(101, responsible: 100, name: "Safari Web Content", cpu: 30, memory: 300),
            process(102, responsible: 100, name: "Safari Networking", cpu: 5, memory: 50),
            process(200, name: "Mail", cpu: 2, memory: 20),
            process(300, name: "agent", cpu: 1),
            process(301, parent: 300, responsible: 300, name: "agent-xpc", cpu: 1),
            process(400, uid: 0, name: "kernel-ish", cpu: 4),
        ]
    }

    @Test func groupsAppsBackgroundAndSystem() {
        let nodes = ProcessTreeBuilder.build(sample, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me)
        #expect(nodes.map(\.section) == [.apps, .background, .system])

        let apps = nodes[0]
        #expect(apps.children.map(\.id) == [100, 200])
        let safari = apps.children[0]
        #expect(Set(safari.children.map(\.id)) == [101, 102])
        #expect(safari.totals.cpuPercent == 45)
        #expect(safari.totals.memory == 450)
        #expect(safari.totals.processCount == 3)
        #expect(apps.totals.processCount == 4)

        #expect(nodes[1].children.map(\.id) == [300])
        #expect(nodes[1].children[0].children.map(\.id) == [301])
        #expect(Set(nodes[2].children.map(\.id)) == [1, 400])
    }

    @Test func omitsEmptySections() {
        let nodes = ProcessTreeBuilder.build([process(5, name: "solo")], mode: .grouped, appPIDs: [], currentUID: Self.me)
        #expect(nodes.map(\.section) == [.background])
    }

    @Test func buildsParentChildTree() {
        let nodes = ProcessTreeBuilder.build(sample, mode: .tree, appPIDs: [], currentUID: Self.me)
        #expect(nodes.map(\.id) == [1])
        let launchd = nodes[0]
        #expect(launchd.children.count == 6)
        #expect(launchd.children.first { $0.id == 300 }?.children.map(\.id) == [301])
        #expect(launchd.totals.processCount == sample.count)
    }

    @Test func flatModeHasNoNesting() {
        let nodes = ProcessTreeBuilder.build(sample, mode: .flat, appPIDs: [100])
        #expect(nodes.count == sample.count)
        #expect(nodes.allSatisfy { $0.children.isEmpty })
    }

    @Test func filterKeepsMatchingBranches() {
        let nodes = ProcessTreeBuilder.build(sample, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me, filter: "web content")
        #expect(nodes.map(\.section) == [.apps])
        #expect(nodes[0].children.map(\.id) == [100])
        #expect(nodes[0].children[0].children.map(\.id) == [101])
        // Totals reflect only what survived the filter.
        #expect(nodes[0].children[0].totals.cpuPercent == 40)
    }

    @Test func filterByPID() {
        let nodes = ProcessTreeBuilder.build(sample, mode: .flat, appPIDs: [], filter: "200")
        #expect(nodes.map(\.id) == [200])
    }

    @Test func sortsWithinSectionsByGroupTotals() {
        let nodes = ProcessTreeBuilder.build(sample, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me)
        let byCPU = ProcessTreeBuilder.sort(nodes, by: .cpu, ascending: false)
        #expect(byCPU.map(\.section) == [.apps, .background, .system])
        #expect(byCPU[0].children.map(\.id) == [100, 200])
        #expect(byCPU[0].children[0].children.map(\.id) == [101, 102])
        #expect(byCPU[2].children.map(\.id) == [400, 1])

        let byName = ProcessTreeBuilder.sort(nodes, by: .name, ascending: true)
        #expect(byName[0].children.map(\.id) == [200, 100])
    }
}
