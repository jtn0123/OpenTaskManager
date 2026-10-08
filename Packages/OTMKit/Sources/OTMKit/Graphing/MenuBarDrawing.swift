import Foundation

/// Only the pixels the template icon draws, so subpixel CPU changes never
/// publish a new status item. Half points fit the finest menu bar scale (2×).
public struct MenuBarDrawing: Equatable, Sendable {
    public static let bars = 14
    public let heights: [Double]
    public let text: String

    public init(history: [Double], usage: Double) {
        heights = history.suffix(Self.bars).map {
            let fraction = $0.isFinite ? min(max($0, 0), 1) : 0
            return max(1, (fraction * 14 * 2).rounded() / 2)
        }
        text = Format.percent(usage)
    }
}

/// The icon alone shows the newest sample at most once every two seconds.
/// Its graph still covers consecutive samples, and the rest of the app
/// keeps the chosen update speed.
public struct MenuBarDrawingCadence: Sendable {
    private var cadence = SamplingCadence(idleInterval: 2)
    public private(set) var drawing = MenuBarDrawing(history: [], usage: 0)

    public init() {}

    public mutating func update(history: @autoclosure () -> [Double], usage: Double, at time: TimeInterval) -> MenuBarDrawing? {
        guard cadence.shouldRead(at: time, live: false) else { return nil }
        let next = MenuBarDrawing(history: history(), usage: usage)
        guard next != drawing else { return nil }
        drawing = next
        return next
    }
}
