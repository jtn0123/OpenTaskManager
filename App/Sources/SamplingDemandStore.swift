import AppKit
import CoreGraphics
import OTMKit
import SwiftUI

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
        visibility.applicationHidden = NSApp.isHidden
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

extension View {
    /// Counts only while this view has visible room in a visible window.
    /// Occlusion and scrolling change demand without waiting for a tick.
    func samplingDemand(_ source: SamplingDemand.Source, when enabled: Bool = true) -> some View {
        background { SamplingDemandView(source: source, enabled: enabled) }
    }
}

private struct SamplingDemandView: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    var source: SamplingDemand.Source
    var enabled: Bool

    func makeNSView(context: Context) -> DemandView {
        DemandView(store: model.samplingDemand, source: source, enabled: enabled)
    }

    func updateNSView(_ view: DemandView, context: Context) {
        view.enabled = enabled
        view.updateDemand()
    }

    static func dismantleNSView(_ view: DemandView, coordinator: Void) { view.stop() }
}

private final class DemandView: NSView {
    let store: SamplingDemandStore
    let source: SamplingDemand.Source
    var enabled: Bool
    private var counted = false
    private var observations: [NSObjectProtocol] = []

    init(store: SamplingDemandStore, source: SamplingDemand.Source, enabled: Bool) {
        self.store = store
        self.source = source
        self.enabled = enabled
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        observe(NSWindow.didChangeOcclusionStateNotification, object: window)
        observe(NSWindow.didMiniaturizeNotification, object: window)
        observe(NSWindow.didDeminiaturizeNotification, object: window)
        observe(NSWindow.willCloseNotification, object: window)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observe(NSView.boundsDidChangeNotification, object: clip)
        }
        updateDemand()
    }

    override func layout() {
        super.layout()
        updateDemand()
    }

    func updateDemand() {
        let visible = enabled && window?.occlusionState.contains(.visible) == true
            && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        guard visible != counted else { return }
        counted = visible
        if visible { store.add(source) } else { store.remove(source) }
    }

    func stop() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations = []
        releaseDemand()
    }

    private func releaseDemand() {
        if counted { store.remove(source) }
        counted = false
    }

    private func observe(_ name: Notification.Name, object: AnyObject) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if name == NSWindow.willCloseNotification { self?.releaseDemand() } else { self?.updateDemand() }
            }
        })
    }
}
