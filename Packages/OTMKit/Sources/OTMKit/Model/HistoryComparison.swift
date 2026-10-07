import Foundation

/// A figure the History page sums up over an interval and compares between
/// two: one of the whole-system figures every record has, the hottest die,
/// or a hardware series (`HistoryHardwareSeries`) the recording holds.
public struct HistoryMetric: Sendable, Hashable, Identifiable, CaseIterable {
    /// What the figure is read from.
    enum Source: Sendable, Hashable {
        case cpu, memory, gpu, power, diskRead, diskWrite, networkIn, networkOut, chipTemperature
        case hardware(HistoryHardwareSeries)
    }

    /// "cpu", "chipTemperature", or "hardware." and the series' ID.
    public let rawValue: String
    let source: Source

    public var id: String { rawValue }

    public static let cpu = Self(rawValue: "cpu", source: .cpu)
    public static let memory = Self(rawValue: "memory", source: .memory)
    public static let gpu = Self(rawValue: "gpu", source: .gpu)
    public static let power = Self(rawValue: "power", source: .power)
    public static let diskRead = Self(rawValue: "diskRead", source: .diskRead)
    public static let diskWrite = Self(rawValue: "diskWrite", source: .diskWrite)
    public static let networkIn = Self(rawValue: "networkIn", source: .networkIn)
    public static let networkOut = Self(rawValue: "networkOut", source: .networkOut)
    /// The hottest die sensor.
    public static let chipTemperature = Self(rawValue: "chipTemperature", source: .chipTemperature)

    /// The figures every recording may have, in the order a comparison lists
    /// them; hardware series follow in chart order.
    public static let allCases: [HistoryMetric] = [
        .cpu, .memory, .gpu, .power, .diskRead, .diskWrite, .networkIn, .networkOut, .chipTemperature,
    ]

    private init(rawValue: String, source: Source) {
        self.rawValue = rawValue
        self.source = source
    }

    /// A hardware series as a figure to sum up.
    public static func hardware(_ series: HistoryHardwareSeries) -> HistoryMetric {
        HistoryMetric(rawValue: "hardware.\(series.id)", source: .hardware(series))
    }

