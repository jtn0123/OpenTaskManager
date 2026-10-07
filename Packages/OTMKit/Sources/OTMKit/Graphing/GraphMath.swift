import Foundation

/// Shape and scale math for the app's graphs. It lives here, away from the
/// drawing code, so it can be unit tested.
public enum GraphMath {
    /// Steps within each power of ten that an auto-scaled axis may stop at.
    /// Finer than the classic 1-2-5 so the line uses most of the height.
    static let ceilingSteps: [Double] = [1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]

    /// Rounds up to a tidy axis maximum (1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 × 10ⁿ).
    public static func niceCeiling(_ value: Double) -> Double {
        // Below 1e-300 the power of ten underflows to zero.
        guard value > 1e-300, value.isFinite else { return 1 }
        let base = pow(10, floor(log10(value)))
        // Compare with a little slack so 2.0000000001 doesn't round up to 2.5.
        for step in ceilingSteps where value <= step * base * (1 + 1e-9) {
            return step * base
        }
        return 10 * base
    }

    /// How an axis will be labelled, so its top lands on a round number in
    /// the units the reader sees.
    public enum AxisUnits: Sendable {
        case plain
        /// Bytes shown with 1024-based units ("400 MB/s").
        case binaryBytes
        /// Bytes shown as decimal bits ("8 Mbps").
        case bits
    }

    /// Top of an auto-scaled axis for values peaking at `peak`, never below
    /// `floor`. An all-zero graph gets a scale of 1.
    public static func ceiling(peak: Double, floor: Double = 0, headroom: Double = 1.05, units: AxisUnits = .plain) -> Double {
        let target = max(peak * headroom, floor)
        guard target > 0 else { return 1 }
        switch units {
        case .plain:
            return niceCeiling(target)
        case .bits:
            return niceCeiling(target * 8) / 8
        case .binaryBytes:
            guard target >= 1024, target.isFinite else { return niceCeiling(target) }
            let base = pow(1024, Foundation.floor(log(target) / log(1024)))
            // 1,000-1,024 of a unit reads better as one of the next unit up.
            return min(niceCeiling(target / base), 1024) * base
        }
    }

    /// Fritsch–Carlson tangents for values at evenly spaced x (spacing 1).
    ///
    /// A cubic through the values with these tangents passes through every
    /// point but never overshoots its neighbours, so a smoothed line can't
    /// poke above 100% or dip below zero.
    public static func monotoneTangents(_ values: [Double]) -> [Double] {
        let count = values.count
        guard count > 1 else { return Array(repeating: 0, count: count) }
        let deltas = (0..<count - 1).map { values[$0 + 1] - values[$0] }
        var tangents = [Double](repeating: 0, count: count)
        tangents[0] = deltas[0]
        tangents[count - 1] = deltas[count - 2]
        for index in 1..<count - 1 where deltas[index - 1] * deltas[index] > 0 {
            tangents[index] = (deltas[index - 1] + deltas[index]) / 2
        }
        for index in 0..<count - 1 {
            let delta = deltas[index]
            if delta == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let alpha = tangents[index] / delta
            let beta = tangents[index + 1] / delta
            let length = alpha * alpha + beta * beta
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[index] = scale * alpha * delta
                tangents[index + 1] = scale * beta * delta
            }
        }
        return tangents
    }

    /// Value on the cubic Hermite segment from `start` to `end` (one x-step
    /// apart) at `progress` in 0...1. With tangents from `monotoneTangents`,
    /// this is exactly the curve the graphs draw.
    public static func hermite(from start: Double, to end: Double, startTangent: Double, endTangent: Double, at progress: Double) -> Double {
        let squared = progress * progress
        let cubed = squared * progress
        return (2 * cubed - 3 * squared + 1) * start
            + (cubed - 2 * squared + progress) * startTangent
            + (-2 * cubed + 3 * squared) * end
            + (cubed - squared) * endTangent
    }

    /// Running totals for a stacked graph: element `i` of the result is the
    /// sum of series `0...i`. Series are aligned on their newest value, and
    /// the result is as long as the longest series.
    public static func stack(_ series: [[Double]]) -> [[Double]] {
        let length = series.map(\.count).max() ?? 0
        var running = [Double](repeating: 0, count: length)
        return series.map { values in
            let offset = length - values.count
            for (index, value) in values.enumerated() {
                running[offset + index] += max(value, 0)
            }
            return running
        }
    }

    /// Times to label on a time axis: every `step` seconds counted from local
    /// midnight, so they land on round clock times, leaving out any within
    /// `margin` (a share of the range) of either end, where a centred label
    /// would be cut off.
    public static func timeTicks(in range: ClosedRange<Date>, step: TimeInterval, margin: Double = 0.05,
                                 calendar: Calendar = .current) -> [Date] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0, step > 0 else { return [] }
        let low = range.lowerBound.addingTimeInterval(span * margin)
        let high = range.upperBound.addingTimeInterval(-span * margin)
        let midnight = calendar.startOfDay(for: range.lowerBound)
        var tick = midnight.addingTimeInterval((low.timeIntervalSince(midnight) / step).rounded(.up) * step)
        var ticks: [Date] = []
        while tick <= high {
            ticks.append(tick)
            tick = tick.addingTimeInterval(step)
        }
        return ticks
    }

    /// Round steps a time axis may be labelled at, from ten seconds to a week.
    static let timeSteps: [TimeInterval] = [
        10, 15, 30, 60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60,
        3_600, 2 * 3_600, 3 * 3_600, 4 * 3_600, 6 * 3_600, 12 * 3_600, 86_400, 2 * 86_400, 7 * 86_400,
    ]

    /// The shortest round step (10, 15 or 30 s; 1, 2, 5, 10, 15 or 30 min;
    /// 1, 2, 3, 4, 6 or 12 h; 1, 2 or 7 days, then whole weeks) that labels
    /// an axis `span` seconds long no more than `maximumTicks` times. For
    /// spans that aren't one of the fixed ranges, such as a short recording
    /// fitted to the width.
    public static func timeTickStep(for span: TimeInterval, maximumTicks: Int = 6) -> TimeInterval {
        guard span.isFinite, span > 0, maximumTicks > 0 else { return timeSteps[0] }
        // A little slack, so an hour over six ticks gets 10 minutes, not 15.
        let shortest = span / Double(maximumTicks) * (1 - 1e-9)
        if let step = timeSteps.first(where: { $0 >= shortest }) { return step }
        let week = 7 * 86_400.0
        return (shortest / week).rounded(.up) * week
    }

    // MARK: - History ranges

    /// Whether fitting a history graph to its recording would change it: the
    /// recording, `recorded` seconds old, began well inside the `range`.
    public static func canFit(range: TimeInterval, recorded: TimeInterval?) -> Bool {
        guard let recorded, recorded.isFinite, recorded >= 0 else { return false }
        return recorded < range * 0.95
    }

    /// Seconds a history graph spans: the whole `range`, or with `fit`, back
    /// only as far as the recording goes (never under `minimum`). Fitting
    /// changes the axis, not the data: ten minutes of recording are labelled
    /// as ten minutes, and gaps in them stay gaps.
    public static func historySpan(range: TimeInterval, recorded: TimeInterval?, fit: Bool, minimum: TimeInterval = 60) -> TimeInterval {
        guard fit, canFit(range: range, recorded: recorded), let recorded else { return range }
        return min(max(recorded, minimum), range)
    }
}
