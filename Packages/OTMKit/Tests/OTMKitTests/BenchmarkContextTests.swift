import Foundation
@testable import OTMKit
import Testing

// MARK: - Fixtures

private let machine = CPUBenchmarkMachine(chip: "Apple M5 Pro", model: "Mac17,8", logicalCores: 18,
                                          coreTypes: [.init(name: "Super", cores: 6), .init(name: "Performance", cores: 12)],
                                          memoryBytes: 48 << 30)

private func context(power: BenchmarkPowerSource? = .ac, battery: Bool? = true, thermal: ThermalState? = .nominal, busy: Double? = 0.04,
                     available: UInt64? = 20 << 30, model: String? = "Mac17,8", chip: String? = "Apple M5 Pro",
                     optimized: Bool? = true, app: String? = "OpenTaskManager 0.1.0") -> BenchmarkContext {
    BenchmarkContext(osVersion: "macOS 27.2 (27C61)", appVersion: app, optimized: optimized, model: model, chip: chip, power: power,
                     hasBattery: battery, lowPowerMode: false, thermalAtStart: thermal, thermalAtEnd: thermal,
                     cpuLoad: busy.map { BenchmarkCPULoad(busy: $0, seconds: 5, source: .sampler) }, availableMemoryBytes: available,
                     physicalMemoryBytes: 48 << 30)
}

private func cpu(at time: TimeInterval, context: BenchmarkContext? = nil) -> CPUBenchmarkResult {
    let workloads = CPUWorkload.allCases.map {
        CPUWorkloadResult(workload: $0, single: CPUBenchmarkMeasurement(workers: 1, repeats: [10, 11, 9]),
                          multi: CPUBenchmarkMeasurement(workers: 18, repeats: [120, 100, 110]))
    }
    var result = CPUBenchmarkResult(date: Date(timeIntervalSince1970: time), suiteVersion: 1, configuration: .standard, machine: machine,
                                    osVersion: "macOS 27.2 (27C61)", appVersion: "OpenTaskManager 0.1.0", optimized: true,
                                    thermalStateAtStart: .nominal, thermalStateAtEnd: .nominal, lowPowerMode: false, seconds: 21,
                                    workloads: workloads)
    result.context = context
    return result
}

private func disk(at time: TimeInterval, context: BenchmarkContext? = nil) -> DiskSpeedResult {
    let sequential = DiskSpeedMeasurement(bytes: 1 << 30, operations: 1024, seconds: 0.5)
    let random = DiskSpeedMeasurement(bytes: 4096 * 30000, operations: 30000, seconds: 3)
    var result = DiskSpeedResult(date: Date(timeIntervalSince1970: time),
                                 volume: DiskSpeedVolume(name: "Macintosh HD", mountPoint: "/", fileSystem: "apfs", uuid: "A19F"),
                                 folder: "/tmp", configuration: DiskSpeedConfiguration(fileSize: 1 << 30, seed: 7), freeBytes: 100 << 30,
                                 bypassedCache: true, fullFlush: true, sequentialWrite: sequential, sequentialRead: sequential,
                                 randomWrite: random, randomRead: random)
    result.context = context
    return result
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("otm-context-\(UUID().uuidString)", isDirectory: true)
}

private func warnings(_ earlier: BenchmarkContext?, _ later: BenchmarkContext?, build: Bool = false,
                      machine: Bool = false) -> [BenchmarkContextWarning] {
    BenchmarkContext.warnings(earlier: earlier, later: later, runsRecordBuild: build, runsRecordMachine: machine)
}

// MARK: - Old files and lenient reading

