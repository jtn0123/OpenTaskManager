import AppKit
import OTMKit

/// Paths stay still within the scroller. Only its position and each visible
/// marker move between samples. Timing and curves are prepared per sample,
/// so a due frame needs no view queries or collection lookups.
@MainActor
final class StreamGraphMotion: WindowAnimationClient {
    private struct Head {
        let layer: CALayer
        let target: CGPoint
        let curve: GraphMotionCurve
        let speed: Double
    }

    weak var animationView: NSView?
    private var clock: WindowAnimationClock?
    private let scroller: CALayer
    private var heads: [Head] = []
    private var timing = GraphMotionTiming(start: 0, interval: 1)
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
            timing = GraphMotionTiming(start: CACurrentMediaTime(), interval: interval)
            duration = interval
            self.step = step
            scrolling = true
            heads.removeAll(keepingCapacity: true)
            scroller.position = .zero
        } else if reset {
            stop()
            self.step = step
            scroller.position = CGPoint(x: -step, y: 0)
        } else if scrolling {
            scroller.position = CGPoint(x: -step * timing.progress(at: CACurrentMediaTime()), y: 0)
        } else {
            scroller.position = CGPoint(x: -step, y: 0)
        }
    }

    func placeHead(_ layer: CALayer, target: CGPoint, segment: GraphMotionSegment?, animated: Bool) {
        let index = heads.firstIndex { $0.layer === layer }
        if animated, scrolling, let segment, segment.peakSpeed > 0 {
            let head = Head(layer: layer, target: target, curve: GraphMotionCurve(segment), speed: segment.peakSpeed)
            if let index { heads[index] = head } else { heads.append(head) }
            layer.position = CGPoint(x: target.x, y: segment.start)
        } else if let index {
            // An appearance or height redraw with the same target keeps the
            // glide underway, just as the scroller keeps its sample's timing.
            if heads[index].target != target || layer.isHidden {
                heads.remove(at: index)
                layer.position = target
            }
        } else {
            layer.position = target
        }
    }

    func resume() {
        guard scrolling else { return }
        heads.removeAll { $0.layer.superlayer == nil }
        distance = Double(step)
        for head in heads where head.speed > distance { distance = head.speed }
        if let next = WindowAnimationClock.start(self) {
            clock = next
        } else {
            stop()
        }
    }

    func stop() {
        clock?.remove(self)
        animationStopped()
    }

    /// The clock calls this only for a sample or a display change, never a frame.
    func frameRate(displayRate: Double) -> Double {
        guard scrolling else { return 0 }
        let scale = Double(animationView?.window?.backingScaleFactor ?? 2)
        return GraphFrameRate.rate(distance: distance, scale: scale, interval: duration, displayRate: displayRate)
    }

    func animate(at time: CFTimeInterval) -> Bool {
        let progress = timing.progress(at: time)
        let x = -step * progress
        if scroller.position.x != x { scroller.position = CGPoint(x: x, y: 0) }
        heads.withUnsafeBufferPointer { buffer in
            guard let head = buffer.baseAddress else { return }
            var index = 0
            while index < buffer.count {
                let current = head[index]
                let y = progress == 1 ? Double(current.target.y) : current.curve.value(at: progress)
                let position = CGPoint(x: current.target.x, y: y)
                if current.layer.position != position { current.layer.position = position }
                index += 1
            }
        }
        if progress == 1 { scrolling = false }
        return scrolling
    }

    func animationStopped() {
        // A completing frame already placed the endpoints in the window's
        // transaction. Only cancellation needs to settle the layers here.
        if scrolling {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scroller.position = CGPoint(x: -step, y: 0)
            for head in heads { head.layer.position = head.target }
            CATransaction.commit()
        }
        scrolling = false
        heads.removeAll(keepingCapacity: true)
        clock = nil
    }
}
