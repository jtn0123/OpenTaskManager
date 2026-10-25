import AppKit
import OTMKit
import os

/// Saves the flight recorder's events (`HistoryEvent`) as they happen: apps
/// launched and quit, and the Mac going to sleep and waking, from
/// NSWorkspace's notifications; the network in use changing, from
/// `NetworkChangeMonitor`; and busy background processes starting and
/// exiting, from each update's process list (`ProcessEventTracker`). None of
/// it reads anything per tick beyond the process list the update already
/// has, and each save goes to the recorder off the main actor.
@MainActor
final class HistoryEventMonitor {
    private let recorder: FlightRecorder
    private var tracker = ProcessEventTracker()
    private var network: NetworkChangeMonitor?
    // Tokens never leave the lock, including when deinit runs off the main actor.
    private let observers = OSAllocatedUnfairLock<[NSObjectProtocol]>(uncheckedState: [])

    init(recorder: FlightRecorder) {
        self.recorder = recorder
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.didLaunchApplicationNotification) { monitor, app in
            // Only the apps in the Dock: agents and helpers come and go by the dozen.
            guard let app, app.activationPolicy == .regular else { return }
            // Its own launch time, from before it finished launching.
            monitor.save([HistoryEvent(time: app.launchDate ?? Date(), kind: .appLaunched, name: Self.name(of: app),
                                       detail: app.bundleIdentifier ?? "")])
        }
        observe(center, NSWorkspace.didTerminateApplicationNotification) { monitor, app in
            guard let app, app.activationPolicy == .regular else { return }
            monitor.save([HistoryEvent(time: Date(), kind: .appQuit, name: Self.name(of: app), detail: app.bundleIdentifier ?? "")])
        }
        observe(center, NSWorkspace.willSleepNotification) { monitor, _ in
            monitor.save(monitor.tracker.flush() + [HistoryEvent(time: Date(), kind: .sleep, name: "")])
        }
        observe(center, NSWorkspace.didWakeNotification) { monitor, _ in
            monitor.save([HistoryEvent(time: Date(), kind: .wake, name: "")])
        }
        network = NetworkChangeMonitor { [weak self] event in self?.save([event]) }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.withLock { tokens in
            for observer in tokens { center.removeObserver(observer) }
        }
    }

    /// Takes one update's processes, leaving out the apps NSWorkspace
    /// reports, and saves the starts and exits whose time has settled.
    func update(_ processes: [ProcessSample], apps: Set<Int32>, at time: Date) {
        let events = tracker.update(processes, skipping: apps, at: time)
        if !events.isEmpty { save(events) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handle: @escaping @MainActor (HistoryEventMonitor, NSRunningApplication?) -> Void) {
        observers.withLock { tokens in
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handle(self, app)
                }
            })
        }
    }

    private func save(_ events: [HistoryEvent]) {
        guard !events.isEmpty else { return }
        let recorder = recorder
        Task.detached(priority: .utility) {
            try? await recorder.append(events)
        }
    }

    private static func name(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App \(app.processIdentifier)"
    }
}
