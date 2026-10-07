import Foundation

/// A figure the History page sums up over an interval and compares between two.
public enum HistoryMetric: String, Sendable, CaseIterable, Identifiable {
    case cpu
    case memory
    case gpu
    case power
    case diskRead
    case diskWrite
    case networkIn
    case networkOut

    public var id: String { rawValue }

    /// Its value in a record: the stretch's average. Nil where the Mac didn't report it.
    public func value(_ values: HistoryValues) -> Double? {
        switch self {
        case .cpu: values.cpu
        case .memory: values.memory
        case .gpu: values.gpu
        case .power: values.systemWatts
        case .diskRead: values.diskRead
        case .diskWrite: values.diskWrite
        case .networkIn: values.networkIn
        case .networkOut: values.networkOut
        }
    }

    /// Its peak in a record: CPU's busiest single update in the stretch;
    /// the rest, which keep only their stretch's average, that.
    public func peak(_ values: HistoryValues) -> Double? {
        self == .cpu ? values.cpuPeak : value(values)
    }

    /// A share from 0 to 1, whose change is in percentage points.
    public var isFraction: Bool {
        switch self {
        case .cpu, .memory, .gpu: true
        case .power, .diskRead, .diskWrite, .networkIn, .networkOut: false
        }
    }

    /// A rate whose total over time means something: bytes moved, or for
    /// power, energy (joules).
    public var accumulates: Bool { !isFraction }

    /// What the comparison shows for it: a share's average and peak; a
    /// throughput's total and peak rate; power's average and energy.
    public var statistics: [HistoryStatistic] {
        switch self {
        case .cpu, .memory, .gpu: [.average, .peak]
        case .power: [.average, .total]
        case .diskRead, .diskWrite, .networkIn, .networkOut: [.total, .peak]
        }
    }

    /// Its name as the History page's charts and moment panel give it.
    public var name: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .power: "Power"
        case .diskRead: "Disk read"
        case .diskWrite: "Disk write"
        case .networkIn: "Received"
        case .networkOut: "Sent"
        }
    }

    /// A row's name in a comparison: "CPU average", "Disk read total",
    /// "Energy" for power's total.
    public func title(_ statistic: HistoryStatistic) -> String {
        switch statistic {
        case .average: "\(name) average"
        case .peak: "\(name) peak"
        case .total: self == .power ? "Energy" : "\(name) total"
        }
    }

    /// A figure as the History page writes it: a share as a percentage, a
    /// rate per second (network in bits, as its chart), a total in bytes,
    /// energy in watt-hours.
    public func format(_ value: Double, _ statistic: HistoryStatistic) -> String {
        if isFraction { return Format.percent(value, digits: value < 0.1 ? 1 : 0) }
        if statistic == .total { return self == .power ? Self.energy(joules: value) : Format.bytes(value) }
        switch self {
        case .power: return Format.watts(value)
        case .networkIn, .networkOut: return Format.bitsPerSecond(value)
        case .cpu, .memory, .gpu, .diskRead, .diskWrite: return Format.bytesPerSecond(value)
        }
    }

    /// "12.3 Wh", "450 mWh", "1.25 kWh".
    static func energy(joules: Double) -> String {
        guard joules.isFinite, joules >= 0 else { return "—" }
        let hours = joules / 3_600
        if hours < 0.0005 { return "0 Wh" }
        if hours < 1 { return "\(Int((hours * 1_000).rounded())) mWh" }
        if hours < 1_000 { return "\(Format.fixed(hours, hours >= 10 ? 1 : 2)) Wh" }
        return "\(Format.fixed(hours / 1_000, 2)) kWh"
    }
}

/// The four figures a comparison leads with: CPU, memory, and disk and
/// network throughput with both directions added together.
public enum HistoryHeadline: String, Sendable, CaseIterable, Identifiable {
    case cpu
    case memory
    case disk
    case network

    public var id: String { rawValue }

    /// The figures it adds up.
    public var metrics: [HistoryMetric] {
        switch self {
        case .cpu: [.cpu]
        case .memory: [.memory]
        case .disk: [.diskRead, .diskWrite]
        case .network: [.networkIn, .networkOut]
        }
    }

    /// Its value in a record: its figures added up; nil when the record has none of them.
    public func value(_ values: HistoryValues) -> Double? {
        let parts = metrics.compactMap { $0.value(values) }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// Its peak in a record: CPU's busiest single update; the rest, their value.
    public func peak(_ values: HistoryValues) -> Double? {
        self == .cpu ? values.cpuPeak : value(values)
    }

    /// A share from 0 to 1, whose change is in percentage points.
    public var isFraction: Bool { metrics.allSatisfy(\.isFraction) }

    public var name: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        }
    }

    /// What it adds up, when that's more than one figure: "read and write".
    public var parts: String? {
        switch self {
        case .cpu, .memory: nil
        case .disk: "read and write"
        case .network: "received and sent"
        }
    }

    /// A figure as the History page writes it: a share as a percentage,
    /// disk in bytes and network in bits per second.
    public func format(_ value: Double) -> String {
        metrics[0].format(value, .average)
    }
}

