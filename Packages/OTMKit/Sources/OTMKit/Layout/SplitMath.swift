import Foundation

/// Width maths for a list with an inspector pane beside it.
public enum SplitMath {
    /// Width of an inspector beside a list that needs `listMinimum` points,
    /// in a container `available` wide: the `preferred` width kept between
    /// `minimum` and `maximum`, but never so wide the list drops below its
    /// minimum. Nil when both don't fit even at their minimums, so the
    /// inspector has to take the whole width instead.
    public static func inspectorWidth(
        available: Double,
        listMinimum: Double,
        preferred: Double,
        minimum: Double,
        maximum: Double,
        divider: Double = 1
    ) -> Double? {
        let room = available - listMinimum - divider
        guard room >= minimum else { return nil }
        return min(max(preferred, minimum), maximum, room)
    }
}
