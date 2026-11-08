import Foundation
import OTMKit

/// Reads only the app's persisted defaults domain, never the CLI's argument domain.
func diskScheduleCommand(_ options: Options) {
    let domain = "io.github.jtn0123.OpenTaskManager"
    let stored = UserDefaults.standard.persistentDomain(forName: domain)?[Settings.storageSchedules.key] as? String
    let schedules = stored.flatMap(DiskScanSchedules.init(rawValue:)) ?? DiskScanSchedules()
    if options.json {
        printJSON(schedules.entries)
        return
    }
    guard !schedules.entries.isEmpty else { print("No automatic Storage scans saved by the app."); return }
    for schedule in schedules.entries {
        print("\(schedule.path) · \(schedule.cadence.title) · \(schedule.status(at: Date()))")
        print("  Last result: \(schedule.lastResult ?? "Never run")")
    }
}