/// How an interval's figure is summed up.
public enum HistoryStatistic: String, Sendable, CaseIterable {
    /// The mean over the recorded stretches.
    case average
    /// The highest recorded stretch (for CPU, the busiest update).
    case peak
    /// The rate times the recorded time: bytes, or joules for power.
    case total
}

/// What the flight recorder holds for one interval, gaps left out of every
/// figure: averages and peaks are over the recorded stretches alone, totals
/// count recorded time alone (nothing is guessed for the rest), and
/// `sampledSeconds` says how much time that was.
public struct HistoryIntervalStats: Sendable, Equatable {
    public struct Figure: Sendable, Equatable {
        public let average: Double
        public let peak: Double
        /// The rate summed over the recorded time; nil for a share.
        public let total: Double?

        public init(average: Double, peak: Double, total: Double?) {
            self.average = average
            self.peak = peak
            self.total = total
        }

        public func value(_ statistic: HistoryStatistic) -> Double? {
            switch statistic {
            case .average: average
            case .peak: peak
            case .total: total
            }
        }
    }

    public let start: Date
    public let end: Date
    /// Seconds of the interval with records: whole stretches, each counted
    /// once however many copies of the app wrote it.
    public let sampledSeconds: TimeInterval
    /// The figures the recording has in the interval; one the Mac never
    /// reported (GPU in a VM) is missing.
    public let figures: [HistoryMetric: Figure]
    /// The headline figures (`HistoryHeadline`), summed up the same way:
    /// disk's and network's peak is the busiest stretch for both directions
    /// together, not the two peaks added.
    public let headlines: [HistoryHeadline: Figure]

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    /// Seconds of the interval nothing was recorded: its gaps.
    public var unrecordedSeconds: TimeInterval { max(duration - sampledSeconds, 0) }

    /// Sums up `records` that end within `start` (excluded) to `end`, each
    /// covering `recordSeconds` up to its time. Records two copies of the
    /// app wrote for one stretch are averaged into one.
    public init(records: [HistoryRecord], from start: Date, to end: Date, recordSeconds: TimeInterval = FlightRecorder.span) {
        self.start = min(start, end)
        self.end = max(start, end)
        let span = max(recordSeconds, 1)
        var stretches: [Int: [HistoryValues]] = [:]
        for record in records where record.time > self.start && record.time <= self.end {
            stretches[Int((record.time.timeIntervalSince1970 / span).rounded(.down)), default: []].append(record.values)
        }
        sampledSeconds = min(Double(stretches.count) * span, self.end.timeIntervalSince(self.start))
        // Oldest first, so the sums come out the same every time.
        let ordered = stretches.sorted { $0.key < $1.key }.map(\.value)
        var figures: [HistoryMetric: Figure] = [:]
        for metric in HistoryMetric.allCases {
            figures[metric] = Self.figure(over: ordered, span: span, accumulates: metric.accumulates,
                                          value: metric.value, peak: metric.peak)
        }
        self.figures = figures
        var headlines: [HistoryHeadline: Figure] = [:]
        for headline in HistoryHeadline.allCases {
            headlines[headline] = Self.figure(over: ordered, span: span, accumulates: !headline.isFraction,
                                              value: headline.value, peak: headline.peak)
        }
        self.headlines = headlines
    }

    /// One figure over `stretches` (each the records of one `span`, oldest
    /// first): the mean of each stretch's average, the highest peak, and for
    /// a rate that `accumulates`, the total over the recorded time. Nil
    /// when no stretch has it.
    private static func figure(over stretches: [[HistoryValues]], span: TimeInterval, accumulates: Bool,
                               value: (HistoryValues) -> Double?, peak: (HistoryValues) -> Double?) -> Figure? {
        var sum = 0.0
        var count = 0
        var highest = -Double.infinity
        for copies in stretches {
            let values = copies.compactMap(value).filter(\.isFinite)
            guard !values.isEmpty else { continue }
            sum += values.reduce(0, +) / Double(values.count)
            count += 1
            highest = max(highest, copies.compactMap(peak).filter(\.isFinite).max() ?? -.infinity)
        }
        guard count > 0 else { return nil }
        let average = sum / Double(count)
        return Figure(average: average, peak: highest.isFinite ? highest : average, total: accumulates ? sum * span : nil)
    }
}

