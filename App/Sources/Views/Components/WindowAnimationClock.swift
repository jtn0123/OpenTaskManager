import AppKit
import OTMKit

@MainActor
protocol WindowAnimationClient: AnyObject {
    var animationView: NSView? { get }
    func frameRate(displayRate: Double) -> Double
    func animate(at time: CFTimeInterval) -> Bool
    func animationStopped()
}

/// A window shares one display link for layer motion and counting numbers.
/// Rate requests are hints on a fixed-refresh screen, so each client also
/// gates its commits by time. No implicit animation fills in skipped frames.
@MainActor
final class WindowAnimationClock: NSObject {
    private final class Entry {
        weak var client: (any WindowAnimationClient)?
        var cadence: GraphFrameCadence

        init(client: any WindowAnimationClient, rate: Double) {
            self.client = client
            // Equal-rate graphs land in the same commit even if their
            // samples arrived a few milliseconds apart.
            cadence = GraphFrameCadence(rate: rate, start: 0)
        }
    }

    private static let clocks = NSMapTable<NSWindow, WindowAnimationClock>.weakToWeakObjects()
    private weak var window: NSWindow?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var link: CADisplayLink?
    private var requestedRate = 0.0

    static func start(_ client: any WindowAnimationClient) -> WindowAnimationClock? {
        guard let view = client.animationView, let window = view.window,
              window.occlusionState.contains(.visible), !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return nil }
        let clock = clocks.object(forKey: window) ?? WindowAnimationClock(window: window)
        clocks.setObject(clock, forKey: window)
        let rate = client.frameRate(displayRate: clock.displayRate)
        guard rate > 0 else { return nil }
        let key = ObjectIdentifier(client)
        if clock.entries[key] == nil { clock.entries[key] = Entry(client: client, rate: rate) }
        clock.refreshLink()
        return clock
    }

    private init(window: NSWindow) {
        self.window = window
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
        }
    }

    func remove(_ client: any WindowAnimationClient) {
        entries.removeValue(forKey: ObjectIdentifier(client))
        refreshLink()
    }

    private var displayRate: Double { Double(window?.screen?.maximumFramesPerSecond ?? 60) }

    private func refreshLink() {
        let rate = entries.values.compactMap { $0.client?.frameRate(displayRate: displayRate) }.max() ?? 0
        guard rate > 0, let window, window.occlusionState.contains(.visible) else {
            link?.invalidate()
            link = nil
            requestedRate = 0
            return
        }
        if link == nil {
            let link = window.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        if requestedRate != rate {
            requestedRate = rate
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        }
    }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification || window?.occlusionState.contains(.visible) != true {
            let clients = entries.values.compactMap(\.client)
            entries.removeAll()
            link?.invalidate()
            link = nil
            requestedRate = 0
            for client in clients { client.animationStopped() }
        } else {
            refreshLink()
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let time = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var drawing = false
        for (key, entry) in entries {
            guard let client = entry.client else {
                entries.removeValue(forKey: key)
                continue
            }
            guard !reduceMotion, let view = client.animationView, view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else {
                entries.removeValue(forKey: key)
                client.animationStopped()
                continue
            }
            let rate = client.frameRate(displayRate: displayRate)
            if rate != entry.cadence.rate { entry.cadence = GraphFrameCadence(rate: rate, start: 0) }
            if entry.cadence.takeFrame(at: time) {
                if !drawing {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    drawing = true
                }
                if !client.animate(at: time) {
                    entries.removeValue(forKey: key)
                    client.animationStopped()
                }
            }
        }
        if drawing { CATransaction.commit() }
        refreshLink()
    }
}
