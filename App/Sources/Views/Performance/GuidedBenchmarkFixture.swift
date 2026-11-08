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
        let settling = watch(battery: battery)
        return settling.snapshot(now: settling.started.addingTimeInterval(30))
    }

    static func watch(battery: Bool) -> BenchmarkSettling {
        let started = Date(timeIntervalSince1970: 1_000)
        var settling = BenchmarkSettling(started: started)
        for index in 1...30 {
            settling.append(BenchmarkPreflightReading(date: started.addingTimeInterval(Double(index)), interval: 1, cpuBusy: 0.03,
                memoryPressure: .normal, thermal: battery ? .fair : .nominal, power: battery ? .battery : .ac, lowPowerMode: false))
        }
        return settling
    }

    static func runs(_ kind: BenchmarkKind) -> [BenchmarkRun]? {
        guard enabled, kind == .cpu || kind == .gpu else { return nil }
        if kind == .gpu { return gpuResults().map(BenchmarkRun.init) }
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

    /// The newest session is qualified; the oldest has verified counters, so gpu:1,3 shows both.
    static func gpuResults() -> [GPUBenchmarkResult] {
        let device = GPUBenchmarkDevice(name: "Made-up GPU", cores: 20, model: "FixtureMac", unifiedMemory: true,
                                        workingSetBytes: 32 << 30)
        return (0..<3).flatMap { group in
            (1...3).map { repeatIndex in
                let date = Date(timeIntervalSince1970: 1_790_000_000 + Double(group * 3_600 + repeatIndex * 60))
                let workloads = GPUWorkload.allCases.map { workload in
                    let rate = (workload == .compute ? 8e12 : workload == .memory ? 2e11 : 3e10) * (1 + Double(group) * 0.2)
                    let counter: GPUTimingEvidence.Interval? = workload == .fill && group != 2 ? .init(start: 10.001, end: 10.499) : nil
                    let evidence = GPUTimingEvidence(counterInterval: counter,
                        commandBufferInterval: .init(start: 10, end: 10.5), wallInterval: .init(start: 0, end: 0.501))
                    return GPUWorkloadResult(workload: workload, measurement: GPUBenchmarkMeasurement(
                        repeats: [rate * 0.99, rate, rate * 1.01], gpuSeconds: Array(repeating: counter?.seconds ?? 0.5, count: 3),
                        wallSeconds: [0.501, 0.501, 0.501], unitsPerRepeat: 40, timingEvidence: Array(repeating: evidence, count: 3)))
                }
                var result = GPUBenchmarkResult(date: date, suiteVersion: GPUBenchmark.suiteVersion, configuration: .standard,
                    device: device, osVersion: "macOS fixture", appVersion: "OpenTaskManager fixture", optimized: false,
                    thermalStateAtStart: .nominal, thermalStateAtEnd: .nominal, lowPowerMode: false, seconds: 9, workloads: workloads)
                result.session = BenchmarkSession(id: "fixture-\(group)", preflight: preflight(battery: group == 0), repeatIndex: repeatIndex)
                return result
            }
        }.sorted { $0.date > $1.date }
    }
}
