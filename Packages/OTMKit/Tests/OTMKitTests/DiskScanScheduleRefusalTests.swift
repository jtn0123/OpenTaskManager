import Foundation
@testable import OTMKit
import Testing

struct DiskScanScheduleRefusalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func overdueSchedulesExplainTheirDefaultAndEachRecordedRefusal() {
        var schedule = DiskScanSchedule(path: "/Library", cadence: .weekly, now: now)
        schedule.dueAt = now.addingTimeInterval(-86_400)
        #expect(schedule.overdueReason == "Waits until the Mac is idle for 2 minutes")
        #expect(schedule.lastCheckedText == "Last checked: not recorded")
        for reason in ["Waiting for two minutes without input", "Battery below 30% or unavailable", "Low Power Mode",
                       "Thermal pressure", DiskScanScheduleSafety.permissionNeeded, "Folder unavailable", "Not mounted"] {
            let refusal = DiskScanScheduleRefusal(reason: reason, checkedAt: now)
            schedule.lastRefusal = refusal
            #expect(schedule.overdueReason == reason)
            #expect(refusal.checkedText { _ in "Oct 5, 10:21 AM" } == "Last checked: Oct 5, 10:21 AM")
            #expect(schedule.status(at: now).hasPrefix("Due since"))
        }
    }

    @Test func refusalsRoundTripAndOlderPreferencesStillDecode() throws {
        var schedule = DiskScanSchedule(path: "/Library", cadence: .weekly, now: now)
        schedule.lastRefusal = DiskScanScheduleRefusal(reason: "Low Power Mode", checkedAt: now)
        let encoded = DiskScanSchedules([schedule]).rawValue
        #expect(DiskScanSchedules(rawValue: encoded)?.entries.first == schedule)
        let data = try JSONEncoder().encode([schedule])
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        legacy[0].removeValue(forKey: "lastRefusal")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let old = try #require(DiskScanSchedules(rawValue: String(decoding: oldData, as: UTF8.self))?.entries.first)
        #expect(old.lastRefusal == nil)
        #expect(old.overdueReason == "Waits until the Mac is idle for 2 minutes")
    }

    @Test func oldScopeFailuresKeepTheirReasonAndAttemptTime() {
        var schedule = DiskScanSchedule(path: "/Library", cadence: .daily, now: now)
        for reason in [DiskScanScheduleSafety.permissionNeeded, "Folder unavailable", "Not mounted"] {
            schedule.finish(at: now, result: reason)
            #expect(schedule.lastRefusal == nil)
            #expect(schedule.overdueReason == reason)
            #expect(schedule.lastCheckedText == DiskScanScheduleRefusal(reason: reason, checkedAt: now).checkedText())
        }
        schedule.finish(at: now, result: "Scanned 1 GB")
        #expect(schedule.overdueReason == "Waits until the Mac is idle for 2 minutes")
    }

    @Test func editingKeepsRefusalsButANewCompletedAttemptClearsThem() {
        var previous = DiskScanSchedule(path: "/Library", cadence: .weekly, now: now)
        previous.lastRefusal = DiskScanScheduleRefusal(reason: "Low Power Mode", checkedAt: now)
        var edited = DiskScanSchedule(path: "/Library", cadence: .daily, now: now).preservingHistory(from: previous)
        #expect(edited.lastRefusal == previous.lastRefusal)
        #expect(!edited.hasSameDeadline(as: previous))
        var checkedAgain = previous
        checkedAgain.lastRefusal = DiskScanScheduleRefusal(reason: "Thermal pressure", checkedAt: now.addingTimeInterval(900))
        #expect(checkedAgain.hasSameDeadline(as: previous))
        edited.finish(at: now, result: "Scanned 1 GB")
        #expect(edited.lastRefusal == nil)
    }
}
