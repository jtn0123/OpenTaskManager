import Foundation
@testable import OTMKit
import Testing

struct DiskScanScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var due: DiskScanSchedule {
        var schedule = DiskScanSchedule(path: "/Library", cadence: .daily, now: now, calendar: calendar)
        schedule.dueAt = now.addingTimeInterval(-86_400 * 8)
        return schedule
    }
    private var eligible: DiskScanEligibility {
        DiskScanEligibility(power: .ac, charge: nil, lowPowerMode: false, thermal: .nominal,
                            idleSeconds: 120, anotherScanRunning: false)
    }

    @Test func catchesUpAfterSleepWithoutMovingDueTime() {
        let schedule = due
        #expect(eligible.refusal(now: now, schedule: schedule) == nil)
        #expect(eligible.refusal(now: now.addingTimeInterval(86_400), schedule: schedule) == nil)
        #expect(schedule.dueAt == due.dueAt)
        #expect(schedule.status(at: now).hasPrefix("Due since"))
    }

    @Test func refusesEveryUnsafeCondition() {
        var conditions = eligible
        conditions.anotherScanRunning = true
        #expect(conditions.refusal(now: now, schedule: due) == "Another scan is running")
        conditions = eligible
        conditions.lowPowerMode = true
        #expect(conditions.refusal(now: now, schedule: due) == "Low Power Mode")
        for thermal in [ThermalState.serious, .critical] {
            conditions = eligible
            conditions.thermal = thermal
            #expect(conditions.refusal(now: now, schedule: due) == "Thermal pressure")
        }
        conditions = eligible
        conditions.power = nil
        #expect(conditions.refusal(now: now, schedule: due) == "Power source unavailable")
        for charge in [nil, Double(0.29), .nan] {
            conditions = eligible
            conditions.power = .battery
            conditions.charge = charge
            #expect(conditions.refusal(now: now, schedule: due) == "Battery below 30% or unavailable")
        }
        for idle in [119.9, -1, Double.nan] {
            conditions = eligible
            conditions.idleSeconds = idle
            #expect(conditions.refusal(now: now, schedule: due) == "Waiting for two minutes without input")
        }
    }

    @Test func boundariesAndRunNowStillRespectSafety() {
        var conditions = eligible
        conditions.power = .battery
        conditions.charge = 0.3
        conditions.thermal = .fair
        #expect(conditions.refusal(now: now, schedule: due) == nil)
        let future = DiskScanSchedule(path: "/Library", cadence: .weekly, now: now, calendar: calendar)
        #expect(conditions.refusal(now: now, schedule: future) == "Not due yet")
        #expect(conditions.refusal(now: now, schedule: future, runNow: true) == nil)
        conditions.idleSeconds = 0
        #expect(conditions.refusal(now: now, schedule: future, runNow: true) != nil)
    }

    @Test func oneDeadlineAndNoTimerWithoutSchedules() {
        let future = DiskScanSchedule(path: "/usr", cadence: .weekly, now: now, calendar: calendar)
        #expect(DiskScanEligibility.nextCheck([], now: now) == nil)
        #expect(DiskScanEligibility.nextCheck([future], now: now) == future.dueAt)
        #expect(DiskScanEligibility.nextCheck([future, due], now: now) == now.addingTimeInterval(900))
        #expect(DiskScanEligibility.nextCheck([future], now: now, pendingRunNow: true) == now.addingTimeInterval(900))
    }

    @Test func failedAttemptWaitsForNextCadence() {
        for cadence in DiskScanCadence.allCases {
            var schedule = due
            schedule.cadence = cadence
            schedule.finish(at: now, result: "Not mounted", calendar: calendar)
            #expect(schedule.lastRun == now)
            #expect(schedule.lastResult == "Not mounted")
            #expect(schedule.dueAt > now)
            #expect(calendar.component(.hour, from: schedule.dueAt) == 2)
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: schedule.dueAt)).day
            #expect(days == cadence.days)
            #expect(eligible.refusal(now: now, schedule: schedule) == "Not due yet")
        }
    }

    @Test func editingPreservesLastAttemptAndUnchangedDueTime() {
        var old = due
        old.lastRun = now.addingTimeInterval(-86_400 * 10)
        old.lastResult = "Not mounted"
        let replacement = DiskScanSchedule(path: old.path, cadence: old.cadence, now: now, calendar: calendar)
        let unchanged = replacement.preservingHistory(from: old, calendar: calendar)
        #expect(unchanged == old)
        var changed = replacement
        changed.cadence = .weekly
        let updated = changed.preservingHistory(from: old, calendar: calendar)
        #expect(updated.lastRun == old.lastRun)
        #expect(updated.lastResult == old.lastResult)
        #expect(updated.cadence == .weekly)
        #expect(updated.dueAt < now)
    }

    @Test func daylightSavingGapStillUsesTheNextLocalDay() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let before = try #require(local.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 3)))
        var schedule = DiskScanSchedule(path: "/Library", cadence: .daily, now: before, calendar: local)
        schedule.finish(at: before, result: "Scanned", calendar: local)
        #expect(local.component(.day, from: schedule.dueAt) == 8)
        #expect(schedule.dueAt > before)
    }

    @Test func privacyScopesAndTheirParentsAreRefused() {
        let home = "/Users/test"
        for path in ["/", "/Users", home, home + "/Desktop", home + "/Documents/project", home + "/Downloads",
                     home + "/Library", home + "/Library/Containers", home + "/Library/Group Containers/other",
                     "/Users/other/Documents", "/System/Volumes/Data", "/System/Volumes/Data/Users/test"] {
            #expect(DiskScanScheduleSafety.refusal(path: path, home: home) != nil)
        }
        for path in ["/Library", "/usr", home + "/Projects", home + "/Library/Caches", home + "/Documents-backup"] {
            #expect(DiskScanScheduleSafety.refusal(path: path, home: home) == nil)
        }
    }

    @Test func growthMustExceedBothThresholdsAndHaveReadableMatchingScopes() {
        func summary(_ size: UInt64, unreadable: Int = 0, path: String = "/Library") -> DiskScanSummary {
            DiskScanSummary(scope: DiskScanScope(rootPath: path), scannedAt: now, unreadableFolders: unreadable,
                            folders: [.init(name: "", parent: -1, allocatedSize: size, logicalSize: size, itemCount: 1)])
        }
        #expect(!DiskScanScheduleSafety.bigGrowth(before: summary(10_000_000_000), after: summary(15_000_000_000)))
        #expect(DiskScanScheduleSafety.bigGrowth(before: summary(10_000_000_000), after: summary(15_000_000_001)))
        #expect(!DiskScanScheduleSafety.bigGrowth(before: summary(100_000_000_000), after: summary(110_000_000_000)))
        #expect(!DiskScanScheduleSafety.bigGrowth(before: summary(10), after: summary(10_000_000_000, unreadable: 1)))
        #expect(!DiskScanScheduleSafety.bigGrowth(before: summary(10), after: summary(10_000_000_000, path: "/usr")))
        #expect(!DiskScanScheduleSafety.bigGrowth(before: summary(100), after: summary(90)))
        // Most system folders hold a few private ones; the same count either side still compares.
        #expect(DiskScanScheduleSafety.bigGrowth(before: summary(10_000_000_000, unreadable: 3),
                                                 after: summary(15_000_000_001, unreadable: 3)))
        #expect(DiskScanScheduleSafety.scannedText(summary(10_000_000_000)) == "Scanned \(Format.bytes(10_000_000_000 as UInt64))")
        #expect(DiskScanScheduleSafety.scannedText(summary(10_000_000_000, unreadable: 1)).hasSuffix(" · 1 folder unreadable"))
        #expect(DiskScanScheduleSafety.scannedText(summary(10_000_000_000, unreadable: 3)).hasSuffix(" · 3 folders unreadable"))
    }

    @Test func scheduledProvenanceIsOptionalAndVersioned() throws {
        let manual = DiskScanSummary(scope: DiskScanScope(rootPath: "/Library"), scannedAt: now,
                                     folders: [.init(name: "", parent: -1, allocatedSize: 10, logicalSize: 10, itemCount: 1)])
        let data = try DiskScanHistory.encode(manual)
        #expect(!String(decoding: data, as: UTF8.self).contains("scheduled"))
        #expect(try DiskScanHistory.decode(data).scheduled == nil)
        let automatic = DiskScanSummary(scope: manual.scope, scannedAt: now, folders: manual.folders,
                                        scheduled: DiskScanScheduledOrigin(cadence: .weekly))
        let restored = try DiskScanHistory.decode(DiskScanHistory.encode(automatic))
        #expect(restored.scheduled?.version == 1)
        #expect(restored.scheduled?.cadence == .weekly)
    }
}

