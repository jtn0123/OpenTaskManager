import Foundation
import OTMKit

/// Read-only envelopes for screenshots, made without calling a benchmark or history writer.
@MainActor
enum GuidedBenchmarkFixture {
    static var enabled: Bool {
        #if DEBUG
        LaunchArgument.string("guidedFixture") == "YES" || LaunchArgument.string("sustainedFixture") == "YES"
        #else
        false
        #endif
    }

    static func preflight(battery: Bool) -> BenchmarkPreflight {
        let started = Date(timeIntervalSince1970: 1_000)
        var settling = BenchmarkSettling(started: started)
        for index in 1...30 {
            settling.append(BenchmarkPreflightReading(date: started.addingTimeInterval(Double(index)), interval: 1, cpuBusy: 0.03,
                memoryPressure: .normal, thermal: battery ? .fair : .nominal, power: battery ? .battery : .ac, lowPowerMode: false))
        }
        return settling.snapshot(now: started.addingTimeInterval(30))
    }

    static func runs(_ kind: BenchmarkKind) -> [BenchmarkRun]? {
        guard enabled, kind == .cpu || kind == .gpu else { return nil }
        return (0..<3).flatMap { group in
            (1...3).map { repeatIndex in
                let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(group * 3_600 + repeatIndex * 60))
                let value = Double(100 + group * 20 + repeatIndex * 2) * 1e6
                var run = BenchmarkRun(id: "fixture-\(kind.rawValue)-\(group)-\(repeatIndex)", kind: kind, date: date,
                    workloadVersion: 1, settings: [], build: BenchmarkBuild(app: "OpenTaskManager fixture", optimized: false),
                    machine: BenchmarkMachine(key: "fixture", name: "Made-up Mac"), target: nil, osVersion: nil, conditions: [],
                    measurements: [BenchmarkMeasurement(id: kind == .cpu ? "floatingPoint.multi" : "compute",
                        name: "Floating point", value: value, unit: .flopsPerSecond, low: value * 0.99, high: value * 1.01, repeats: 3)])
                run.session = BenchmarkSession(id: "fixture-\(group)", preflight: preflight(battery: group == 0), repeatIndex: repeatIndex)
                return run
            }
        }
    }
}
