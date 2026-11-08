import Foundation

/// The newest segment's vertical motion, in points. Keeping its curve and
/// speed together lets the marker stay on the line without redrawing paths.
public struct GraphMotionSegment: Sendable {
    public var start: Double
    public var end: Double
    public var startTangent: Double
    public var endTangent: Double

    public init(start: Double, end: Double, startTangent: Double, endTangent: Double) {
        self.start = start
        self.end = end
        self.startTangent = startTangent
        self.endTangent = endTangent
    }

    public func value(at progress: Double) -> Double {
        GraphMath.hermite(from: start, to: end, startTangent: startTangent, endTangent: endTangent, at: progress)
    }

    /// Largest distance per unit of progress, including a steep middle of
    /// the curve. Endpoint distance alone would undersample that stretch.
    public var peakSpeed: Double {
        let quadratic = 6 * (start - end) + 3 * (startTangent + endTangent)
        let linear = 6 * (end - start) - 4 * startTangent - 2 * endTangent
        var peak = max(abs(startTangent), abs(endTangent))
        if quadratic != 0 {
            let vertex = -linear / (2 * quadratic)
            if vertex > 0, vertex < 1 {
                peak = max(peak, abs((quadratic * vertex + linear) * vertex + startTangent))
            }
        }
        return peak
    }
}

/// One device pixel per frame is enough for a slow graph to look continuous.
/// A small floor keeps even tiny tiles moving between samples; zero is idle.
public enum GraphFrameRate {
    public static func rate(distance: Double, scale: Double, interval: Double, displayRate: Double) -> Double {
        guard distance.isFinite, distance > 0, scale.isFinite, scale > 0,
              interval.isFinite, interval > 0, displayRate.isFinite, displayRate > 0 else { return 0 }
        return min(max(ceil(distance * scale / interval), 4), min(displayRate, 60))
    }

    /// Travel ends exactly one step on, even when it isn't a whole device
    /// pixel. Fractional positions keep a steep head on its curve when its
    /// vertical speed needs more frames than the sideways scroll alone.
    public static func scrollOffset(step: Double, progress: Double, scale: Double) -> Double {
        guard step.isFinite, step > 0, progress.isFinite, scale.isFinite, scale > 0 else { return 0 }
        return -step * min(max(progress, 0), 1)
    }
}

/// Gates layer commits even when a fixed-refresh display delivers callbacks
/// faster than requested. Missed frames catch up by time, never by counting.
public struct GraphFrameCadence: Sendable {
    public let rate: Double
    public private(set) var nextFrameTime: Double
    private let start: Double

    public init(rate: Double, start: Double) {
        self.rate = rate
        self.start = start
        nextFrameTime = rate.isFinite && rate > 0 && start.isFinite ? start : .infinity
    }

    public mutating func takeFrame(at time: Double) -> Bool {
        guard time >= nextFrameTime, time.isFinite else { return false }
        let frame = floor((time - start) * rate + 1e-7)
        // The same slack as the frame index keeps exact display boundaries
        // due despite floating-point rounding. A missed frame never queues work.
        nextFrameTime = start + (frame + 1 - 1e-7) / rate
        return true
    }
}

/// A Hermite segment prepared once per sample. Horner's form needs only
/// three multiplies and adds for a marker's y on each frame.
public struct GraphMotionCurve: Sendable {
    private let cubic: Double
    private let quadratic: Double
    private let linear: Double
    private let constant: Double

    public init(_ segment: GraphMotionSegment) {
        cubic = 2 * (segment.start - segment.end) + segment.startTangent + segment.endTangent
        quadratic = 3 * (segment.end - segment.start) - 2 * segment.startTangent - segment.endTangent
        linear = segment.startTangent
        constant = segment.start
    }

    public func value(at progress: Double) -> Double {
        ((cubic * progress + quadratic) * progress + linear) * progress + constant
    }
}

/// Cached timing for one sample's motion. A delayed frame reaches the
/// current position immediately, and an expired sample settles exactly.
public struct GraphMotionTiming: Sendable {
    private let start: Double
    private let inverseInterval: Double

    public init(start: Double, interval: Double) {
        self.start = start
        inverseInterval = interval.isFinite && interval > 0 ? 1 / interval : 0
    }

    public func progress(at time: Double) -> Double {
        guard inverseInterval > 0 else { return 1 }
        let fraction = (time - start) * inverseInterval
        if fraction < 0 { return 0 }
        return fraction < 1 ? fraction : 1
    }
}
