import Foundation

/// Where the mini monitor sits among windows (`Settings.miniMonitorLevel`).
public enum MiniMonitorLevel: String, CaseIterable, Sendable, Identifiable {
    /// Over every other window, full-screen apps' too.
    case aboveWindows
    /// A window like the others, which another can cover.
    case amongWindows
    /// On the desktop, under every window but over its icons and widgets.
    case desktop

    public var id: Self { self }

    public var title: String {
        switch self {
        case .aboveWindows: "Above other windows"
        case .amongWindows: "Among other windows"
        case .desktop: "On the desktop"
        }
    }
}

/// A reading the mini monitor can show, in the order it shows them.
public enum MiniMonitorMeter: String, CaseIterable, Sendable, Identifiable {
    case cpu, memory, gpu, network, disk, power

    public var id: Self { self }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .disk: "Disk"
        case .power: "Power"
        }
    }
}

/// The meters picked for the mini monitor (`Settings.miniMonitorMeters`),
/// never none. A Mac that doesn't give a reading (a GPU's load, power)
/// leaves its meter out whatever is picked.
public struct MiniMonitorMeters: RawRepresentable, Equatable, Sendable {
    public private(set) var meters: Set<MiniMonitorMeter>

    public static let all = MiniMonitorMeters(meters: Set(MiniMonitorMeter.allCases))

    /// `meters`, or all of them for none.
    public init(meters: Set<MiniMonitorMeter>) {
        self.meters = meters.isEmpty ? Set(MiniMonitorMeter.allCases) : meters
    }

    public init?(rawValue: String) {
        let meters = Set(rawValue.split(separator: ",").compactMap { MiniMonitorMeter(rawValue: String($0)) })
        guard !meters.isEmpty else { return nil }
        self.init(meters: meters)
    }

    public var rawValue: String {
        shown.map(\.rawValue).joined(separator: ",")
    }

    /// The picked meters in showing order.
    public var shown: [MiniMonitorMeter] {
        MiniMonitorMeter.allCases.filter(meters.contains)
    }

    public func contains(_ meter: MiniMonitorMeter) -> Bool {
        meters.contains(meter)
    }

    /// Picks `meter`, or unpicks it unless it's the last.
    public mutating func toggle(_ meter: MiniMonitorMeter) {
        if meters.contains(meter) {
            if meters.count > 1 { meters.remove(meter) }
        } else {
            meters.insert(meter)
        }
    }
}
