import OTMKit
import SwiftUI

struct StorageScheduleSheet: View {
    let scope: StorageScope
    @Environment(\.dismiss) private var dismiss
    @State private var cadence = DiskScanCadence.weekly
    @State private var time = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var refusal: String?
    @State private var checking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan This Automatically").font(.title2.weight(.semibold))
            Text(scope.path).font(.tableText).textSelection(.enabled)
            Picker("Scan", selection: $cadence) {
                ForEach(DiskScanCadence.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            DatePicker("When the Mac is idle after", selection: $time, displayedComponents: .hourAndMinute)
            Text("Runs only while OpenTaskManager is running, after two minutes without input. "
                 + "A due scan waits for enough battery, Low Power Mode to be off and thermal pressure to settle. "
                 + "This is a preference, not an alarm.")
                .font(.explanation).foregroundStyle(.secondaryText)
            if let refusal {
                Text(refusal).font(.explanation).foregroundStyle(.secondaryText)
            }
            if StorageScheduler.shared.isFixture {
                Text("Screenshot fixture. These schedules are never saved or run.").font(.explanation).foregroundStyle(.secondaryText)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Schedule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || refusal != nil || StorageScheduler.shared.isFixture)
            }
        }
        .padding(24)
        .frame(width: 460)
        .task {
            if let saved = StorageScheduler.shared.schedules.entries.first(where: { $0.path == scope.path }) {
                cadence = saved.cadence
                time = Calendar.current.date(bySettingHour: saved.hour, minute: saved.minute, second: 0, of: time) ?? time
            }
            let path = scope.path
            let home = NSHomeDirectory()
            refusal = DiskScanScheduleSafety.refusal(path: path, home: home)
            if refusal == nil {
                let resolved = await Task.detached(priority: .utility) {
                    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                }.value
                refusal = DiskScanScheduleSafety.refusal(path: resolved, home: home)
            }
            if StorageScheduler.shared.schedules.entries.count >= DiskScanSchedules.limit,
               !StorageScheduler.shared.schedules.entries.contains(where: { $0.path == path }) {
                refusal = "Remove a schedule in Settings before adding another. Up to \(DiskScanSchedules.limit) scopes can be scheduled."
            }
            checking = false
        }
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        StorageScheduler.shared.save(DiskScanSchedule(path: scope.path, cadence: cadence,
                                                      hour: parts.hour ?? 2, minute: parts.minute ?? 0, now: Date()))
        dismiss()
    }
}

/// This observes the scheduler alone, so no status work lands on a sampler tick.
struct StorageScheduleStatus: View {
    private let scheduler = StorageScheduler.shared

    var body: some View {
        if !scheduler.schedules.entries.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(scheduler.schedules.entries) { schedule in
                        StorageScheduleRow(schedule: schedule, controls: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(scheduler.schedules.entries.count) * 94, 160))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
        }
    }
}

struct StorageScheduleSettings: View {
    private let scheduler = StorageScheduler.shared
    @Setting(Settings.storageScheduleNotifications) private var notify: Bool

    var body: some View {
        Section("Storage") {
            if scheduler.schedules.entries.isEmpty {
                Text("No automatic scans. Choose Scan This Automatically… in Storage to add one.")
                    .font(.explanation).foregroundStyle(.secondaryText)
            }
            if !scheduler.schedules.entries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(scheduler.schedules.entries) { schedule in
                            StorageScheduleRow(schedule: schedule, controls: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(scheduler.schedules.entries.count) * 120, 260))
            }
            Toggle("Notify when a scheduled scan finds big growth", isOn: $notify)
                .disabled(scheduler.isFixture)
                .onChange(of: notify) { _, enabled in
                    if enabled { scheduler.requestNotifications() }
                }
            Text("Big growth means more than both 5 GB and 10% since the previous saved scan.")
                .font(.explanation).foregroundStyle(.secondaryText)
        }
    }
}

private struct StorageScheduleRow: View {
    let schedule: DiskScanSchedule
    let controls: Bool
    private let scheduler = StorageScheduler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\((schedule.path as NSString).abbreviatingWithTildeInPath) · \(schedule.cadence.title)", systemImage: "clock")
                .font(.tableText).lineLimit(1).truncationMode(.middle).help(schedule.path)
            Text(schedule.status(at: Date())).font(.metadata).foregroundStyle(.secondaryText)
            if let reason = scheduler.waiting[schedule.path] ?? schedule.lastResult {
                Text(reason).font(.explanation).foregroundStyle(.secondaryText)
            }
            if !controls {
                Button("Show Saved Scans") {
                    Task {
                        let store = StorageStore.shared
                        await store.showSavedScans(of: StorageScope.resolve(schedule.path, volumes: store.volumes))
                    }
                }
                .disabled(scheduler.isFixture || StorageStore.shared.isScanning)
            }
            if controls {
                HStack {
                    Button("Run Now") { scheduler.runNow(schedule.path) }
                        .help("Queue this scan now. It still waits for two minutes without input and safe power and thermal conditions.")
                        .disabled(scheduler.isFixture || StorageStore.shared.isScanning || scheduler.checking)
                    Button("Remove") { scheduler.remove(schedule.path) }.disabled(scheduler.isFixture)
                }
            }
        }
    }
}
