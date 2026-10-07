import Foundation

/// The top of an auto-scaled share graph (CPU), so light load isn't
/// crushed against the bottom of a 100% scale.
///
/// The bound is one of a few round figures (10, 20, 25, 50, 75 or 100%), with
/// headroom over the data, and it holds steady: it grows as soon as the
/// data needs more room, but shrinks only once the data has stayed well
/// inside a smaller bound for a while. Between the two thresholds neither
/// happens, so load hovering near a step never flicks between two scales.
public struct AutoScale: Equatable, Sendable {
    /// The bounds a scale stops at, as fractions of the whole.
    public static let steps: [Double] = [0.1, 0.2, 0.25, 0.5, 0.75, 1]
    /// The share of a bound the data may reach before the scale grows.
    public static let headroom = 0.85
    /// The share of a smaller bound the data must stay under for the scale
    /// to shrink to it: well below the point where it would grow again.
    public static let shrinkFill = 0.7
    /// Seconds the data must stay that low before the scale shrinks.
    public static let hold: TimeInterval = 15

    /// The current top of the scale.
    public private(set) var bound: Double
    /// When the data last came to fit a smaller bound, while it still does.
    private var lowSince: TimeInterval?

    /// A scale that fits data peaking at `peak` right away.
    public init(peak: Double) {
        bound = Self.bound(for: peak)
    }

    /// The smallest step that holds `peak` within the headroom, or 100% when
    /// none does. For data that is drawn once, such as a recorded range.
    public static func bound(for peak: Double) -> Double {
        let peak = peak.isNaN ? 0 : peak
        return smallestStep { peak <= $0 * headroom }
    }

    /// The bound after a sample, for data now peaking at `peak` (the highest
    /// value on screen), at `time` in seconds on a steady clock.
    @discardableResult
    public mutating func update(peak: Double, at time: TimeInterval) -> Double {
        let peak = peak.isNaN ? 0 : peak
        let needed = Self.bound(for: peak)
        if needed > bound {
            bound = needed
            lowSince = nil
            return bound
        }
        let smaller = Self.smallestStep { peak <= $0 * Self.shrinkFill }
        guard smaller < bound else {
            lowSince = nil
            return bound
        }
        let since = lowSince ?? time
        if time - since >= Self.hold {
            bound = smaller
            lowSince = nil
        } else {
            lowSince = since
        }
        return bound
    }

    private static func smallestStep(where fits: (Double) -> Bool) -> Double {
        steps.first(where: fits) ?? steps[steps.count - 1]
    }
}
