import AppKit
import OTMKit

/// Paths stay still within the scroller. Only its position and each visible
/// marker move between samples, at the rate their screen distance needs.
@MainActor
final class StreamGraphMotion: WindowAnimationClient {
    private struct Head {
        let layer: CALayer
        let target: CGPoint
        let segment: GraphMotionSegment
    }

    weak var animationView: NSView?
    private var clock: WindowAnimationClock?
    private let scroller: CALayer
    private var heads: [ObjectIdentifier: Head] = [:]
    private var start: CFTimeInterval = 0
    private var duration: TimeInterval = 1
    private var step: CGFloat = 0
    private var scrolling = false
    private var distance: Double = 0

    init(scroller: CALayer) {
        self.scroller = scroller
    }

    func prepare(view: NSView, step: CGFloat, interval: TimeInterval, scrolls: Bool, reset: Bool) {
        animationView = view
        if scrolls, interval.isFinite, interval > 0 {
            start = CACurrentMediaTime()
            duration = interval
            self.step = step
            scrolling = true
            heads.removeAll()
            scroller.position = .zero
        } else if reset {
            stop()
            self.step = step
            scroller.position = CGPoint(x: -step, y: 0)
        } else if scrolling {
            let progress = min(max((CACurrentMediaTime() - start) / duration, 0), 1)
            scroller.position = CGPoint(x: GraphFrameRate.scrollOffset(step: Double(step), progress: progress, scale: scale), y: 0)
        } else {
            scroller.position = CGPoint(x: -step, y: 0)
        }
    }

    func placeHead(_ layer: CALayer, target: CGPoint, segment: GraphMotionSegment?, animated: Bool) {
        let key = ObjectIdentifier(layer)
        if animated, scrolling, let segment, segment.peakSpeed > 0 {
            heads[key] = Head(layer: layer, target: target, segment: segment)
            layer.position = CGPoint(x: target.x, y: segment.start)
        } else if heads[key]?.target != target || layer.isHidden {
            heads.removeValue(forKey: key)
            layer.position = target
        }
    }

    func resume() {
        guard scrolling else { return }
        distance = max(Double(step), heads.values.map { $0.segment.peakSpeed }.max() ?? 0)
        clock = WindowAnimationClock.start(self)
        if clock == nil { animationStopped() }
    }

    func stop() {
        clock?.remove(self)
        animationStopped()
    }

    func frameRate(displayRate: Double) -> Double {
        guard scrolling else { return 0 }
        return GraphFrameRate.rate(distance: distance, scale: scale, interval: duration, displayRate: displayRate)
    }

    func animate(at time: CFTimeInterval) -> Bool {
        let progress = min(max((time - start) / duration, 0), 1)
        let x = GraphFrameRate.scrollOffset(step: Double(step), progress: progress, scale: scale)
        if scroller.position.x != x { scroller.position = CGPoint(x: x, y: 0) }
        for head in heads.values where !head.layer.isHidden {
            let y = progress == 1 ? Double(head.target.y) : head.segment.value(at: progress)
            let position = CGPoint(x: head.target.x, y: y)
            if head.layer.position != position { head.layer.position = position }
        }
        return progress < 1
    }

    func animationStopped() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if scrolling {
            scroller.position = CGPoint(x: -step, y: 0)
            for head in heads.values { head.layer.position = head.target }
        }
        CATransaction.commit()
        scrolling = false
        heads.removeAll()
        clock = nil
    }

    private var scale: Double { Double(animationView?.window?.backingScaleFactor ?? 2) }
}
