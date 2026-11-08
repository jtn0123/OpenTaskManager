import Foundation

/// Time above the media block's minimum power state, not throughput or
/// utilization. Each channel is independent; their percentages do not add up.
public struct MediaEngineSample: Sendable, Codable, Equatable, Identifiable {
    public let channel: String
    public let activeFraction: Double
    public var id: String { channel }
    public var label: String { MediaEngineChannel(channel)?.label ?? channel }
    public var rank: Int { MediaEngineChannel(channel)?.rank ?? 999 }

    public init(channel: String, activeFraction: Double) {
        self.channel = channel
        self.activeFraction = activeFraction
    }

    public static let explanation = "Time above each block's minimum power state. This shows power-state activity, "
        + "not throughput or how much work its full capacity could handle. Blocks can run together."
}

/// Only known media domains; other SoC floors (CPU, display, memory, etc.)
/// must not become media readings merely because they have the same states.
struct MediaEngineChannel {
    let label: String
    let rank: Int

    init?(_ channel: String) {
        let families: [(String, String)] = [
            ("AVE", "Video encode"), ("AVD", "Video decode"), ("PRORES", "ProRes"),
            ("MSR", "Media scaler"), ("JPEG", "JPEG"), ("SCODEC", "SCODEC"),
        ]
        for (index, family) in families.enumerated() where channel.hasPrefix(family.0) {
            let suffix = channel.dropFirst(family.0.count)
            guard suffix.isEmpty || (suffix.allSatisfy({ $0.isASCII && $0.isNumber }) && Int(suffix).map { $0 < 16 } == true) else { continue }
            label = family.1 + (suffix.isEmpty ? "" : " \(suffix)")
            rank = index * 16 + (Int(suffix) ?? 0)
            return
        }
        return nil
    }

    static func sample(_ channel: IOReportChannel) -> MediaEngineSample? {
        guard channel.group == "PMP0", channel.subgroup == "SOC Floor", MediaEngineChannel(channel.name) != nil,
              case .states(let states) = channel.value, let active = activeFraction(states) else { return nil }
        return MediaEngineSample(channel: channel.name, activeFraction: active)
    }

    /// M5 Pro SOC Floor states are VMIN, VNOM, VMAX and VOVD. A channel
    /// with no advancing residency (including several published ProRes and
    /// secondary channels) is missing, never an invented zero-percent engine.
    static func activeFraction(_ states: [IOReportChannel.State]) -> Double? {
        guard states.contains(where: { $0.name == "VMIN" }),
              states.allSatisfy({ $0.residency >= 0 }),
              states.allSatisfy({ $0.residency == 0 || ["VMIN", "VNOM", "VMAX", "VOVD"].contains($0.name) }) else { return nil }
        let total = states.reduce(0.0) { $0 + Double($1.residency) }
        guard total > 0, total.isFinite else { return nil }
        let active = states.filter { $0.name != "VMIN" }.reduce(0.0) { $0 + Double($1.residency) }
        return active / total
    }
}

/// A timer-free gate shared by live display and background recording. The
/// power manager does expensive work for this channel group, so it has its
/// own subscription and never joins the every-tick CPU/GPU read.
struct MediaEngineCadence {
    private var last: TimeInterval?

    mutating func shouldRead(at time: TimeInterval, live: Bool) -> Bool {
        guard time.isFinite, last.map({ time < $0 || time - $0 >= (live ? 2 : 5) }) ?? true else { return false }
        last = time
        return true
    }
}
