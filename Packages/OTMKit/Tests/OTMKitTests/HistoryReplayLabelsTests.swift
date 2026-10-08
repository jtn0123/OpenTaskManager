import Foundation
@testable import OTMKit
import Testing

struct HistoryReplayLabelsTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func eventTitlesKeepCompleteShortWords() {
        let time = date(1_000)
        for kind in SpikeKind.allCases {
            let event = HistoryEvent(time: time, kind: .spike, name: kind.shortLabel)
            #expect(HistoryReplayLabels.eventTitle(event) == "\(kind.shortLabel) spike captured")
        }
        #expect(HistoryReplayLabels.eventTitle(HistoryEvent(time: time, kind: .processStarted, name: "clang", count: 5))
            == "5 × clang started")
        #expect(HistoryReplayLabels.eventTitle(HistoryEvent(time: time, kind: .networkChanged, name: ""))
            == "Network disconnected")
        #expect(HistoryReplayLabels.eventTitle(HistoryEvent(time: time, kind: .appLaunched, name: "Editor")) == "Editor launched")
        #expect(HistoryReplayLabels.eventTitle(HistoryEvent(time: time, kind: .appQuit, name: "Editor")) == "Editor quit")
        #expect(HistoryReplayLabels.eventTitle(HistoryEvent(time: time, kind: .processExited, name: "clang")) == "clang exited")
        #expect(HistoryReplayLabels.eventTitle(HistoryEvent(time: time, kind: .sleep, name: "")) == "Mac went to sleep")
        #expect(HistoryReplayLabels.eventTitle(HistoryEvent(time: time, kind: .wake, name: "")) == "Mac woke")
    }

    @Test func eventOffsetsNameBeforeDuringAndAfterWithoutAbbreviatingWords() {
        func offset(_ seconds: Double, bucket: Double = 1, approximate: Bool = false) -> String {
            let event = HistoryEvent(time: date(seconds), kind: .spike, name: "CPU", isApproximate: approximate)
            return HistoryReplayLabels.eventOffset(event, at: date(1_000), bucket: bucket)
        }
        #expect(offset(989) == "11 s before")
        #expect(offset(999) == "1 s before", "the start boundary belongs to the preceding bucket")
        #expect(offset(999.5) == "during these 1 s")
        #expect(offset(1_000) == "during these 1 s")
        #expect(offset(1_002) == "2 s after")
        #expect(offset(989, approximate: true) == "about 11 s before")
        #expect(offset(995, bucket: 10, approximate: true) == "about during these 10 s")
    }

    @Test func recordingDetailsPreserveCadenceAndMissingReports() {
        #expect(HistoryReplayLabels.processNotice == "This recording doesn't keep process histories")
        #expect(HistoryReplayLabels.searchLive == "Search Live History")
        #expect(HistoryReplayLabels.readOnly == "Read-only")
        #expect(HistoryReplayLabels.recordCount(180, seconds: 1) == "180 records of 1 s")
        #expect(HistoryReplayLabels.recordCount(91, seconds: 10) == "91 records")
        #expect(HistoryReplayLabels.recordCount(1, seconds: 10) == "1 record")
        #expect(HistoryReplayLabels.machine("Test Mac", notReported: []) == "Recorded on Test Mac")
        #expect(HistoryReplayLabels.machine("Test Mac", notReported: ["GPU"]) == "Recorded on Test Mac · GPU not reported")
        let missing = HistoryReplayLabels.machine("Test Mac", notReported: ["GPU", "power", "chip temperature"])
        for label in ["GPU", "power", "chip temperature", "not reported"] { #expect(missing.contains(label)) }
        let trigger = SpikeTrigger(kind: .cpu, time: date(1_000), since: date(990), figure: 0.98, threshold: 0.8)
        #expect(HistoryReplayLabels.triggerTime(trigger) == "CPU crossed at \(trigger.time.formatted(date: .omitted, time: .standard))")
    }

    @Test func recordedScopeShowsModestGapsAndUnevenSharesInEitherOrder() {
        #expect(HistoryCompareLabels.recordedScope(a: 0.62, b: 0.52)
            == "Recorded: A 62%, B 52% — changes describe recorded time only.")
        #expect(HistoryCompareLabels.recordedScope(a: 1, b: 0.89) != nil)
        #expect(HistoryCompareLabels.recordedScope(a: 0.89, b: 1) != nil)
        #expect(HistoryCompareLabels.recordedScope(a: 0.9, b: 1) == nil)
        #expect(HistoryCompareLabels.recordedScope(a: 1, b: 1) == nil)
        #expect(HistoryCompareLabels.recordedScope(a: 0.96, b: 0.96) == nil)
        #expect(HistoryCompareLabels.recordedScope(a: 0.89, b: 0.89) != nil)
        #expect(HistoryCompareLabels.recordedScope(a: .nan, b: 2)
            == "Recorded: A 0%, B 100% — changes describe recorded time only.")
    }

    private func lifetime(ended: Double? = nil) -> ProcessLifetime {
        ProcessLifetime(id: 1, identity: ProcessIdentity(pid: 7, startTime: date(900)), name: "quiet",
                        firstSeen: date(1_001), lastSeen: date(1_100), ended: ended.map(date))
    }

    private func point(_ time: Double, stored: Int = 0, segment: Int = 0) -> ProcessHistoryPoint {
        ProcessHistoryPoint(time: date(time), records: 1, stored: stored, cpu: stored > 0 ? 0 : nil,
                            cpuPeak: stored > 0 ? 0 : nil, memory: stored > 0 ? 1_024 : nil,
                            diskRead: nil, diskWrite: nil, segment: segment)
    }

    @Test func idleOnlyMomentsStillLeaveRealGapsUnrecorded() {
        let lifetime = lifetime()
        let points = [point(1_010), point(1_020), point(1_090, segment: 1)]
        func moment(_ time: Double) -> ProcessHistoryLabels.Moment {
            ProcessHistoryLabels.moment(of: lifetime, at: date(time), points: points, bucket: 10)
        }
        #expect(moment(1_010) == .idle)
        #expect(moment(1_016) == .idle)
        #expect(moment(1_070) == .notRecorded, "an idle-only lifetime does not make gaps idle")
        #expect(moment(950) == .notRecorded, "before its first watched record, it was not recorded")
        #expect(moment(880) == .notRunning)
        #expect(moment(1_200) == .notRecorded, "after the last sighting it may still have run")
        #expect(ProcessHistoryLabels.moment(of: lifetime, at: date(1_200), points: points, bucket: 10, isGone: true)
            == .notSeenAfter(date(1_100)), "gone now, but its end went unwatched")
        #expect(ProcessHistoryLabels.moment(of: lifetime, at: date(1_105), points: points, bucket: 10, isGone: true)
            == .notRecorded, "within a record of its last sighting it may still have run")
        #expect(ProcessHistoryLabels.moment(of: self.lifetime(ended: 1_100), at: date(1_200), points: points, bucket: 10,
                                            isGone: true) == .notRunning, "a seen end stays not running")
        #expect(ProcessHistoryLabels.moment(of: lifetime, at: date(1_010), points: [], bucket: 10) == .notRecorded)
        #expect(ProcessHistoryLabels.idleMoment == "Idle (not kept)")
        #expect(ProcessHistoryLabels.notRecorded == "Not recorded")
    }

    @Test func liveEdgeNamesTheLatestKeptMemoryWithItsOriginalTime() {
        let step = ProcessMemoryStep(time: date(1_090), footprint: 49 * 1_024 * 1_024, measure: .footprint)
        let coverage = [date(1_080)...date(1_100)]
        func moment(_ time: Double, ended: Double? = nil, gone: Bool = false) -> ProcessHistoryLabels.Moment {
            ProcessHistoryLabels.moment(of: lifetime(ended: ended), at: date(time), points: [], bucket: 60,
                                        memory: [step], coverage: coverage, isGone: gone, recordSpan: 10)
        }
        #expect(moment(1_101) == .latestMemory(step))
        #expect(moment(1_110) == .latestMemory(step))
        #expect(moment(1_110.001) == .notRecorded, "the chart bucket does not lengthen the record span")
        #expect(moment(1_105, ended: 1_100) == .notRecorded)
        #expect(moment(1_105, gone: true) == .notRecorded)
        #expect(moment(1_070) == .notRecorded, "the live edge cannot fill an earlier gap")
        let label = ProcessHistoryLabels.latestMemoryMoment(step)
        #expect(label == "Footprint about 49 MB at \(step.time.formatted(date: .omitted, time: .standard)), the latest record")
        #expect(!label.contains(date(1_105).formatted(date: .omitted, time: .standard)))
        let resident = ProcessMemoryStep(time: step.time, footprint: step.footprint, measure: .resident)
        #expect(ProcessHistoryLabels.latestMemoryMoment(resident).hasPrefix("Resident about 49 MB at "))
    }

    @Test func keptZeroAndPartialIdleAreFiguresAndAnEndedLifetimeIsNotRunning() {
        let zero = point(1_010, stored: 1)
        #expect(ProcessHistoryLabels.moment(of: lifetime(), at: zero.time, points: [zero], bucket: 10) == .figures(zero))
        let mixed = ProcessHistoryPoint(time: date(1_030), records: 2, stored: 1, cpu: 15, cpuPeak: 30,
                                        memory: 1_024, diskRead: nil, diskWrite: nil)
        #expect(ProcessHistoryLabels.moment(of: lifetime(), at: mixed.time, points: [mixed], bucket: 20) == .figures(mixed))
        #expect(ProcessHistoryLabels.moment(of: lifetime(ended: 1_040), at: date(1_060), points: [zero], bucket: 10) == .notRunning)
    }

    @Test func idleSummaryIsDistinctFromNoRecordsAndLifetimeUsesItsRealStart() {
        #expect(!ProcessHistorySummary.empty.isIdle)
        let idle = ProcessHistorySummary(records: 2, stored: 0, recordedSeconds: 20, averageCPU: nil, peakCPU: nil,
                                         peakMemory: nil, averageDiskRead: nil, averageDiskWrite: nil)
        #expect(idle.isIdle)
        #expect(ProcessHistoryLabels.idleSummary == "Idle throughout: no busy figures kept")
        let lifetime = lifetime()
        let style: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute().second()
        let running = ProcessHistoryLabels.lifetime(lifetime, isRunning: true)
        #expect(running.hasPrefix("Started \(date(900).formatted(style))"))
        #expect(running.contains("Still running"))
        #expect(running.hasSuffix("\(Format.roughDuration(200)) at last sighting"))
        #expect(ProcessHistoryLabels.lifetime(lifetime, isRunning: false).contains("Last seen"))
        let ended = ProcessHistoryLabels.lifetime(self.lifetime(ended: 1_040), isRunning: false)
        #expect(ended.contains("Ended \(date(1_040).formatted(style))"))
        #expect(ended.hasSuffix(Format.roughDuration(140)))
    }
}
