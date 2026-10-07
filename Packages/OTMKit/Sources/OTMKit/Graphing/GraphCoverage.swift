import Foundation

/// How much of a live graph's window holds samples. Until the window fills,
/// the graph shades the part before recording started, so it isn't read as
/// a stretch of zeros, and says how much it has collected.
public struct GraphCoverage: Equatable, Sendable {
    /// Samples the graph has.
    public var samples: Int
    /// Samples across the graph's full width.
    public var capacity: Int
    /// Seconds between samples.
    public var interval: TimeInterval

    public init(samples: Int, capacity: Int, interval: TimeInterval) {
        self.samples = max(samples, 0)
        self.capacity = max(capacity, 1)
        self.interval = interval.isFinite ? max(interval, 0) : 0
    }

    /// Every position across the graph has a sample.
    public var isFull: Bool { samples >= capacity }

    /// Seconds collected, rounded down to a step that grows with them (each
    /// sample for the first 10 s, then 5 s, 15 s past a minute and whole
    /// minutes past ten), so a caption changes every few samples rather
    /// than on every one.
    public var collectedSeconds: TimeInterval {
        let seconds = Double(samples) * interval
        let step: TimeInterval = seconds < 10 ? 0 : seconds < 60 ? 5 : seconds < 600 ? 15 : 60
        return step > 0 ? (seconds / step).rounded(.down) * step : seconds
    }

    /// "45 s collected", while the window is filling. Nil before the first
    /// sample and once the window is full.
    public var shortCaption: String? {
        guard samples > 0, !isFull, interval > 0 else { return nil }
        return "\(Format.timeSpan(collectedSeconds)) collected"
    }

    /// "45 s collected · 5-minute window", while the window is filling.
    public var caption: String? {
        shortCaption.map { "\($0) · \(Self.window(Double(capacity) * interval))" }
    }

    /// "5-minute window", "30-second window", or "2 min 30 s window" for a
    /// span that isn't a whole number of one unit.
    static func window(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        guard Double(whole) == seconds, whole > 0 else { return "\(Format.timeSpan(seconds)) window" }
        if whole % 3600 == 0 { return "\(whole / 3600)-hour window" }
        if whole % 60 == 0 { return "\(whole / 60)-minute window" }
        if whole < 60 { return "\(whole)-second window" }
        return "\(Format.timeSpan(seconds)) window"
    }
}
