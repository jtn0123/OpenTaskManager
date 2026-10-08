import AppKit
import CoreGraphics
import IOKit.ps
import Observation
import OTMKit
import UserNotifications

/// One deadline for all scopes, independent of the sampler and the Storage page.
@Observable
@MainActor
final class StorageScheduler {
    static let shared = StorageScheduler()

    private(set) var schedules = DiskScanSchedules()
    private(set) var waiting: [String: String] = [:]
    private(set) var isFixture = false
    private(set) var checking = false
    var editing: StorageScope?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var runNowPaths: Set<String> = []
    @ObservationIgnored private var active: DiskScanSchedule?
    @ObservationIgnored private var prepared: DiskScanSchedule?
    @ObservationIgnored private var conditionObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        isFixture = LaunchArgument.string("scheduleFixture") == "YES"
        #endif
        if isFixture {
            let now = Date()
            var due = DiskScanSchedule(path: "/Library", cadence: .weekly, now: now)
            due.dueAt = now.addingTimeInterval(-3 * 86_400)
            var denied = DiskScanSchedule(path: "/usr", cadence: .daily, now: now)
            denied.finish(at: now, result: DiskScanScheduleSafety.permissionNeeded)
            schedules = DiskScanSchedules([due, denied])
            return
        }
        schedules = Settings.storageSchedules.get()
        updateObservations()
        arm()
    }

    private func updateObservations() {
        if schedules.entries.isEmpty {
            for observer in conditionObservers { NotificationCenter.default.removeObserver(observer) }
            conditionObservers = []
            if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
            powerSource = nil
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
            wakeObserver = nil
            return
        }
        guard conditionObservers.isEmpty else { return }
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.conditionsChanged() }
            }
            conditionObservers.append(observer)
        }
        powerSource = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in StorageScheduler.shared.conditionsChanged() }
        }, nil)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.arm() }
        }
    }

    func save(_ schedule: DiskScanSchedule) {
        guard !isFixture else { return }
        var entries = schedules.entries.filter { $0.path != schedule.path }
        guard entries.count < DiskScanSchedules.limit else { return }
        let updated = schedule.preservingHistory(from: schedules.entries.first { $0.path == schedule.path })
        entries.append(updated)
        schedules = DiskScanSchedules(entries)
        persist()
        arm()
    }

    func remove(_ path: String) {
        guard !isFixture else { return }
        schedules.entries.removeAll { $0.path == path }
        if active?.path == path { StorageStore.shared.stop() }
        runNowPaths.remove(path)
        waiting.removeValue(forKey: path)
        persist()
        arm()
    }

    func runNow(_ path: String) {
        guard !isFixture, schedules.entries.contains(where: { $0.path == path }) else { return }
        runNowPaths.insert(path)
        arm()
    }

    private func persist() {
        Settings.storageSchedules.set(schedules)
        updateObservations()
    }

    private func conditionsChanged() {
        // Notifications move the same timer forward; system reads still happen only when it fires.
        guard !schedules.entries.isEmpty else { return }
        arm(checkActive: active != nil)
    }

    private func arm(afterRefusal: Bool = false, checkActive: Bool = false) {
        timer?.invalidate()
        timer = nil
        guard !isFixture, !checking, active == nil || checkActive, !schedules.entries.isEmpty else { return }
        let now = Date()
        let hasDue = !runNowPaths.isEmpty || schedules.entries.contains { $0.dueAt <= now }
        let deadline = checkActive || (hasDue && !afterRefusal) ? now : DiskScanEligibility.nextCheck(
            schedules.entries, now: now, pendingRunNow: !runNowPaths.isEmpty
        )
        guard let deadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
        timer.tolerance = 30
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fire() {
        timer?.invalidate()
        timer = nil
        guard !isFixture, !checking else { return }
        let now = Date()
        if let active {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
            var conditions = DiskScanScheduleReader.conditions(idleSeconds: idle, anotherScanRunning: false)
            // Input gates starting a walk; a power or thermal change can stop one already running.
            conditions.idleSeconds = 120
            if let reason = conditions.refusal(now: now, schedule: active, runNow: true) {
                waiting[active.path] = reason
                StorageStore.shared.stop()
            }
            return
        }
        let due = schedules.entries.filter { $0.dueAt <= now || runNowPaths.contains($0.path) }.sorted { $0.dueAt < $1.dueAt }
        guard let schedule = due.first else { arm(); return }
        // Read all HID input once per firing, not just mouse or keyboard events.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let conditions = DiskScanScheduleReader.conditions(idleSeconds: idle, anotherScanRunning: StorageStore.shared.isScanning)
        if let reason = conditions.refusal(now: now, schedule: schedule, runNow: runNowPaths.contains(schedule.path)) {
            prepared = nil
            for item in due { waiting[item.path] = reason }
            arm(afterRefusal: true)
            return
        }
        if prepared == schedule {
            prepared = nil
            active = schedule
            waiting.removeValue(forKey: schedule.path)
            let scope = StorageScope.resolve(schedule.path, volumes: StorageStore.shared.volumes)
            StorageStore.shared.scan(scope, scheduled: schedule)
            return
        }
        checking = true
        Task {
            let failure = await Task.detached(priority: .utility) { DiskScanScheduleReader.scopeFailure(path: schedule.path) }.value
            checking = false
            guard schedules.entries.contains(schedule) else { arm(); return }
            if let failure {
                finished(schedule, result: failure)
                return
            }
            // A fresh timer firing checks input and power again after asynchronous filesystem work.
            prepared = schedule
            arm()
        }
    }

    func completed(_ schedule: DiskScanSchedule, saved: StorageArchive.Saved?, cancelled: Bool) {
        active = nil
        if cancelled {
            waiting[schedule.path] = waiting[schedule.path] ?? "Scan stopped; waiting to retry"
            arm(afterRefusal: true)
            return
        }
        // A root it can't read was refused before the walk; private folders inside
        // (most of /Library has some) are counted, not a failure.
        let result = saved.map { saved in
            saved.saveFailure ?? DiskScanScheduleSafety.scannedText(saved.summary)
        } ?? "Scan failed; it runs again when next due"
        finished(schedule, result: result)
        guard let saved, saved.saveFailure == nil, let before = saved.earlier.first,
              DiskScanScheduleSafety.bigGrowth(before: before, after: saved.summary), Settings.storageScheduleNotifications.get() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Storage grew in \((schedule.path as NSString).lastPathComponent)"
        content.body = "Grew by \(Format.bytes(saved.summary.allocatedSize - before.allocatedSize)) since the previous scan. Open Storage to compare."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    private func finished(_ schedule: DiskScanSchedule, result: String) {
        if let index = schedules.entries.firstIndex(where: { $0 == schedule }) {
            schedules.entries[index].finish(at: Date(), result: result)
            persist()
        }
        runNowPaths.remove(schedule.path)
        waiting.removeValue(forKey: schedule.path)
        arm()
    }

    func scanEnded() {
        if active == nil { arm() }
    }

    func requestNotifications() {
        guard !isFixture else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }
}
