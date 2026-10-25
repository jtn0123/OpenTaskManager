import AppKit
import OTMKit

@MainActor
protocol WindowAnimationClient: AnyObject {
    var animationView: NSView? { get }
    func frameRate(displayRate: Double) -> Double
    func animate(at time: CFTimeInterval) -> Bool
    func animationStopped()
}

/// Rates and membership are prepared between frames. Equal-rate clients
/// share one deadline, and all due batches move in one transaction. A fixed
/// refresh display can call faster than requested without visiting slow clients.
@MainActor
final class WindowAnimationClock: NSObject {
    private final class Entry {
        weak var client: (any WindowAnimationClient)?
        var rate: Double
        var active = true

        init(client: any WindowAnimationClient, rate: Double) {
            self.client = client
            self.rate = rate
        }
    }

    private final class Batch {
        var cadence: GraphFrameCadence
        var entries: [Entry] = []

        init(rate: Double) {
            // A new member keeps the batch's phase, even if its sample
            // arrived a few milliseconds after the other members'.
            cadence = GraphFrameCadence(rate: rate, start: 0)
        }
    }

    private static let clocks = NSMapTable<NSWindow, WindowAnimationClock>.weakToWeakObjects()
    private weak var window: NSWindow?
    /// These dictionaries are used only when membership or rates change.
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var batchesByRate: [Double: Batch] = [:]
    private var batches: [Batch] = []
    private let observedClips = NSHashTable<NSClipView>.weakObjects()
    private var link: CADisplayLink?
    private var displayRate: Double
    private var requestedRate = 0.0
    private var maintenancePending = false

    static func start(_ client: any WindowAnimationClient) -> WindowAnimationClock? {
        guard let view = client.animationView, let window = view.window,
              window.occlusionState.contains(.visible), !window.isMiniaturized,
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return nil }
        let clock = clocks.object(forKey: window) ?? WindowAnimationClock(window: window)
        clocks.setObject(clock, forKey: window)
        let rate = client.frameRate(displayRate: clock.displayRate)
        guard rate > 0, rate.isFinite else { return nil }
        let key = ObjectIdentifier(client)
        if let entry = clock.entries[key] {
            if entry.active, entry.rate == rate { return clock }
            entry.active = true
            entry.rate = rate
        } else {
            clock.entries[key] = Entry(client: client, rate: rate)
            clock.observeClips(of: view)
        }
        clock.scheduleMaintenance()
        return clock
    }

    private init(window: NSWindow) {
        self.window = window
        displayRate = Double(window.screen?.maximumFramesPerSecond ?? 60)
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                     NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    func remove(_ client: any WindowAnimationClient) {
        guard let entry = entries[ObjectIdentifier(client)], entry.active else { return }
        entry.active = false
        scheduleMaintenance()
    }

    private func observeClips(of view: NSView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let clip = current as? NSClipView, !observedClips.contains(clip) {
                observedClips.add(clip)
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                       name: NSView.boundsDidChangeNotification, object: clip)
            }
            ancestor = current.superview
        }
    }

    /// Sample updates in one run-loop turn rebuild the batches once. A
    /// finishing frame marks entries inactive; its cleanup waits until after
    /// the pointer walk, so membership arrays never copy during that walk.
    private func scheduleMaintenance() {
        guard !maintenancePending else { return }
        maintenancePending = true
        DispatchQueue.main.async { [weak self] in self?.maintainBatches() }
    }

    private func maintainBatches() {
        maintenancePending = false
        entries = entries.filter { $0.value.active && $0.value.client != nil }
        var next: [Double: Batch] = [:]
        for entry in entries.values {
            let rate = entry.rate
            let batch: Batch
            if let existing = next[rate] {
                batch = existing
            } else {
                batch = batchesByRate[rate] ?? Batch(rate: rate)
                batch.entries.removeAll(keepingCapacity: true)
                next[rate] = batch
            }
            batch.entries.append(entry)
        }
        batchesByRate = next
        batches = next.values.sorted { $0.cadence.rate < $1.cadence.rate }
        refreshLink()
    }

    private func refreshLink() {
        let rate = batches.last?.cadence.rate ?? 0
        guard rate > 0, let window, window.occlusionState.contains(.visible), !window.isMiniaturized else {
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
        if notification.name == NSWindow.willCloseNotification || window?.occlusionState.contains(.visible) != true
            || window?.isMiniaturized != false {
            stopAll()
            return
        }
        displayRate = Double(window?.screen?.maximumFramesPerSecond ?? 60)
        for entry in entries.values where entry.active {
            entry.rate = entry.client?.frameRate(displayRate: displayRate) ?? 0
            if entry.rate <= 0 || !entry.rate.isFinite {
                entry.active = false
                entry.client?.animationStopped()
            }
        }
        visibilityChanged()
        scheduleMaintenance()
    }

    @objc private func displayOptionsChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { stopAll() }
    }

    @objc private func visibilityChanged() {
        var changed = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in entries.values where entry.active {
            guard let view = entry.client?.animationView, view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else {
                entry.active = false
                entry.client?.animationStopped()
                changed = true
                continue
            }
        }
        CATransaction.commit()
        if changed { scheduleMaintenance() }
    }

    private func stopAll() {
        link?.invalidate()
        link = nil
        requestedRate = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in entries.values where entry.active {
            entry.active = false
            entry.client?.animationStopped()
        }
        CATransaction.commit()
        entries.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        batchesByRate.removeAll(keepingCapacity: true)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !maintenancePending else { return }
        let time = CACurrentMediaTime()
        var drawing = false
        var finished = false
        batches.withUnsafeBufferPointer { buffer in
            guard let batch = buffer.baseAddress else { return }
            var index = 0
            while index < buffer.count {
                let current = batch[index]
                if time >= current.cadence.nextFrameTime, current.cadence.takeFrame(at: time) {
                    if !drawing {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        drawing = true
                    }
                    if move(current, at: time) { finished = true }
                }
                index += 1
            }
        }
        if drawing { CATransaction.commit() }
        if finished { scheduleMaintenance() }
    }

    /// No view queries, rate calculations, dictionary lookups or membership
    /// edits here. Non-escaping buffer borrows keep the frame allocation-free.
    private func move(_ batch: Batch, at time: CFTimeInterval) -> Bool {
        var finished = false
        batch.entries.withUnsafeBufferPointer { buffer in
            guard let entry = buffer.baseAddress else { return }
            var index = 0
            while index < buffer.count {
                let current = entry[index]
                if current.active {
                    if let client = current.client {
                        if !client.animate(at: time) {
                            current.active = false
                            client.animationStopped()
                            finished = true
                        }
                    } else {
                        current.active = false
                        finished = true
                    }
                }
                index += 1
            }
        }
        return finished
    }
}