    /// The hardware series behind it, if it's one.
    public var series: HistoryHardwareSeries? {
        if case .hardware(let series) = source { return series }
        return nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }

    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    /// Where it sorts in a comparison: the whole-system figures first, then
    /// the hardware series in chart order.
    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.series, rhs.series) {
        case let (left?, right?): left < right
        case (nil, .some): true
        case (.some, nil): false
        case (nil, nil): (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
        }
    }

    /// Its value in a record: the stretch's average. Nil where the Mac didn't report it.
    public func value(_ values: HistoryValues) -> Double? {
        switch source {
        case .cpu: values.cpu
        case .memory: values.memory
        case .gpu: values.gpu
        case .power: values.systemWatts
        case .diskRead: values.diskRead
        case .diskWrite: values.diskWrite
        case .networkIn: values.networkIn
        case .networkOut: values.networkOut
        case .chipTemperature: values.chipCelsius
        case .hardware(let series): values.hardware[series.id]
        }
    }

    /// Its peak in a record: CPU's busiest single update in the stretch;
    /// the rest, which keep only their stretch's average, that.
    public func peak(_ values: HistoryValues) -> Double? {
        self == .cpu ? values.cpuPeak : value(values)
    }

    /// A share from 0 to 1, whose change is in percentage points.
    public var isFraction: Bool {
        switch source {
        case .cpu, .memory, .gpu: true
        case .power, .diskRead, .diskWrite, .networkIn, .networkOut, .chipTemperature: false
        case .hardware(let series): series.unit == .fraction
        }
    }

    /// A rate whose total over time means something: bytes moved, or for
    /// power, energy (joules).
    public var accumulates: Bool {
        switch source {
        case .power, .diskRead, .diskWrite, .networkIn, .networkOut: true
        case .cpu, .memory, .gpu, .chipTemperature: false
        case .hardware(let series): series.unit == .watts
        }
    }

    /// A temperature, whose change is in degrees, not relative.
    var isTemperature: Bool {
        source == .chipTemperature || series?.unit == .celsius
    }

    /// What the comparison shows for it: a share's average and peak; a
    /// throughput's total and peak rate; power's average and energy; the
    /// hottest die's average and peak; a hardware series' average, and the
    /// busiest core's peak too.
    public var statistics: [HistoryStatistic] {
        switch source {
        case .cpu, .memory, .gpu, .chipTemperature: [.average, .peak]
        case .power: [.average, .total]
        case .diskRead, .diskWrite, .networkIn, .networkOut: [.total, .peak]
        case .hardware(let series): series.id == HistoryHardwareSeries.busiestCore ? [.average, .peak] : [.average]
        }
    }

    /// Its name as the History page's charts and moment panel give it.
    public var name: String {
        switch source {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .power: "Power"
        case .diskRead: "Disk read"
        case .diskWrite: "Disk write"
        case .networkIn: "Received"
        case .networkOut: "Sent"
        case .chipTemperature: "Hottest die"
        case .hardware(let series): Self.name(of: series)
        }
    }

    /// A hardware series' name out of its chart: "Fan 1 speed", "GPU clock",
    /// "SSD temperature", "Neural Engine power".
    static func name(of series: HistoryHardwareSeries) -> String {
        switch series.kind {
        case .load: series.label
        case .clock: "\(series.label) clock"
        case .temperature: series.label.hasSuffix(" die") ? series.label : "\(series.label) temperature"
        case .fan: "\(series.label) speed"
        case .power: "\(series.label) power"
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
    /// energy in watt-hours, a hardware series in its unit.
    public func format(_ value: Double, _ statistic: HistoryStatistic) -> String {
        if isFraction { return Format.percent(value, digits: value < 0.1 ? 1 : 0) }
        if statistic == .total, accumulates { return series != nil || self == .power ? Self.energy(joules: value) : Format.bytes(value) }
        switch source {
        case .power: return Format.watts(value)
        case .networkIn, .networkOut: return Format.bitsPerSecond(value)
        case .chipTemperature: return SensorUnit.celsius.format(value)
        case .hardware(let series): return series.unit == .watts ? Format.watts(value) : series.unit.format(value)
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
    /// The figures it has, in the order a comparison lists them.
    public let metrics: [HistoryMetric]

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    /// Seconds of the interval nothing was recorded: its gaps.
    public var unrecordedSeconds: TimeInterval { max(duration - sampledSeconds, 0) }

    /// Sums up `records` that end within `start` (excluded) to `end`, each
    /// covering `recordSeconds` up to its time. Records two copies of the
    /// app wrote for one stretch are averaged into one. `hardware` names
    /// the hardware series to sum up; nil takes the records' own.
    public init(records: [HistoryRecord], from start: Date, to end: Date, recordSeconds: TimeInterval = FlightRecorder.span,
                hardware: [HistoryHardwareSeries]? = nil) {
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
        let series = hardware ?? Set(records.flatMap(\.hardwareSeries)).sorted()
        let candidates = HistoryMetric.allCases + series.map(HistoryMetric.hardware)
        for metric in candidates {
            var sum = 0.0
            var count = 0
            var peak = -Double.infinity
            for copies in ordered {
                let values = copies.compactMap { metric.value($0) }.filter(\.isFinite)
                guard !values.isEmpty else { continue }
                sum += values.reduce(0, +) / Double(values.count)
                count += 1
                peak = max(peak, copies.compactMap { metric.peak($0) }.filter(\.isFinite).max() ?? -.infinity)
            }
            guard count > 0 else { continue }
            figures[metric] = Figure(average: sum / Double(count), peak: peak.isFinite ? peak : sum / Double(count),
                                     total: metric.accumulates ? sum * span : nil)
        }
        self.figures = figures
        metrics = candidates.filter { figures[$0] != nil }
    }
}

/// Two intervals of the History page side by side, A against B: each
/// figure's average, peak or total in both, and how A differs.
public struct HistoryComparison: Sendable, Equatable {
    /// A's figure against B's.
    public struct Change: Sendable, Equatable {
        public let a: Double
        public let b: Double
        /// For a temperature, the unit its difference is given in ("+4.1 °C"),
        /// since a ratio of temperatures means nothing.
        public var absoluteUnit: SensorUnit?
        /// A minus B: percentage points for a share (as a fraction), else the figure's unit.
        public var difference: Double { a - b }
        /// A over B; nil when B is zero.
        public var ratio: Double? { b != 0 ? a / b : nil }

        public init(a: Double, b: Double, absoluteUnit: SensorUnit? = nil) {
            self.a = a
            self.b = b
            self.absoluteUnit = absoluteUnit
        }

        /// How A differs, in a few characters: for a share, in percentage
        /// points ("+7.0 pts"); for a temperature, in degrees ("+4.1 °C");
        /// for the rest, relative to B ("+140%", "−35%", "×12"), or "from
        /// none" when B had none.
        public func label(isFraction: Bool) -> String {
            if let absoluteUnit {
                guard abs(difference) >= 0.05 else { return "no change" }
                return Self.signed(difference, digits: 1) + " " + absoluteUnit.symbol
            }
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
            return Change(a: a, b: b, absoluteUnit: metric.isTemperature ? .celsius : nil)
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

    public let a: HistoryIntervalStats
    public let b: HistoryIntervalStats
    /// Each figure either interval has: the whole-system ones in
    /// `HistoryMetric` order, then the hardware series in chart order.
    public let rows: [Row]

    public init(a: HistoryIntervalStats, b: HistoryIntervalStats) {
        self.a = a
        self.b = b
        let metrics = (a.metrics + b.metrics.filter { a.figures[$0] == nil }).sorted(by: HistoryMetric.precedes)
        rows = metrics.flatMap { metric -> [Row] in
            let first = a.figures[metric]
            let second = b.figures[metric]
            guard first != nil || second != nil else { return [] }
            return metric.statistics.map { statistic in
                Row(metric: metric, statistic: statistic, a: first?.value(statistic), b: second?.value(statistic))
            }
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
}