struct BenchmarkContextDecodingTests {
    @Test func aRunSavedBeforeContextsLoadsWithoutOne() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A history entry exactly as an earlier app wrote it: no context key.
        var entry = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(cpu(at: 100))) as? [String: Any])
        entry["context"] = nil
        let file = folder.appendingPathComponent("cpu-benchmark.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = try JSONSerialization.data(withJSONObject: ["version": 1, "results": [entry]])
        try old.write(to: file)

        let loaded = SpeedTestHistory<CPUBenchmarkResult>(file: file).load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.context == nil)
        let run = try #require(BenchmarkLibrary(folder: folder).load().first)
        #expect(run.context == nil)
        #expect(run.contextSummary == "Context not recorded")
        // Reading never rewrites the file.
        #expect(try Data(contentsOf: file) == old)
    }

    @Test func aContextRoundTripsWithItsRun() throws {
        let result = cpu(at: 100, context: context(power: .battery, thermal: .fair, busy: 0.31))
        let decoded = try JSONDecoder().decode(CPUBenchmarkResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(decoded.context?.version == BenchmarkContext.currentVersion)
        #expect(BenchmarkRun(decoded).context == result.context)
    }

    @Test func aDamagedOrNewerContextCostsOnlyItsFields() throws {
        let json = #"""
        {"version": 7, "power": "solar", "cpuLoad": "busy", "thermalAtStart": "serious", "lowPowerMode": true,
         "availableMemoryBytes": -5, "chip": "Apple M5 Pro", "aFieldFromLater": {"x": 1}}
        """#
        let read = try JSONDecoder().decode(BenchmarkContext.self, from: Data(json.utf8))
        #expect(read.version == 7)
        #expect(read.power == nil)
        #expect(read.cpuLoad == nil)
        #expect(read.availableMemoryBytes == nil)
        #expect(read.thermalAtStart == .serious)
        #expect(read.lowPowerMode == true)
        #expect(read.chip == "Apple M5 Pro")
        #expect(!read.isEmpty)
    }

    @Test func aContextThatIsntAnObjectReadsAsNotRecorded() throws {
        var entry = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(disk(at: 100))) as? [String: Any])
        entry["context"] = 5
        let data = try JSONSerialization.data(withJSONObject: entry)
        let result = try JSONDecoder().decode(DiskSpeedResult.self, from: data)
        #expect(result.context?.isEmpty == true)
        #expect(BenchmarkRun(result).context == nil)
        #expect(BenchmarkRun(result).contextSummary == BenchmarkContext.notRecorded)
    }

    @Test func everyTestCarriesItsContext() {
        let state = context()
        let network = NetworkQualityResult(date: Date(timeIntervalSince1970: 1), requestedInterface: "en0", interface: "en0",
                                           downloadBitsPerSecond: 1e8, uploadBitsPerSecond: 1e7, responsiveness: 600, context: state)
        #expect(BenchmarkRun(network).context == state)
        #expect(BenchmarkRun(cpu(at: 1, context: state)).context == state)
        let diskRun = BenchmarkRun(disk(at: 1, context: context(thermal: .serious)))
        // The disk test records no system version of its own: its context gives one.
        #expect(diskRun.osVersion == "macOS 27.2 (27C61)")
        #expect(diskRun.conditions == ["thermal pressure serious"])
        #expect(BenchmarkRun(disk(at: 1)).osVersion == nil)
    }
}

// MARK: - In words

struct BenchmarkContextTextTests {
    @Test func saysHowTheMacStoodInALine() {
        let state = context(power: .battery, thermal: .fair, busy: 0.12, available: 3 << 30)
        #expect(state.conditionsLine == "on battery · thermal fair · CPU 12% busy before · 3.00 GB memory available")
        #expect(state.provenanceLine == "macOS 27.2 (27C61) · OpenTaskManager 0.1.0, release build · Mac17,8 · Apple M5 Pro")
        var desktop = context(battery: false)
        desktop.lowPowerMode = true
        desktop.thermalAtEnd = .serious
        #expect(desktop.conditionsLine.hasPrefix("on AC power · Low Power Mode on · thermal nominal, then serious · "))
        #expect(desktop.worstThermal == .serious)
        #expect(BenchmarkContext(version: 1).conditionsLine.isEmpty)
        #expect(BenchmarkContext(version: 1).isEmpty)
    }
}

// MARK: - Differences between two runs' starts

struct BenchmarkContextWarningTests {
    @Test func alikeStartsGiveNoWarnings() {
        #expect(warnings(context(), context()).isEmpty)
        #expect(warnings(nil, nil).isEmpty)
    }

    @Test func aRunWithoutAContextIsNamed() {
        let earlier = warnings(nil, context())
        #expect(earlier.map(\.topic) == [.notRecorded])
        #expect(earlier.first?.text.hasPrefix("The earlier run didn't record its context") == true)
        #expect(warnings(context(), nil).first?.text.contains("only the earlier run's is known") == true)
    }

    @Test func powerSourceDiffers() {
        let laptop = warnings(context(power: .battery), context(power: .ac))
        #expect(laptop.map(\.text) == ["The earlier run was on battery, the later on the power adapter."])
        let desktop = warnings(context(power: .ac, battery: false), context(power: .ups, battery: false))
        #expect(desktop.map(\.text) == ["The earlier run was on AC power, the later on a UPS."])
    }

    @Test func thermalStateAtTheStartDiffersOrIsHigh() {
        #expect(warnings(context(thermal: .nominal), context(thermal: .serious)).map(\.text)
            == ["The later run started at thermal state serious, the earlier at nominal."])
        #expect(warnings(context(thermal: .fair), context(thermal: .nominal)).map(\.text)
            == ["The earlier run started at thermal state fair, the later at nominal."])
        #expect(warnings(context(thermal: .fair), context(thermal: .fair)).map(\.text) == ["Both runs started at thermal state fair."])
        #expect(warnings(context(thermal: nil), context(thermal: .critical)).isEmpty)
    }

    @Test func aBusyCPUBeforeEitherRun() {
        #expect(warnings(context(busy: 0.03), context(busy: 0.45)).map(\.text)
            == ["The later run started with 45% of the CPU busy, the earlier with 3%."])
        #expect(warnings(context(busy: 0.25), context(busy: 0.30)).map(\.text) == ["Both runs started with the CPU busy: 25% and 30%."])
        // Under 20% in both, a few points' difference is nothing to mention.
        #expect(warnings(context(busy: 0.05), context(busy: 0.15)).isEmpty)
    }

    @Test func muchLessMemoryAvailable() {
        #expect(warnings(context(available: 2 << 30), context(available: 20 << 30)).map(\.text)
            == ["The earlier run started with 2.00 GB of memory available, the later with 20.0 GB."])
        #expect(warnings(context(available: 10 << 30), context(available: 12 << 30)).isEmpty)
        // Under half, but less than a gigabyte apart.
        #expect(warnings(context(available: 200 << 20), context(available: 600 << 20)).isEmpty)
    }

    @Test func hardwareAndBuildOnlyWhereTheRunsDontRecordThem() {
        let other = context(model: "Mac16,1", chip: "Apple M4", optimized: false, app: "OpenTaskManager 0.2.0")
        let both = warnings(context(), other)
        #expect(both.map(\.topic) == [.hardware, .build])
        #expect(both.first?.text == "The runs were on different Macs: Mac17,8 (Apple M5 Pro), then Mac16,1 (Apple M4).")
        #expect(both.last?.text == "The earlier run came from a release build of the app, the later from a debug build.")
        #expect(warnings(context(), other, build: true, machine: true).isEmpty)
        #expect(warnings(context(app: "otm 0.1.0"), context(app: "otm 0.2.0")).map(\.text)
            == ["The app changed between the runs: otm 0.1.0, then otm 0.2.0."])
    }

    @Test func warningsComeInAFixedOrder() {
        let topics = warnings(context(power: .battery, thermal: .fair, busy: 0.5, available: 1 << 30),
                              context(power: .ac, thermal: .nominal, busy: 0.02, available: 30 << 30)).map(\.topic)
        #expect(topics == [.power, .thermal, .cpuLoad, .memory])
    }

    @Test func aComparisonWarnsButStillCompares() throws {
        let earlier = BenchmarkRun(disk(at: 100, context: context(power: .battery, busy: 0.5)))
        let later = BenchmarkRun(disk(at: 200, context: context(power: .ac)))
        guard case let .compared(comparison) = BenchmarkComparison.compare(later, earlier) else {
            Issue.record("A different context must not refuse a comparison")
            return
        }
        #expect(comparison.contextWarnings.map(\.topic) == [.power, .cpuLoad])
        // A CPU benchmark records its build and Mac, so those never repeat here.
        let builds = BenchmarkComparison.contextWarnings(BenchmarkRun(cpu(at: 100, context: context(optimized: true))),
                                                         BenchmarkRun(cpu(at: 200, context: context(optimized: false))))
        #expect(builds.isEmpty)
        // Only the workload version or build refuses; an old run without a context still compares.
        guard case let .compared(mixed) = BenchmarkComparison.compare(BenchmarkRun(cpu(at: 100)), BenchmarkRun(cpu(at: 200, context: context())))
        else {
            Issue.record("A run without a context must still compare")
            return
        }
        #expect(mixed.contextWarnings.map(\.topic) == [.notRecorded])
    }
}

// MARK: - Reading this Mac's

struct BenchmarkContextReaderTests {
    @Test func readsThisMacsState() {
        let load = BenchmarkCPULoad(busy: 0.07, seconds: 5, source: .sampler)
        let state = BenchmarkContextReader.atStart(appVersion: "otm test", cpuLoad: load)
        #expect(state.version == BenchmarkContext.currentVersion)
        #expect(state.osVersion?.hasPrefix("macOS ") == true)
        #expect(state.appVersion == "otm test")
        #expect(state.optimized == CPUBenchmark.isOptimizedBuild)
        #expect(state.chip?.isEmpty == false)
        #expect(state.lowPowerMode != nil)
        #expect(state.thermalAtStart != nil)
        #expect(state.thermalAtEnd == nil)
        #expect(state.cpuLoad == load)
        #expect((state.availableMemoryBytes ?? 0) > 0)
        #expect((state.physicalMemoryBytes ?? 0) >= (state.availableMemoryBytes ?? 0))
        #expect(state.ended(thermal: .fair).thermalAtEnd == .fair)
    }

    @Test func probesTheCPUWhenNoSamplerIsRunning() throws {
        let load = try #require(BenchmarkContextReader.probe(seconds: 0.05))
        #expect((0...1).contains(load.busy))
        #expect(load.source == .probe)
        #expect(load.seconds >= 0.05)
        #expect(BenchmarkContextReader.probe(seconds: 0) == nil)
    }

    @Test func takesTheSamplersLatestLoads() throws {
        // One a second: the last five, never the oldest held (since boot).
        let load = try #require(BenchmarkCPULoad.recent([0.9, 0.1, 0.2, 0.1, 0.2, 0.1, 0.3], step: 1, seconds: 5))
        #expect(abs(load.busy - 0.18) < 1e-9)
        #expect(load.seconds == 5)
        #expect(load.source == .sampler)
        // Just launched: what there is after the first.
        let early = try #require(BenchmarkCPULoad.recent([0.9, 0.4, 0.2], step: 1, seconds: 5))
        #expect(abs(early.busy - 0.3) < 1e-9)
        #expect(early.seconds == 2)
        // Every 2 s, about 5 s back: three updates.
        #expect(BenchmarkCPULoad.recent([0.5, 0.5, 0.5, 0.5, 0.5], step: 2, seconds: 5)?.seconds == 6)
        #expect(BenchmarkCPULoad.recent([2, 2], step: 1, seconds: 5)?.busy == 1)
        #expect(BenchmarkCPULoad.recent([0.3], step: 1, seconds: 5) == nil)
        #expect(BenchmarkCPULoad.recent([0.3, 0.4], step: 0, seconds: 5) == nil)
        #expect(BenchmarkCPULoad.recent([0.3, .nan], step: 1, seconds: 5) == nil)
    }

    @Test func capturesWithoutBlockingWhenAsked() async throws {
        let given = BenchmarkCPULoad(busy: 0.2, seconds: 5, source: .sampler)
        let kept = await BenchmarkContextReader.capture(appVersion: "app", cpuLoad: given, probeSeconds: 0.05)
        #expect(kept.cpuLoad == given)
        let probed = await BenchmarkContextReader.capture(appVersion: "app", probeSeconds: 0.05)
        let load = try #require(probed.cpuLoad)
        #expect(load.source == .probe)
        #expect(load.seconds >= 0.05)
        #expect((0...1).contains(load.busy))
        #expect(await BenchmarkContextReader.probeAsync(seconds: 0) == nil)
    }

    @Test func namesThePowerSource() {
        #expect(BenchmarkContextReader.powerSource("AC Power") == .ac)
        #expect(BenchmarkContextReader.powerSource("Battery Power") == .battery)
        #expect(BenchmarkContextReader.powerSource("UPS Power") == .ups)
        #expect(BenchmarkContextReader.powerSource("Solar") == nil)
    }
}
