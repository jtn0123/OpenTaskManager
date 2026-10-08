import AppKit
import OTMKit
import SwiftUI

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
    private var lease = SamplingDemandLease()
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
        apply(lease.update(
            enabled: enabled, windowVisible: window?.occlusionState.contains(.visible) == true,
            miniaturized: window?.isMiniaturized == true, hidden: isHiddenOrHasHiddenAncestor,
            hasVisibleRoom: !visibleRect.isEmpty
        ))
    }

    func stop() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations = []
        releaseDemand()
    }

    private func releaseDemand() {
        apply(lease.release())
    }

    private func apply(_ change: SamplingDemandLease.Change?) {
        switch change {
        case .add: store.add(source)
        case .remove: store.remove(source)
        case nil: break
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if name == NSWindow.willCloseNotification { self?.releaseDemand() } else { self?.updateDemand() }
            }
        })
    }
}
