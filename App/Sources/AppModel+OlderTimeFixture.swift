#if DEBUG
import Foundation
import OTMKit

/// A made-up hour and ten minutes of older time behind the live window, for
/// screenshots of squeezed graphs (`-olderTimeFixture YES`, debug builds):
/// a quiet wander with short bursts, a long busy stretch, ten minutes asleep
/// and a shorter busy stretch, each line scaled to suit its kind or from its
/// first real reading. Older time is never saved, so it records nothing.
@MainActor
enum OlderTimeFixture {
    static let enabled = LaunchArgument.string("olderTimeFixture") == "YES"
    /// Samples of made-up time, oldest first.
    static let samples = 4_200
    /// Where the Mac slept, in samples from the start.
    static let asleep = 1_500..<2_100

    /// How busy the made-up time is `sample` samples in, 0 to 1.
    static func load(_ sample: Int) -> Double {
        let time = Double(sample)
        var load = 0.16 + 0.08 * sin(time / 300) + 0.04 * sin(time * 1.7) * sin(time / 23)
        if (600..<960).contains(sample) { load = 0.82 + 0.1 * sin(time / 9) }
        if (2_700..<2_820).contains(sample) { load = 0.68 + 0.05 * sin(time / 5) }
        if sample % 370 < 18 { load += 0.35 }
        return min(max(load, 0), 1)
    }

    /// `series`' made-up reading at `load`, from its real reading `now`.
    static func value(_ series: OlderSeries, now: Double, load: Double) -> Double {
        switch series {
        case .cpu, .tier: load
        case .cpuSystem, .tierKernel: load * 0.28
        case .memoryApp, .memoryWired, .memoryCompressed, .memoryCached: now * (0.88 + 0.24 * load)
        case .memoryPressure: 0.18 + 0.3 * load
        case .gpuBusy: load * 0.6
        case .gpuRenderer: load * 0.5
        case .gpuTiler: load * 0.2
        case .gpuMemory: now * (0.8 + 0.4 * load)
        case .diskActive: load * 0.5
        case .diskRead: load * 80_000_000
        case .diskWrite: load * 30_000_000
        case .networkIn: load * 6_000_000
        case .networkOut: load * 900_000
        case .power: 4 + 24 * load
        case .powerPart(.cpu): 14 * load
        case .powerPart(.gpu): 4 * load
        case .powerPart: 0.3 + 0.6 * load
        case .powerRest: 2 + load
        case .thermalPressure: load > 0.75 ? 1.0 / 3 : 0
        case .hottest(.chip): 42 + 45 * load
        case .hottest: 34 + 9 * load
        case .chipAverage: 38 + 32 * load
        }
    }
}

extension AppModel {
    /// Puts `OlderTimeFixture`'s made-up time into older time, for the
    /// lines `snapshot` has.
    func fillOlderTimeFixture(_ snapshot: SystemSnapshot, sensors: SensorSample?) {
        var readings: [(OlderSeries, Double)] = []
        forEachOlderReading(snapshot, sensors: sensors) { readings.append(($0, $1)) }
        var sample = 0
        while sample < OlderTimeFixture.samples {
            if sample == OlderTimeFixture.asleep.lowerBound {
                olderTime.gap(samples: OlderTimeFixture.asleep.count)
                sample = OlderTimeFixture.asleep.upperBound
                continue
            }
            let load = OlderTimeFixture.load(sample)
            olderTime.startTick()
            for (series, now) in readings {
                olderTime.add(OlderTimeFixture.value(series, now: now, load: load), for: series)
            }
            olderTime.finishTick()
            sample += 1
        }
    }
}
#endif
