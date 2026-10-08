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

    /// "45 s collected · 5 min window", while the window is filling: the
    /// graph's one note on its unrecorded stretch, at its foot.
    public var caption: String? {
        shortCaption.map { "\($0) · \(Self.window(Double(capacity) * interval))" }
    }

    /// The caption as VoiceOver reads it, saying what the shaded stretch is.
    public var spokenCaption: String? {
        caption.map { "\($0). Not recorded before that." }
    }

    /// "5 min window", "30 s window", "2 min 30 s window": in the time axis's units.
    static func window(_ seconds: TimeInterval) -> String {
        "\(Format.timeSpan(seconds)) window"
    }
}

// MARK: - Fitting a filling window

extension GraphCoverage {
    /// The windows a fitted graph steps through, in thirtieths of the full
    /// one: 10, 20, 30, 40 and 60 s of a 5-minute window over the first
    /// minute, then every 30 s.
    static let fitSteps = [1, 2, 3, 4, 6, 9, 12, 15, 18, 21, 24, 27, 30]

    /// Samples across graphs fitted to the `samples` collected so far, out
    /// of a full window of `span`: the first step that holds them all.
    ///
    /// A step rather than the count itself, so the graphs keep scrolling
    /// between samples, and their window, axis and caption change every
    /// 30 s at most. Past the first step, what's collected fills at least
    /// half the width. Never under 2, never over `span`.
    public static func fittedCapacity(samples: Int, span: Int) -> Int {
        fittedCapacity(samples: samples, span: span, steps: fitSteps, of: 30)
    }

    /// The windows a short graph (the Overview's two minutes) steps through,
    /// in 24ths of the full one: 10, 20, 30 and 45 s, then 1, 1.5 and 2 min.
    /// Fewer, rounder steps than `fitSteps`, as its window fills in two
    /// minutes and each step relabels every graph on the page.
    static let shortFitSteps = [2, 4, 6, 9, 12, 18, 24]

    /// Samples across a short graph that always fits what's been collected,
    /// as the Overview's do: `fittedCapacity` in `shortFitSteps`. Past the
    /// first step, what's collected fills at least half the width.
    public static func shortFittedCapacity(samples: Int, span: Int) -> Int {
        fittedCapacity(samples: samples, span: span, steps: shortFitSteps, of: 24)
    }

    /// The first of `steps`, each that many `of`ths of `span`, that holds
    /// `samples`. Never under 2, never over `span`.
    private static func fittedCapacity(samples: Int, span: Int, steps: [Int], of parts: Int) -> Int {
        let span = max(span, 2)
        for step in steps {
            let capacity = max(Int((Double(span * step) / Double(parts)).rounded()), 2)
            if capacity >= samples { return min(capacity, span) }
        }
        return span
    }

    /// Whether fitting changes anything: true while a window shorter than
    /// `span` holds every sample collected.
    public static func canFit(samples: Int, span: Int) -> Bool {
        fittedCapacity(samples: samples, span: span) < max(span, 2)
    }
}
