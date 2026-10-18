@testable import OTMKit
import Testing

struct SystemPressureReportTests {
    @Test func quietAndBusyReadingsStayDistinct() {
        let quiet = SystemPressureReport(.init(interval: 1, cpu: 0.1))
        #expect(!quiet.isMeasuring && quiet.findings.isEmpty)
        let busy = SystemPressureReport(.init(interval: 1, cpu: 0.85, memory: .critical, thermal: .serious, gpu: 0.9))
        #expect(busy.findings.map(\.resource) == [.thermal, .memory, .cpu, .gpu])
        #expect(busy.findings[0].state == "serious")
        #expect(busy.findings[1].state == "critical")
        #expect(busy.findings[2].fraction == 0.85)
    }

    @Test func oneBusyCoreDoesNotBecomeAWholeCPUBottleneck() {
        let report = SystemPressureReport(.init(interval: 1, cpu: 0.1, busiestCore: 0.97))
        #expect(report.findings.map(\.resource) == [.busyCore])
        let allBusy = SystemPressureReport(.init(interval: 1, cpu: 0.9, busiestCore: 1))
        #expect(allBusy.findings.map(\.resource) == [.cpu])
    }

    @Test func firstSampleAndGapsKeepStatesButDoNotInterpretRates() {
        for interval in [0.0, -1, 20, .infinity, .nan] {
            let report = SystemPressureReport(.init(interval: interval, cpu: 1, memory: .warning, thermal: .critical, gpu: 1))
            #expect(report.isMeasuring)
            #expect(report.findings.map(\.resource) == [.thermal, .memory])
        }
    }

    @Test func missingInvalidAndNearThresholdFiguresDoNotRaiseFindings() {
        for value in [-1.0, Double.nan, .infinity, 1.1, 0.849] {
            let report = SystemPressureReport(.init(interval: 1, cpu: value, busiestCore: value, gpu: value))
            #expect(report.findings.isEmpty)
        }
        #expect(SystemPressureReport(.init(interval: 1, cpu: 0.5, gpu: 0.899)).findings.isEmpty)
        #expect(SystemPressureReport(.init(interval: 1, cpu: 0.5, thermal: .fair)).findings.isEmpty)
    }

    @Test func readingsRecoverWithoutLatchingOldWarnings() {
        #expect(!SystemPressureReport(.init(interval: 1, cpu: 1, memory: .warning)).findings.isEmpty)
        #expect(SystemPressureReport(.init(interval: 1, cpu: 0.2)).findings.isEmpty)
    }

    @Test func rankingsUseTheRelevantResourceAndStableTies() {
        var a = process(10), b = process(20), third = process(30)
        a.cpuPercent = 50
        b.cpuPercent = 90
        third.cpuPercent = .nan
        a.memory = 200
        b.memory = 100
        third.memory = 300
        a.gpuFraction = nil
        b.gpuFraction = 0.4
        third.gpuFraction = 0.4
        let list = [third, b, a]
        #expect(SystemPressureReport.topProcesses(for: .cpu, in: list).map(\.pid) == [20, 10])
        #expect(SystemPressureReport.topProcesses(for: .thermal, in: list).map(\.pid) == [20, 10])
        #expect(SystemPressureReport.topProcesses(for: .memory, in: list, limit: 2).map(\.pid) == [30, 10])
        #expect(SystemPressureReport.topProcesses(for: .gpu, in: list).map(\.pid) == [20, 30])
        #expect(SystemPressureReport.topProcesses(for: .cpu, in: list, limit: 0).isEmpty)
        #expect(SystemPressureReport.topProcesses(for: .gpu, in: [a]).isEmpty)
    }

    private func process(_ pid: Int32) -> ProcessSample {
        ProcessSample(pid: pid, parentPID: 1, responsiblePID: pid, uid: 501, userName: "test", name: "Process \(pid)",
                      executablePath: nil, state: .running, nice: 0, startTime: nil, isTranslated: false, isRestricted: false,
                      cpuPercent: 0, cpuTime: 0, memory: 0, residentMemory: 0, threadCount: 1,
                      diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0, diskWriteTotal: 0)
    }
}