struct DiskScanSavedUsageTests {
    @Test func reopensBoundedTreeWithRemaindersAndNoCleanupIdentities() {
        let summary = DiskScanSummary(scope: DiskScanScope(rootPath: "/Library"), scannedAt: Date(), folders: [
            .init(name: "", parent: -1, allocatedSize: 100, logicalSize: 100, itemCount: 10),
            .init(name: "small", parent: 0, allocatedSize: 20, logicalSize: 20, itemCount: 2),
            .init(name: "large", parent: 0, allocatedSize: 50, logicalSize: 50, itemCount: 5),
            .init(name: "inside", parent: 2, allocatedSize: 40, logicalSize: 40, itemCount: 3),
        ])
        let usage = summary.boundedUsage()
        #expect(usage.finishedAt == summary.scannedAt)
        #expect(usage.root.allocatedSize == 100)
        #expect(usage.items.allSatisfy { $0.identity == nil })
        #expect(usage.children(of: usage.root).map(\.allocatedSize) == [50, 20, 30])
        #expect(usage.item(atPath: "/Library/large/inside")?.allocatedSize == 40)
        for item in usage.items where item.kind == .folder {
            #expect(usage.children(of: item).reduce(UInt64(0)) { $0 + $1.allocatedSize } == item.allocatedSize)
        }
    }
}
