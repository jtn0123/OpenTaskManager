import AppKit
import CoreGraphics
import OTMKit

/// View lifetimes share the samplers without following the selected page:
/// another window can still need a source after this one leaves it.
@MainActor
final class SamplingDemandStore {
    private var demand = SamplingDemand()
    private var visibility = SamplingVisibility()
    private var observers: [NSObjectProtocol] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var visibilityChanged: (() -> Void)?

    var hasVisibleWindow: Bool { visibility.isVisible(windowDemand: demand.contains(.window)) }
    var displayIsAwake: Bool { !visibility.displayAsleep && !visibility.screenLocked }

    init() {
        // No application object in the hostless tests.
        visibility.applicationHidden = NSApp?.isHidden ?? false
        let displays = NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        visibility.displayAsleep = !displays.isEmpty && displays.allSatisfy { CGDisplayIsAsleep($0) != 0 }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        visibility.screenLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        observe(NotificationCenter.default, NSApplication.didHideNotification) { $0.applicationHidden = true }
        observe(NotificationCenter.default, NSApplication.didUnhideNotification) { $0.applicationHidden = false }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         change: @escaping @MainActor (inout SamplingVisibility) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.hasVisibleWindow
                change(&self.visibility)
                self.notifyVisibility(after: previous)
            }
        })
    }

    func contains(_ source: SamplingDemand.Source) -> Bool { demand.contains(source) }
    func add(_ source: SamplingDemand.Source) {
        let previous = hasVisibleWindow
        demand.add(source)
        notifyVisibility(after: previous)
    }

    func remove(_ source: SamplingDemand.Source) {
        let previous = hasVisibleWindow
        demand.remove(source)
        notifyVisibility(after: previous)
    }

    private func notifyVisibility(after previous: Bool) {
        guard previous != hasVisibleWindow else { return }
        if hasVisibleWindow {
            let pending = waiters.values
            waiters = [:]
            for waiter in pending { waiter.resume() }
        }
        visibilityChanged?()
    }

    /// View-only readers wait on a notification instead of waking to poll
    /// a covered window. Cancellation releases a removed view's waiter.
    func waitUntilVisible() async {
        while !hasVisibleWindow && !Task.isCancelled {
            let token = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if hasVisibleWindow || Task.isCancelled { continuation.resume() } else { waiters[token] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: token)?.resume() }
            }
        }
    }
}
