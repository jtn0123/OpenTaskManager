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
        var tangents = [Double](repeating: 0, count: count)
        // While loops over pointers: every graph runs this for each point each
        // sample, and in a debug build a range's iterator and an array's
        // subscript are each a call per point, where a pointer's isn't. Each
        // slope is worked out where it's needed, the same subtraction each time.
        values.withUnsafeBufferPointer { valueBuffer in
            tangents.withUnsafeMutableBufferPointer { tangentBuffer in
                guard let value = valueBuffer.baseAddress, let tangent = tangentBuffer.baseAddress else { return }
                tangent[0] = value[1] - value[0]
                tangent[count - 1] = value[count - 1] - value[count - 2]
                var index = 1
                while index < count - 1 {
                    let before = value[index] - value[index - 1]
                    let after = value[index + 1] - value[index]
                    if before * after > 0 { tangent[index] = (before + after) / 2 }
                    index += 1
                }
                index = 0
                while index < count - 1 {
                    let delta = value[index + 1] - value[index]
                    if delta == 0 {
                        tangent[index] = 0
                        tangent[index + 1] = 0
                    } else {
                        let alpha = tangent[index] / delta
                        let beta = tangent[index + 1] / delta
                        let length = alpha * alpha + beta * beta
                        if length > 9 {
                            let scale = 3 / length.squareRoot()
                            tangent[index] = scale * alpha * delta
                            tangent[index + 1] = scale * beta * delta
                        }
                    }
                    index += 1
                }
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
        var running = [Double](repeating: 0, count: longest(series))
        var result: [[Double]] = []
        result.reserveCapacity(series.count)
        for values in series {
            addAligned(values, into: &running, floorsAtZero: true)
            result.append(running)
        }
        return result
    }

    /// Adds series element-wise, aligned on their newest values; the result
    /// is as long as the longest.
    public static func tailSum(_ series: [[Double]]) -> [Double] {
        var sums = [Double](repeating: 0, count: longest(series))
        for values in series {
            addAligned(values, into: &sums, floorsAtZero: false)
        }
        return sums
    }

    /// `total` minus the sum of `parts`, aligned on the newest value and
    /// never negative: what a stacked graph's top band, the rest, shows.
    public static func remainder(of total: [Double], minus parts: [[Double]]) -> [Double] {
        let used = tailSum(parts)
        let count = total.count
        // Where `total`'s first value falls in `used`, which may be shorter.
        let offset = used.count - count
        var result = [Double](repeating: 0, count: count)
        total.withUnsafeBufferPointer { totalBuffer in
            used.withUnsafeBufferPointer { usedBuffer in
                result.withUnsafeMutableBufferPointer { resultBuffer in
                    guard let value = totalBuffer.baseAddress, let out = resultBuffer.baseAddress else { return }
                    let part = usedBuffer.baseAddress
                    var index = 0
                    while index < count {
                        let rest = value[index] - (index + offset >= 0 ? part?[index + offset] ?? 0 : 0)
                        out[index] = 0 >= rest ? 0 : rest
                        index += 1
                    }
                }
            }
        }
        return result
    }

    /// The largest finite value among the last `count` of `values` (all of
    /// them by default), or 0 when there's none.
    public static func finitePeak(_ values: [Double], last count: Int = .max) -> Double {
        let end = values.count
        let start = count >= end ? 0 : end - count
        var peak = 0.0
        var found = false
        values.withUnsafeBufferPointer { buffer in
            guard let value = buffer.baseAddress else { return }
            var index = start
            while index < end {
                let candidate = value[index]
                if candidate.isFinite, !found || candidate > peak {
                    peak = candidate
                    found = true
                }
                index += 1
            }
        }
        return peak
    }

    private static func longest(_ series: [[Double]]) -> Int {
        var length = 0
        for values in series where values.count > length { length = values.count }
        return length
    }

    /// Adds `values` into the end of `sums`, which is at least as long, as a
    /// while loop over pointers (see `monotoneTangents`); with `floorsAtZero`,
    /// a negative value adds nothing.
    private static func addAligned(_ values: [Double], into sums: inout [Double], floorsAtZero: Bool) {
        let count = values.count
        let offset = sums.count - count
        values.withUnsafeBufferPointer { valueBuffer in
            sums.withUnsafeMutableBufferPointer { sumBuffer in
                guard let value = valueBuffer.baseAddress, let sum = sumBuffer.baseAddress else { return }
                var index = 0
                while index < count {
                    let added = value[index]
                    sum[offset + index] += floorsAtZero && 0 >= added ? 0 : added
                    index += 1
                }
            }
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

    /// Times to label on a time axis `width` points wide, whose labels are
    /// about `labelWidth` points wide: every `step` seconds, or a longer
    /// round step when that many labels wouldn't fit side by side with
    /// `spacing` between them, and none so near an end that its centred
    /// label would run past it. Fewer labels, never cut-off ones. Until the
    /// width is known it keeps 8% of the range clear at each end.
    public static func timeTicks(in range: ClosedRange<Date>, step: TimeInterval, width: Double, labelWidth: Double,
                                 spacing: Double = 14, calendar: Calendar = .current) -> [Date] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard width > 0, labelWidth > 0, span > 0 else { return timeTicks(in: range, step: step, margin: 0.08, calendar: calendar) }
        let fitting = max(Int((width + spacing) / (labelWidth + spacing)), 1)
        let step = max(step, timeTickStep(for: span, maximumTicks: fitting))
        let margin = min(max((labelWidth / 2 + 2) / width, 0.05), 0.5)
        return timeTicks(in: range, step: step, margin: margin, calendar: calendar)
    }

    // MARK: - History ranges

    /// The stretch a history graph spans, ending `end`: the whole `range`,
    /// or with `fit`, from the start of the first record in it to the last
    /// (`recorded`, each record covering `record` seconds), so a recording
    /// that began or had gaps inside the range fills the width. Never under
    /// `minimum` seconds or past the range. Fitting changes the axis, not
    /// the data: ten minutes of recording are labelled as ten minutes, and
    /// gaps in them stay gaps.
    public static func historyDomain(range: TimeInterval, end: Date, recorded: ClosedRange<Date>?, fit: Bool,
                                     record: TimeInterval = 10, minimum: TimeInterval = 60) -> ClosedRange<Date> {
        let start = end.addingTimeInterval(-range)
        guard fit, let recorded else { return start...end }
        let last = min(max(recorded.upperBound, start), end)
        let first = min(recorded.lowerBound.addingTimeInterval(-record), last.addingTimeInterval(-minimum))
        return max(first, start)...last
    }

    /// Whether the records in a history range (`recorded`) begin well inside
    /// it, more than 5% of the `range` after its start, so it opens on a
    /// stretch with nothing recorded.
    public static func recordingStartsLate(range: TimeInterval, end: Date, recorded: ClosedRange<Date>) -> Bool {
        recorded.lowerBound.timeIntervalSince(end.addingTimeInterval(-range)) > range * 0.05
    }
}
