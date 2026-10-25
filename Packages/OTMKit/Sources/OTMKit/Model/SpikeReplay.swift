import Foundation

/// Where a spike capture's replay opens and where its triggers fall on a
/// chart. A capture opens at its first trigger rather than its end, where
/// the spike has passed; other recordings (no incident) still open at the end.
public enum SpikeReplay {
    public static func openingMoment(incident: SpikeIncident?) -> Date? {
        incident?.primary.time
    }

    public struct Marker: Sendable, Equatable {
        public let trigger: SpikeTrigger
        /// Across the plot, from zero at its start to one at its end.
        public let fraction: Double
    }

    /// Only triggers within the chart's range get a rule. Fractions let
    /// charts of different widths line up without reading the playhead.
    public static func markers(incident: SpikeIncident?, within range: ClosedRange<Date>) -> [Marker] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard let incident, span > 0, span.isFinite else { return [] }
        return incident.triggers.filter { range.contains($0.time) }.map {
            Marker(trigger: $0, fraction: $0.time.timeIntervalSince(range.lowerBound) / span)
        }
    }
}
