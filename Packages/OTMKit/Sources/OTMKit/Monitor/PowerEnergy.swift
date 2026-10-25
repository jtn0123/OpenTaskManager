import Foundation

/// Energy integrates only measured stretches. A tick longer than a recorder
/// stretch may include sleep, so it cannot stand for watts throughout it.
public struct PowerEnergy: Sendable {
    public private(set) var joules = 0.0
    public private(set) var components: [PowerComponent: Double] = [:]
    public private(set) var seconds = 0.0

    public init() {}

    public var averageWatts: Double? { seconds > 0 ? joules / seconds : nil }

    public mutating func add(_ power: PowerSample, interval: TimeInterval) {
        guard interval > 0, interval <= FlightRecorder.span else { return }
        if let watts = power.systemWatts {
            joules += watts * interval
            seconds += interval
        }
        for component in PowerComponent.allCases {
            if let watts = power.components?.watts(component) { components[component, default: 0] += watts * interval }
        }
    }
}
