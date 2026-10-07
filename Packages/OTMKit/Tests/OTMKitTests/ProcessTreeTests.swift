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

    @Test func groupTotalsKnowWhetherPowerWasMeasured() {
        var measured = sample
        measured[1].powerWatts = 1.5
        measured[2].powerWatts = 0
        let nodes = ProcessTreeBuilder.build(measured, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me)
        let apps = nodes[0].children
        #expect(apps[0].totals.isPowerMeasured, "Safari and its helpers have readings")
        #expect(apps[0].totals.powerWatts == 1.5)
        #expect(!apps[1].totals.isPowerMeasured, "Mail has none: its 0 W is missing data")
        #expect(nodes[0].totals.isPowerMeasured)
        #expect(!nodes[2].totals.isPowerMeasured, "nothing in the system section was measured")
        #expect(ProcessTotals(measured[2]).isPowerMeasured, "a measured 0 W is still a measurement")
    }

    @Test func tellsWhetherThisMacCountsEnergyPerProcess() {
        var measured = sample
        measured[1].powerWatts = 0.2
        #expect(ProcessSample.measuresEnergy(measured, interval: 1) == true)
        // A virtual machine's kernel counts no energy, so no process has a reading.
        #expect(ProcessSample.measuresEnergy(sample, interval: 1) == false)
        #expect(ProcessSample.measuresEnergy(sample, interval: 0) == nil, "the first sample has no rates yet")
        #expect(ProcessSample.measuresEnergy([], interval: 1) == nil)
    }

    @Test func findsARowWithTheTotalsTheTableShows() {
        let grouped = ProcessTreeBuilder.build(sample, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me)
        let safari = ProcessTreeBuilder.node(for: 100, in: grouped)
        #expect(safari?.totals.memory == 450, "the app's row counts its helpers")
        #expect(safari?.totals.processCount == 3)
        #expect(ProcessTreeBuilder.node(for: 101, in: grouped)?.totals.processCount == 1, "a helper is found under its app")
        #expect(ProcessTreeBuilder.node(for: 999, in: grouped) == nil)

        let tree = ProcessTreeBuilder.build(sample, mode: .tree, appPIDs: [], currentUID: Self.me)
        #expect(ProcessTreeBuilder.node(for: 300, in: tree)?.children.map(\.id) == [301], "found two levels down")
        let filtered = ProcessTreeBuilder.build(sample, mode: .grouped, appPIDs: [100, 200], currentUID: Self.me, filter: "web content")
        #expect(ProcessTreeBuilder.node(for: 100, in: filtered)?.totals.memory == 400, "only the helpers the search kept")
    }

    @Test func gpuIsReportedOnceAnyProcessHasGPUTime() {
        var reporting = ProcessGPUReporting()
        #expect(reporting.isReported == nil)
        reporting.record(anyGPUTime: true)
        #expect(reporting.isReported == true)
        // Once seen, quiet samples don't take it back this session.
        for _ in 0..<10 { reporting.record(anyGPUTime: false) }
        #expect(reporting.isReported == true)
    }

    @Test func gpuIsUnreportedOnlyAfterSeveralSamplesWithNone() {
        var reporting = ProcessGPUReporting()
        for _ in 1..<ProcessGPUReporting.samplesToRuleOut { reporting.record(anyGPUTime: false) }
        #expect(reporting.isReported == nil, "too soon to tell")
        reporting.record(anyGPUTime: false)
        #expect(reporting.isReported == false)
        // A process that draws later still brings it back.
        reporting.record(anyGPUTime: true)
        #expect(reporting.isReported == true)
    }

    @Test func gpuVerdictFromAnEarlierLaunchHoldsUntilSamplesSayOtherwise() {
        var hidden = ProcessGPUReporting(isReported: false)
        #expect(hidden.isReported == false, "a VM without GPU time hides the column from the first frame")
        hidden.record(anyGPUTime: true)
        #expect(hidden.isReported == true)

        var shown = ProcessGPUReporting(isReported: true)
        shown.record(anyGPUTime: false)
        #expect(shown.isReported == true)
        for _ in 1..<ProcessGPUReporting.samplesToRuleOut { shown.record(anyGPUTime: false) }
        #expect(shown.isReported == false)
    }
}