/// Two intervals of the History page side by side, A against B: each
/// figure's average, peak or total in both, and how A differs.
public struct HistoryComparison: Sendable, Equatable {
    /// A's figure against B's.
    public struct Change: Sendable, Equatable {
        public let a: Double
        public let b: Double
        /// A minus B: percentage points for a share (as a fraction), else the figure's unit.
        public var difference: Double { a - b }
        /// A over B; nil when B is zero.
        public var ratio: Double? { b != 0 ? a / b : nil }

        public init(a: Double, b: Double) {
            self.a = a
            self.b = b
        }

        /// How A differs, in a few characters: for a share, in percentage
        /// points ("+7.0 pts"); for the rest, relative to B ("+140%",
        /// "−35%", "×12"), or "from none" when B had none.
        public func label(isFraction: Bool) -> String {
            if isFraction {
                let points = difference * 100
                guard abs(points) >= 0.05 else { return "no change" }
                return Self.signed(points, digits: abs(points) < 10 ? 1 : 0) + " pts"
            }
            guard let ratio else { return a == 0 ? "no change" : "from none" }
            guard abs(ratio - 1) >= 0.0005 else { return "no change" }
            if ratio >= 10 { return "×" + Format.fixed(ratio, 0) }
            let percent = (ratio - 1) * 100
            return Self.signed(percent, digits: abs(percent) < 10 ? 1 : 0) + "%"
        }

        /// "+7.0", or with a true minus sign, "−3.5".
        private static func signed(_ value: Double, digits: Int) -> String {
            (value < 0 ? "\u{2212}" : "+") + Format.fixed(abs(value), digits)
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String { "\(metric.rawValue).\(statistic.rawValue)" }
        public let metric: HistoryMetric
        public let statistic: HistoryStatistic
        /// Nil where the interval has no record of the figure.
        public let a: Double?
        public let b: Double?
        /// Nil unless both have it.
        public var change: Change? {
            guard let a, let b else { return nil }
            return Change(a: a, b: b)
        }
    }

    /// An app's average CPU in each interval.
    public struct AppChange: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        /// Percent of one core, averaged over the interval's records (0 when it wasn't among the busiest).
        public let a: Double
        public let b: Double
    }

    /// A headline figure's average and peak in both intervals, for the
    /// summary a comparison leads with.
    public struct Headline: Sendable, Equatable, Identifiable {
        public var id: String { headline.rawValue }
        public let headline: HistoryHeadline
        /// Nil where the interval has no record of it.
        public let a: HistoryIntervalStats.Figure?
        public let b: HistoryIntervalStats.Figure?

        /// A's figure against B's, for `.average` or `.peak`; nil unless both have it.
        public func change(_ statistic: HistoryStatistic) -> Change? {
            guard let first = a?.value(statistic), let second = b?.value(statistic) else { return nil }
            return Change(a: first, b: second)
        }

        /// A figure as written, or "—" where the interval has none.
        public func text(_ figure: HistoryIntervalStats.Figure?, _ statistic: HistoryStatistic) -> String {
            figure?.value(statistic).map(headline.format) ?? "—"
        }

        /// How A differs from B, as `Change.label` puts it, or "—".
        public func changeText(_ statistic: HistoryStatistic) -> String {
            change(statistic)?.label(isFraction: headline.isFraction) ?? "—"
        }
    }

    public let a: HistoryIntervalStats
    public let b: HistoryIntervalStats
    /// Each figure either interval has, in `HistoryMetric` order.
    public let rows: [Row]
    /// CPU, memory, disk and network, those either interval has, in `HistoryHeadline` order.
    public let headlines: [Headline]

    public init(a: HistoryIntervalStats, b: HistoryIntervalStats) {
        self.a = a
        self.b = b
        rows = HistoryMetric.allCases.flatMap { metric -> [Row] in
            let first = a.figures[metric]
            let second = b.figures[metric]
            guard first != nil || second != nil else { return [] }
            return metric.statistics.map { statistic in
                Row(metric: metric, statistic: statistic, a: first?.value(statistic), b: second?.value(statistic))
            }
        }
        headlines = HistoryHeadline.allCases.compactMap { headline in
            let first = a.headlines[headline]
            let second = b.headlines[headline]
            guard first != nil || second != nil else { return nil }
            return Headline(headline: headline, a: first, b: second)
        }
    }

    /// The interval as long as `interval` that ends where it starts: what A
    /// is compared with until another is picked.
    public static func before(_ interval: ClosedRange<Date>) -> ClosedRange<Date> {
        let length = interval.upperBound.timeIntervalSince(interval.lowerBound)
        return interval.lowerBound.addingTimeInterval(-length)...interval.lowerBound
    }

