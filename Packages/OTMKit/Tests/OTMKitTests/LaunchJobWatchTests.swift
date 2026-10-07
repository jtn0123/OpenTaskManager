import Foundation
@testable import OTMKit
import Testing

/// A loaded job from a minimal property list, with launchd's view of it.
private func job(_ label: String = "com.example.agent", scope: LaunchItemScope = .userAgent, keepAlive: Bool = false,
                 pid: Int32?, lastExit: LaunchExitStatus? = nil, loaded: Bool = true) -> LaunchItem {
    let keys = "<key>Label</key><string>\(label)</string>" + (keepAlive ? "<key>KeepAlive</key><true/>" : "")
    let data = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>\(keys)</dict></plist>
    """.utf8)
    var item = LaunchItems.item(plist: data, path: "/Library/LaunchAgents/\(label).plist", scope: scope)
    if loaded { item.job = LaunchJobStatus(label: label, pid: pid, lastExit: lastExit) }
    return item
}

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func at(_ seconds: TimeInterval) -> Date {
    start.addingTimeInterval(seconds)
}

/// "+90" for a date 90 seconds after `start`, so summaries read the same in any time zone.
private func offset(_ date: Date) -> String {
    "+\(Int(date.timeIntervalSince(start)))"
}

struct LaunchExitClassificationTests {
    @Test func crashesAreSignalsThatMeanTheProgramBroke() {
        #expect(LaunchExitStatus.code(-11).crashSignal == 11)
        #expect(LaunchExitStatus.code(-6).crashSignal == 6)
        // launchd ends idle jobs with SIGKILL and stops them with SIGTERM.
        #expect(LaunchExitStatus.code(-9).crashSignal == nil)
        #expect(LaunchExitStatus.code(-15).crashSignal == nil)
        #expect(!LaunchExitStatus.code(-9).isFailure)
    }

    @Test func failuresAreNonZeroCodes() {
        #expect(LaunchExitStatus.code(78).failureCode == 78)
        #expect(LaunchExitStatus.code(78).isFailure)
        #expect(LaunchExitStatus.code(0).failureCode == nil)
        #expect(!LaunchExitStatus.code(0).isFailure)
        // An idle exit or a memory-limit kill is the system's doing, not the job failing.
        #expect(!LaunchExitStatus.reason("pe").isFailure)
        #expect(!LaunchExitStatus.reason("jt").isFailure)
    }

    @Test func namesConventionalCodes() {
        #expect(LaunchExitStatus.meaning(ofCode: 78)?.hasPrefix("EX_CONFIG") == true)
        #expect(LaunchExitStatus.meaning(ofCode: 127) == "its program wasn't found")
        #expect(LaunchExitStatus.meaning(ofCode: 1) == nil)
    }
}

struct LaunchJobWatchTests {
    @Test func theFirstProcessSeenIsTheBaseline() throws {
        var watch = LaunchJobWatch()
        let item = job(pid: 500)
        watch.observe([item], startTimes: [500: at(-60)], at: at(0))
        let record = try #require(watch.record(for: item))
        #expect(record.restartCount == 0)
        #expect(record.firstSeen == at(0))
        #expect(watch.since == at(0))
        #expect(watch.health(of: item) == .healthy)
    }

    @Test func aNewPIDIsARestartDatedByItsStart() {
        var watch = LaunchJobWatch()
        watch.observe([job(pid: 500)], startTimes: [500: at(-60)], at: at(0))
        watch.observe([job(pid: 500)], startTimes: [500: at(-60)], at: at(10))
        let item = job(pid: 612, lastExit: .code(0))
        watch.observe([item], startTimes: [612: at(14)], at: at(20))
        let record = watch.record(for: item)
        #expect(record?.restartCount == 1)
        #expect(record?.lastRestart == LaunchJobRestart(date: at(14), previousExit: .code(0), isTroubled: false))
    }

    @Test func aReusedPIDWithAnotherStartIsARestartToo() {
        var watch = LaunchJobWatch()
        watch.observe([job(pid: 500)], startTimes: [500: at(-60)], at: at(0))
        watch.observe([job(pid: 500)], startTimes: [500: at(5)], at: at(10))
        #expect(watch.record(for: job(pid: 500))?.restartCount == 1)
    }

    @Test func aStartTimeLearnedLateIsTheSameProcess() {
        var watch = LaunchJobWatch()
        // The process list didn't have the new process yet at the first read.
        watch.observe([job(pid: 500)], startTimes: [:], at: at(0))
        watch.observe([job(pid: 500)], startTimes: [500: at(-1)], at: at(10))
        watch.observe([job(pid: 500)], startTimes: [500: at(-1)], at: at(20))
        let record = watch.record(for: job(pid: 500))
        #expect(record?.restartCount == 0)
        #expect(record?.instance == LaunchJobInstance(pid: 500, started: at(-1)))
    }

    @Test func aRunAfterWaitingBetweenRunsCounts() {
        var watch = LaunchJobWatch()
        watch.observe([job(pid: 500)], startTimes: [:], at: at(0))
        watch.observe([job(pid: nil, lastExit: .code(0))], startTimes: [:], at: at(10))
        watch.observe([job(pid: 700, lastExit: .code(0))], startTimes: [:], at: at(20))
        let record = watch.record(for: job(pid: 700))
        #expect(record?.restartCount == 1)
        // Its start isn't known, so the read that saw it dates it.
        #expect(record?.lastRestart?.date == at(20))
    }

    @Test func unloadingStartsAfresh() {
        var watch = LaunchJobWatch()
        watch.observe([job(pid: 500)], startTimes: [:], at: at(0))
        watch.observe([job(pid: nil, loaded: false)], startTimes: [:], at: at(10))
        watch.observe([job(pid: 800)], startTimes: [:], at: at(20))
        #expect(watch.record(for: job(pid: 800))?.restartCount == 0)
    }

    @Test func eachScopeIsItsOwnJob() {
        var watch = LaunchJobWatch()
        watch.observe([job(scope: .userAgent, pid: 500), job(scope: .daemon, pid: 900)], startTimes: [:], at: at(0))
        watch.observe([job(scope: .userAgent, pid: 501), job(scope: .daemon, pid: 900)], startTimes: [:], at: at(10))
        #expect(watch.record(for: job(scope: .userAgent, pid: 501))?.restartCount == 1)
        #expect(watch.record(for: job(scope: .daemon, pid: 900))?.restartCount == 0)
    }

    @Test func onDemandRestartsAfterCleanExitsAreNotTrouble() {
        var watch = LaunchJobWatch()
        for (index, pid) in [500, 501, 502, 503, 504].enumerated() {
            watch.observe([job(pid: Int32(pid), lastExit: .code(-9))], startTimes: [:], at: at(Double(index) * 10))
        }
        let item = job(pid: 504, lastExit: .code(-9))
        #expect(watch.record(for: item)?.restartCount == 4)
        #expect(watch.health(of: item) == .healthy)
    }

    @Test func repeatedRestartsAfterCrashesAreRestarting() {
        var watch = LaunchJobWatch()
        for (index, pid) in [500, 501, 502, 503].enumerated() {
            watch.observe([job(pid: Int32(pid), lastExit: .code(-11))], startTimes: [:], at: at(Double(index) * 10))
        }
        let item = job(pid: 503, lastExit: .code(-11))
        #expect(watch.health(of: item) == .restarting(count: 3))
        let text = watch.health(of: item).explanation(for: item, record: watch.record(for: item), time: offset)
        #expect(text == "Restarted 3 times since +0, the last at +30, after its run before ended: killed by signal 11 (SIGSEGV).")
        #expect(watch.health(of: item).stateTitle(isRunning: true) == "Restarting")
    }

    @Test func aKeepAliveJobThatKeepsEndingIsRestarting() {
        var watch = LaunchJobWatch()
        for (index, pid) in [500, 501, 502, 503].enumerated() {
            watch.observe([job(keepAlive: true, pid: Int32(pid), lastExit: .code(0))], startTimes: [:], at: at(Double(index) * 10))
        }
        let item = job(keepAlive: true, pid: 503, lastExit: .code(0))
        #expect(watch.health(of: item) == .restarting(count: 3))
        let text = watch.health(of: item).explanation(for: item, record: watch.record(for: item), time: offset)
        #expect(text == "Restarted 3 times since +0, the last at +30. launchd keeps it alive, so it starts again whenever it ends.")
    }

    @Test func restartsOutsideTheWindowStopCounting() {
        var watch = LaunchJobWatch()
        for (index, pid) in [500, 501, 502, 503].enumerated() {
            watch.observe([job(pid: Int32(pid), lastExit: .code(1))], startTimes: [:], at: at(Double(index) * 10))
        }
        // Calm for longer than the window: still failed last time, no longer restarting.
        let item = job(pid: 503, lastExit: .code(1))
        watch.observe([item], startTimes: [:], at: at(30 + LaunchJobWatch.flappingWindow + 1))
        #expect(watch.health(of: item) == .failed(code: 1))
        #expect(watch.record(for: item)?.restartCount == 3)
    }

    @Test func keepsOnlyTheLatestRestarts() {
        var watch = LaunchJobWatch()
        for pid in 0..<40 {
            watch.observe([job(pid: Int32(1000 + pid))], startTimes: [:], at: at(Double(pid)))
        }
        let record = watch.record(for: job(pid: 1039))
        #expect(record?.restartCount == 39)
        #expect(record?.recentRestarts.count == LaunchJobWatch.keptRestarts)
        #expect(record?.lastRestart?.date == at(39))
    }

    @Test func lastExitsSayWhetherAJobFailed() {
        let watch = LaunchJobWatch()
        #expect(watch.health(of: job(pid: nil, lastExit: .code(78))) == .failed(code: 78))
        #expect(watch.health(of: job(pid: 42, lastExit: .code(-6))) == .crashed(signal: 6))
        #expect(watch.health(of: job(pid: nil, lastExit: .reason("pe"))) == .healthy)
        #expect(watch.health(of: job(pid: nil, lastExit: nil)) == .healthy)
        // Not loaded: launchd says nothing about it.
        #expect(watch.health(of: job(pid: nil, lastExit: .code(1), loaded: false)) == .healthy)
    }

    @Test func explainsFailuresAndCrashes() {
        let failed = job(pid: nil, lastExit: .code(78))
        #expect(LaunchJobHealth.failed(code: 78).stateTitle(isRunning: false) == "Failed")
        #expect(LaunchJobHealth.failed(code: 78).explanation(for: failed, record: nil, time: offset)
            == "Exited with code 78 (EX_CONFIG: a setup problem, such as a program or file it can't find "
            + "or isn't allowed to open).")
        #expect(LaunchJobHealth.failed(code: 3).explanation(for: failed, record: nil, time: offset) == "Exited with code 3.")
        let crashed = job(pid: 42, lastExit: .code(-11))
        // Running again, it keeps saying Running.
        #expect(LaunchJobHealth.crashed(signal: 11).stateTitle(isRunning: true) == nil)
        #expect(LaunchJobHealth.crashed(signal: 11).explanation(for: crashed, record: nil, time: offset)
            == "Killed by signal 11 (SIGSEGV): the program crashed. It's running again now.")
        #expect(LaunchJobHealth.healthy.headline == nil)
        #expect(!LaunchJobHealth.healthy.needsAttention)
    }

    @Test func summarisesRestarts() {
        var record = LaunchJobRecord(firstSeen: at(0))
        #expect(record.restartSummary(time: offset) == "None seen since +0")
        var watch = LaunchJobWatch()
        watch.observe([job(pid: 1)], startTimes: [:], at: at(0))
        watch.observe([job(pid: 2)], startTimes: [:], at: at(10))
        record = watch.record(for: job(pid: 2)) ?? record
        #expect(record.restartSummary(time: offset) == "Once since +0, at +10")
        watch.observe([job(pid: 3)], startTimes: [:], at: at(20))
        record = watch.record(for: job(pid: 3)) ?? record
        #expect(record.restartSummary(time: offset) == "2 times since +0, the last at +20")
    }
}