    /// The apps whose average CPU rose most from B to A, at most `count`,
    /// leaving out rises under `threshold` percent of one core. Each
    /// interval's apps are its records' busiest (`HistoryRecord.topApps`),
    /// so an app missing from one counts as idle there.
    public static func busier(a: [HistoryApp], b: [HistoryApp], count: Int, threshold: Double = 1) -> [AppChange] {
        let before = Dictionary(b.map { ($0.name, $0.value) }, uniquingKeysWith: max)
        return a.map { AppChange(name: $0.name, a: $0.value, b: before[$0.name] ?? 0) }
            .filter { $0.a - $0.b >= threshold }
            .sorted { $0.a - $0.b == $1.a - $1.b ? $0.name < $1.name : $0.a - $0.b > $1.a - $1.b }
            .prefix(count)
            .map { $0 }
    }

    /// How many events of one kind each interval holds.
    public struct EventCount: Sendable, Equatable {
        public let kind: HistoryEvent.Kind
        public let a: Int
        public let b: Int
    }

    /// How many events of each kind each interval holds, counting the
    /// processes folded into one event; kinds neither has are left out.
    public static func eventCounts(a: [HistoryEvent], b: [HistoryEvent]) -> [EventCount] {
        func counts(_ events: [HistoryEvent]) -> [HistoryEvent.Kind: Int] {
            events.reduce(into: [:]) { $0[$1.kind, default: 0] += $1.count }
        }
        let first = counts(a)
        let second = counts(b)
        return HistoryEvent.Kind.allCases.compactMap { kind in
            let count = EventCount(kind: kind, a: first[kind] ?? 0, b: second[kind] ?? 0)
            return count.a + count.b > 0 ? count : nil
        }
    }
}

/// Lengths of time as the History page names its intervals.
public enum HistoryInterval {
    /// "10-second", "1-minute", "28-minute", "4-hour": what a moment's
    /// figures average over ("10-second average").
    public static func adjective(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let whole = max(Int(seconds.rounded()), 1)
        if whole % 3_600 == 0 { return "\(whole / 3_600)-hour" }
        if whole % 60 == 0 { return "\(whole / 60)-minute" }
        if whole < 120 { return "\(whole)-second" }
        if whole % 30 == 0 { return "\(whole / 60).5-minute" }
        if whole < 3_600 { return "\(whole)-second" }
        return "\(Int((seconds / 60).rounded()))-minute"
    }

    /// "20 min span · 11 min sampled": how long an interval is and how much
    /// of it the recorder holds.
    public static func coverage(span: TimeInterval, sampled: TimeInterval) -> String {
        "\(Format.roughDuration(span)) span · \(Format.roughDuration(min(sampled, span))) sampled"
    }

    /// What an interval's figures leave out: "9 min of gaps left out", "no
    /// gaps", or "nothing recorded". Less than a gap's worth unrecorded
    /// (`HistoryGap.spacing` records, which the graphs don't break for
    /// either) is a record's timing, not a gap.
    public static func leftOut(span: TimeInterval, sampled: TimeInterval, recordSeconds: TimeInterval = FlightRecorder.span) -> String {
        guard sampled > 0 else { return "nothing recorded" }
        let missing = max(span - sampled, 0)
        return missing < recordSeconds * HistoryGap.spacing ? "no gaps" : "\(Format.roughDuration(missing)) of gaps left out"
    }
}

/// Two intervals to compare as the History page opens, from
/// `-openHistoryCompare <minutesAgoA>,<lengthA>[,<minutesAgoB>,<lengthB>]`:
/// each starts that many minutes before the end of what the page shows (now,
/// or a recording file's end) and lasts its length, cut off at that end.
/// Without B, A is compared with the same length just before it.
public struct HistoryCompareRequest: Sendable, Equatable {
    public struct Interval: Sendable, Equatable {
        public let minutesAgo: Double
        public let minutes: Double

        /// The interval before `end`.
        public func range(before end: Date) -> ClosedRange<Date> {
            let start = end.addingTimeInterval(-minutesAgo * 60)
            return start...min(start.addingTimeInterval(minutes * 60), end)
        }
    }

    public let a: Interval
    /// Nil compares A with the same length before it.
    public let b: Interval?

    /// Reads "15,15" or "15,15,45,15"; nil for anything else, or a start or
    /// length that isn't a positive number of minutes.
    public init?(_ text: String) {
        let numbers = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 2 || numbers.count == 4 else { return nil }
        let values = numbers.compactMap { $0 }
        guard values.count == numbers.count, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        a = Interval(minutesAgo: values[0], minutes: values[1])
        b = values.count == 4 ? Interval(minutesAgo: values[2], minutes: values[3]) : nil
    }
}
