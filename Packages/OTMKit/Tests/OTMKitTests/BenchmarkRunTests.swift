import Foundation
@testable import OTMKit
import Testing

// MARK: - Fixtures

private let mac = CPUBenchmarkMachine(chip: "Apple M5 Pro", model: "Mac17,8", logicalCores: 18,
                                      coreTypes: [.init(name: "Super", cores: 6), .init(name: "Performance", cores: 12)],
                                      memoryBytes: 48 << 30)

private func cpu(at time: TimeInterval, machine: CPUBenchmarkMachine = mac, optimized: Bool = true, suite: Int = 1,
                 single: [Double] = [10, 11, 9], multi: [Double] = [120, 100, 110], lowPower: Bool = false,
                 os: String = "macOS 27.2 (27C61)") -> CPUBenchmarkResult {
    let workloads = CPUWorkload.allCases.map {
        CPUWorkloadResult(workload: $0, single: CPUBenchmarkMeasurement(workers: 1, repeats: single),
                          multi: CPUBenchmarkMeasurement(workers: 18, repeats: multi))
    }
    return CPUBenchmarkResult(date: Date(timeIntervalSince1970: time), suiteVersion: suite, configuration: .standard, machine: machine,
                              osVersion: os, appVersion: "OpenTaskManager 0.1.0", optimized: optimized, thermalStateAtStart: .nominal,
                              thermalStateAtEnd: .nominal, lowPowerMode: lowPower, seconds: 21, workloads: workloads)
}

/// `shortTimed` workloads' GPU time falls 50 ms short of their wall time, as a VM's can.
private func gpu(at time: TimeInterval, optimized: Bool = true, rates: [Double] = [8e12, 8.2e12, 7.9e12],
                 shortTimed: Set<GPUWorkload> = []) -> GPUBenchmarkResult {
    let device = GPUBenchmarkDevice(name: "Apple M5 Pro", cores: 20, model: "Mac17,8", unifiedMemory: true, workingSetBytes: 36 << 30)
    let workloads = GPUWorkload.allCases.map { workload in
        let gpu = shortTimed.contains(workload) ? 0.45 : 0.5
        return GPUWorkloadResult(workload: workload, measurement: GPUBenchmarkMeasurement(repeats: rates, gpuSeconds: [gpu, gpu, gpu],
                                                                                          wallSeconds: [0.501, 0.501, 0.501],
                                                                                          unitsPerRepeat: 40))
    }
    return GPUBenchmarkResult(date: Date(timeIntervalSince1970: time), suiteVersion: 1, configuration: .standard, device: device,
                              osVersion: "macOS 27.2 (27C61)", appVersion: optimized ? "otm 0.1.0" : "OpenTaskManager 0.1.0",
                              optimized: optimized, thermalStateAtStart: .nominal, thermalStateAtEnd: .fair, lowPowerMode: false,
                              seconds: 9, workloads: workloads)
}

private func disk(at time: TimeInterval, volume: String = "A19FE379", name: String = "Macintosh HD", fileSize: UInt64 = 1 << 30,
                  readSeconds: Double = 0.5) -> DiskSpeedResult {
    let sequential = DiskSpeedMeasurement(bytes: 1 << 30, operations: 1024, seconds: readSeconds)
    let random = DiskSpeedMeasurement(bytes: 4096 * 30000, operations: 30000, seconds: 3)
    return DiskSpeedResult(date: Date(timeIntervalSince1970: time),
                           volume: DiskSpeedVolume(name: name, mountPoint: "/", fileSystem: "apfs", uuid: volume), folder: "/tmp",
                           configuration: DiskSpeedConfiguration(fileSize: fileSize, seed: 7), freeBytes: 100 << 30, bypassedCache: false,
                           fullFlush: true, sequentialWrite: sequential, sequentialRead: sequential, randomWrite: random, randomRead: random)
}

private func network(at time: TimeInterval, interface: String = "en0", download: Double = 300e6, latency: Double? = 16,
                     endpoint: String = "edge-1.example") -> NetworkQualityResult {
    NetworkQualityResult(date: Date(timeIntervalSince1970: time), requestedInterface: interface, interface: interface,
                         downloadBitsPerSecond: download, uploadBitsPerSecond: 40e6, responsiveness: 600, idleLatency: latency,
                         endpoint: endpoint, toolVersion: "Version 27.2 (Build 27C61)")
}

private func refusal(_ first: BenchmarkRun, _ second: BenchmarkRun) -> BenchmarkRefusal? {
    guard case let .refused(refusal) = BenchmarkComparison.compare(first, second) else { return nil }
    return refusal
}

private func comparison(_ first: BenchmarkRun, _ second: BenchmarkRun) -> BenchmarkComparison? {
    guard case let .compared(comparison) = BenchmarkComparison.compare(first, second) else { return nil }
    return comparison
}

private func measurement(_ value: Double, _ low: Double? = nil, _ high: Double? = nil,
                         unit: BenchmarkUnit = .bytesPerSecond) -> BenchmarkMeasurement {
    BenchmarkMeasurement(id: "figure", name: "Figure", value: value, unit: unit, low: low, high: high, repeats: low == nil ? nil : 5)
}

// MARK: - Adapting each history

struct BenchmarkRunTests {
    @Test func adaptsACPUResult() {
        let run = BenchmarkRun(cpu(at: 100, optimized: false))
        #expect(run.kind == .cpu)
        #expect(run.id == "cpu-\(Int64((Date(timeIntervalSince1970: 100).timeIntervalSinceReferenceDate * 1000).rounded()))")
        #expect(run.workloadVersion == 1)
        #expect(run.build == BenchmarkBuild(app: "OpenTaskManager 0.1.0", optimized: false))
        #expect(run.build?.title == "Debug")
        #expect(run.machine?.key == mac.key)
        #expect(run.target == nil)
        #expect(run.measurements.map(\.id) == ["integer.single", "integer.multi", "floatingPoint.single", "floatingPoint.multi",
                                               "memory.single", "memory.multi"])
        let multi = run.measurement("integer.multi")
        #expect(multi?.title == "Integer, 18 workers")
        #expect(multi?.value == 110)
        #expect(multi?.low == 100)
        #expect(multi?.high == 120)
        #expect(multi?.repeats == 3)
        #expect(multi?.spread == 20.0 / 110)
        #expect(run.measurement("floatingPoint.single")?.unit == .flopsPerSecond)
        #expect(run.settings.first == BenchmarkSetting(name: "Workers", value: "18"))
        #expect(run.headline.map(\.id) == ["integer.multi", "floatingPoint.multi", "memory.multi"])
    }

    @Test func adaptsAGPUResult() {
        let run = BenchmarkRun(gpu(at: 100))
        #expect(run.kind == .gpu)
        #expect(run.measurements.map(\.unit) == [.flopsPerSecond, .bytesPerSecond, .pixelsPerSecond])
        #expect(run.measurement("compute")?.value == 8e12)
        #expect(run.machine?.name == "Apple M5 Pro · 20 cores · Mac17,8")
        #expect(run.conditions == ["thermal pressure fair"])
        #expect(run.measurements.allSatisfy { $0.caveat == nil })
    }

    @Test func aGPUFigureTimedShortCarriesItsOwnCaveat() {
        let run = BenchmarkRun(gpu(at: 100, shortTimed: [.fill]))
        #expect(run.measurement("fill")?.caveat == .timingUnverified)
        #expect(run.measurement("compute")?.caveat == nil)
        #expect(run.measurement("memory")?.caveat == nil)
        // It qualifies that figure, not the run.
        #expect(run.conditions == ["thermal pressure fair"])
        #expect(run.headlineSummary.hasSuffix("Fill rate 8.00 Tpixel/s (timing unverified)"))
        #expect(BenchmarkFigureCaveat.timingUnverified.title == "Timing unverified")
        #expect(BenchmarkFigureCaveat.timingUnverified.explanation.hasSuffix("so the figure may read high."))
        #expect(BenchmarkFigureCaveat.timingUnverified.brief.hasSuffix("so the figure may read high"))
    }

    @Test func adaptsADiskResult() {
        let run = BenchmarkRun(disk(at: 100))
        #expect(run.build == nil)
        #expect(run.target == BenchmarkTarget(key: "A19FE379", name: "Macintosh HD", detail: "/tmp"))
        #expect(run.measurements.map(\.id) == ["sequentialRead", "sequentialWrite", "randomRead", "randomWrite"])
        // 1 GiB in 0.5 s is 2,147 decimal megabytes a second.
        #expect(abs((run.measurement("sequentialRead")?.value ?? 0) - 2147.483648) < 1e-6)
        #expect(run.measurement("randomRead")?.value == 10000)
        #expect(run.measurement("randomRead")?.unit == .operationsPerSecond)
        #expect(run.measurements.allSatisfy { $0.spread == nil })
        #expect(run.conditions.first?.contains("F_NOCACHE") == true)
        // The seed changes every run and isn't a setting.
        #expect(!run.settingsSummary.contains("7"))
    }

    @Test func adaptsANetworkResultWithoutTheFiguresItLacks() {
        let run = BenchmarkRun(network(at: 100, latency: nil))
        #expect(run.measurements.map(\.id) == ["download", "upload", "responsiveness"])
        #expect(run.target?.key == "en0")
        #expect(run.target?.detail == "edge-1.example")
        #expect(!run.kind.measuresThisMac)
    }

    // MARK: - Compatibility

    @Test func comparesTwoCompatibleRunsEarlierFirst() throws {
        let earlier = BenchmarkRun(cpu(at: 100))
        let later = BenchmarkRun(cpu(at: 200, multi: [140, 135, 138]))
        let forward = try #require(comparison(earlier, later))
        let backward = try #require(comparison(later, earlier))
        #expect(forward == backward)
        #expect(forward.baseline == earlier.id)
        #expect(forward.compared == later.id)
        #expect(forward.changes.count == 6)
    }

    @Test func refusesTheSameRunTwice() {
        let run = BenchmarkRun(cpu(at: 100))
        #expect(refusal(run, run) == .sameRun)
    }

    @Test func refusesDifferentTests() {
        let refused = refusal(BenchmarkRun(cpu(at: 100)), BenchmarkRun(gpu(at: 200)))
        #expect(refused == .differentTests(.cpu, .gpu))
        #expect(refused?.reason.hasPrefix("These are different tests (CPU benchmark and GPU benchmark)") == true)
    }

    @Test func refusesDifferentWorkloadVersions() {
        let refused = refusal(BenchmarkRun(cpu(at: 100, suite: 1)), BenchmarkRun(cpu(at: 200, suite: 2)))
        #expect(refused == .differentVersions(.cpu, 1, 2))
        #expect(refused?.reason.hasPrefix("The runs used different versions of the workloads (v1 and v2)") == true)
        // The disk and Internet tests have no workloads: their method is versioned.
        var earlier = disk(at: 100), later = disk(at: 200)
        later.version = earlier.version + 1
        let disks = refusal(BenchmarkRun(earlier), BenchmarkRun(later))
        #expect(disks == .differentVersions(.disk, earlier.version, later.version))
        #expect(disks?.reason.contains("different versions of the test (v\(earlier.version) and v\(later.version))") == true)
        #expect(disks?.reason.contains("workload") == false)
    }

    @Test func refusesDebugAgainstRelease() {
        let refused = refusal(BenchmarkRun(gpu(at: 200, optimized: false)), BenchmarkRun(gpu(at: 100, optimized: true)))
        #expect(refused == .differentBuilds(baselineOptimized: true))
        #expect(refused?.reason.hasPrefix("The earlier run is from a release build and the later one from a debug build") == true)
        // Two debug runs compare.
        #expect(comparison(BenchmarkRun(cpu(at: 100, optimized: false)), BenchmarkRun(cpu(at: 200, optimized: false))) != nil)
    }

    @Test func refusesDifferentMacs() {
        var other = mac
        other.chip = "Apple M4"
        let refused = refusal(BenchmarkRun(cpu(at: 100)), BenchmarkRun(cpu(at: 200, machine: other)))
        #expect(refused == .differentMachines("Apple M5 Pro · Mac17,8", "Apple M4 · Mac17,8"))
    }

    @Test func refusesDifferentVolumesAndInterfaces() {
        let volumes = refusal(BenchmarkRun(disk(at: 100)), BenchmarkRun(disk(at: 200, volume: "B2", name: "Backup")))
        #expect(volumes == .differentTargets(.disk, "Macintosh HD", "Backup"))
        #expect(volumes?.reason.contains("different volumes (Macintosh HD and Backup)") == true)
        let interfaces = refusal(BenchmarkRun(network(at: 100)), BenchmarkRun(network(at: 200, interface: "en1")))
        #expect(interfaces?.reason.contains("different interfaces") == true)
    }

    @Test func refusesDifferentSettings() {
        let refused = refusal(BenchmarkRun(disk(at: 100)), BenchmarkRun(disk(at: 200, fileSize: 512 << 20)))
        #expect(refused == .differentSettings(name: "Test file", baseline: "1 GB", compared: "512 MB"))
        #expect(refused?.reason.contains("test file 1 GB in one and 512 MB in the other") == true)
    }

    // MARK: - Percentages and spread

    @Test func percentageChange() {
        #expect(BenchmarkChange.change(from: 100, to: 125) == 0.25)
        #expect(BenchmarkChange.change(from: 200, to: 150) == -0.25)
        #expect(BenchmarkChange.change(from: 0, to: 10) == nil)
        #expect(BenchmarkChange.change(from: 100, to: .nan) == nil)
        #expect(BenchmarkChange.formatChange(0.042) == "+4.2%")
        #expect(BenchmarkChange.formatChange(-0.25) == "−25%")
        #expect(BenchmarkChange.formatChange(0.0001) == "0.0%")
    }

    @Test func aChangeInsideBothRangesIsNoise() {
        // 100 ranging 95–105, then 103 ranging 99–108: the ranges overlap.
        #expect(BenchmarkChange.verdict(baseline: measurement(100, 95, 105), compared: measurement(103, 99, 108)) == .withinSpread)
        // Ranges that only touch still overlap.
        #expect(BenchmarkChange.verdict(baseline: measurement(100, 95, 105), compared: measurement(110, 105, 112)) == .withinSpread)
    }

    @Test func aChangePastBothRangesCounts() {
        #expect(BenchmarkChange.verdict(baseline: measurement(100, 99, 101), compared: measurement(110, 108, 111)) == .better)
        #expect(BenchmarkChange.verdict(baseline: measurement(100, 99, 101), compared: measurement(90, 89, 92)) == .worse)
        // A delay is better lower.
        let lower = BenchmarkChange.verdict(baseline: measurement(20, 19, 21, unit: .milliseconds),
                                            compared: measurement(10, 9, 11, unit: .milliseconds))
        #expect(lower == .better)
    }

    @Test func aTinyMovePastTightRangesIsNegligible() {
        // 8.012 ranging 8.011–8.013, then 8.009 ranging 8.008–8.010: no overlap, but a 0.04% move.
        #expect(BenchmarkChange.verdict(baseline: measurement(8.012, 8.011, 8.013), compared: measurement(8.009, 8.008, 8.010)) == .negligible)
        // A 1% move past both ranges counts.
        #expect(BenchmarkChange.verdict(baseline: measurement(100, 99.9, 100.1), compared: measurement(99, 98.9, 99.1)) == .worse)
    }

    @Test func aFigureMeasuredOnceHasNoVerdict() {
        #expect(BenchmarkChange.verdict(baseline: measurement(100), compared: measurement(150)) == .measuredOnce)
        #expect(BenchmarkChange.verdict(baseline: measurement(100), compared: measurement(100)) == .unchanged)
    }

    @Test func comparisonRowsCarryBothSpreads() throws {
        let compared = try #require(comparison(BenchmarkRun(cpu(at: 100)), BenchmarkRun(cpu(at: 200, multi: [140, 135, 138]))))
        let multi = try #require(compared.changes.first { $0.id == "integer.multi" })
        #expect(multi.baseline == 110)
        #expect(multi.compared == 138)
        #expect(abs((multi.change ?? 0) - 28.0 / 110) < 1e-12)
        #expect(multi.verdict == .better)
        #expect(multi.spreadText == "±9.1% / ±1.8%")
        let single = try #require(compared.changes.first { $0.id == "integer.single" })
        #expect(single.verdict == .unchanged)
    }

    @Test func caveatsSayWhatTheFiguresCantShow() throws {
        let disks = try #require(comparison(BenchmarkRun(disk(at: 100)), BenchmarkRun(disk(at: 200, readSeconds: 0.4))))
        #expect(disks.changes.first?.verdict == .measuredOnce)
        #expect(disks.changes.first?.spreadText == "—")
        #expect(disks.caveats.contains { $0.hasPrefix("This test measures each figure once") })
        #expect(disks.caveats.contains { $0.hasPrefix("Earlier run: the volume ignored F_NOCACHE") })

        let macs = try #require(comparison(BenchmarkRun(cpu(at: 100)), BenchmarkRun(cpu(at: 200, lowPower: true, os: "macOS 27.3 (27D1)"))))
        #expect(macs.caveats.contains("The system changed between the runs: macOS 27.2 (27C61), then macOS 27.3 (27D1)."))
        #expect(macs.caveats.contains("Later run: Low Power Mode on."))
        #expect(!macs.caveats.contains { $0.hasPrefix("Both runs are from a debug build") })

        let debug = try #require(comparison(BenchmarkRun(cpu(at: 100, optimized: false)), BenchmarkRun(cpu(at: 200, optimized: false))))
        #expect(debug.caveats.contains { $0.hasPrefix("Both runs are from a debug build") })

        let links = try #require(comparison(BenchmarkRun(network(at: 100)), BenchmarkRun(network(at: 200, endpoint: "edge-2.example"))))
        #expect(links.caveats.first?.contains("not on this Mac; these runs reached different servers (edge-1.example, then edge-2.example)") == true)
    }

    @Test func aFigureInDoubtQualifiesItsChange() throws {
        let later = try #require(comparison(BenchmarkRun(gpu(at: 100)), BenchmarkRun(gpu(at: 200, shortTimed: [.fill]))))
        let fill = try #require(later.changes.first { $0.id == "fill" })
        #expect(fill.baselineCaveat == nil)
        #expect(fill.comparedCaveat == .timingUnverified)
        #expect(fill.caveat == .timingUnverified)
        #expect(fill.caveatNote == "Fill rate: timing unverified in the later run, so this change may not be real.")
        #expect(later.changes.first { $0.id == "compute" }?.caveat == nil)
        // First, since it bears on a row's verdict.
        #expect(later.caveats.first == fill.caveatNote)

        let both = try #require(comparison(BenchmarkRun(gpu(at: 100, shortTimed: [.fill])), BenchmarkRun(gpu(at: 200, shortTimed: [.fill]))))
        #expect(both.changes.first { $0.id == "fill" }?.caveatNote?.contains("in both runs") == true)
        let earlier = try #require(comparison(BenchmarkRun(gpu(at: 100, shortTimed: [.fill])), BenchmarkRun(gpu(at: 200))))
        #expect(earlier.changes.first { $0.id == "fill" }?.caveatNote?.contains("in the earlier run") == true)
    }

    @Test func verdictSummaryCountsTheMovesFirst() throws {
        let compared = try #require(comparison(BenchmarkRun(cpu(at: 100)), BenchmarkRun(cpu(at: 200, multi: [140, 135, 138]))))
        // Each workload's multi figure moved past both spreads; its single figure didn't move.
        #expect(compared.verdictSummary == "3 better · 3 unchanged")
        let disks = try #require(comparison(BenchmarkRun(disk(at: 100)), BenchmarkRun(disk(at: 200, readSeconds: 0.4))))
        #expect(disks.verdictSummary == "2 measured once · 2 unchanged")
    }

    @Test func refusalsHaveAShortForm() {
        #expect(BenchmarkRefusal.differentBuilds(baselineOptimized: true).summary == "a debug and a release build")
        #expect(BenchmarkRefusal.differentTargets(.disk, "A", "B").summary == "different volumes")
        #expect(BenchmarkRefusal.differentTargets(.network, "en0", "en1").summary == "different interfaces")
        #expect(BenchmarkRefusal.differentSettings(name: "Workers", baseline: "6", compared: "8").summary == "different settings (workers)")
        #expect(BenchmarkRefusal.sameRun.summary == "the same run twice")
    }

    // MARK: - Units

    @Test func unitsScaleToTheLargestFigure() {
        #expect(BenchmarkUnit.bytesPerSecond.format(12.4e9) == "12.4 GB/s")
        #expect(BenchmarkUnit.flopsPerSecond.format(150e6) == "150 MFLOP/s")
        #expect(BenchmarkUnit.pixelsPerSecond.format(3.21e9) == "3.21 Gpixel/s")
        #expect(BenchmarkUnit.bitsPerSecond.format(302_652_288) == "303 Mbps")
        #expect(BenchmarkUnit.bitsPerSecond.format(34_500_000) == "34.5 Mbps")
        #expect(BenchmarkUnit.megabytesPerSecond.format(3207.4) == "\(3207.formatted()) MB/s")
        #expect(BenchmarkUnit.megabytesPerSecond.format(48.24) == "48.2 MB/s")
        #expect(BenchmarkUnit.roundTripsPerMinute.format(612.7) == "613 RPM")
        #expect(BenchmarkUnit.milliseconds.format(16.4) == "16 ms")
        #expect(BenchmarkUnit.milliseconds.format(4.24) == "4.2 ms")
        let scale = BenchmarkUnit.bytesPerSecond.scale(28.5e9)
        #expect(scale.unit == "GB/s")
        #expect(BenchmarkUnit.bytesPerSecond.number(5.3e9, divisor: scale.divisor) == "5.30")
        #expect(!BenchmarkUnit.milliseconds.higherIsBetter)
    }
}

// MARK: - Export and the library

struct BenchmarkExportTests {
    @Test func jsonRoundTripsInAVersionedEnvelope() throws {
        let runs = [BenchmarkRun(cpu(at: 100)), BenchmarkRun(cpu(at: 200)), BenchmarkRun(disk(at: 150))]
        let export = BenchmarkExport(exported: Date(timeIntervalSince1970: 300), app: "otm 0.1.0", runs: runs,
                                     comparisons: [(runs[1], runs[0])])
        #expect(export.runs.map(\.date.timeIntervalSince1970) == [200, 150, 100])
        let data = try export.json()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == BenchmarkExport.formatName)
        #expect(object["version"] as? Int == 1)
        #expect(object["exported"] as? String == "1970-01-01T00:05:00Z")
        let read = try BenchmarkExport.read(data)
        #expect(read == export)
        #expect(read.comparisons.first?.baseline == runs[0].id)
        #expect(read.comparisons.first?.changes?.count == 6)
    }

    @Test func refusedComparisonsKeepTheirReason() {
        let runs = [BenchmarkRun(gpu(at: 100, optimized: true)), BenchmarkRun(gpu(at: 200, optimized: false))]
        let export = BenchmarkExport(exported: Date(), app: "otm", runs: runs, comparisons: [(runs[0], runs[1])])
        #expect(export.comparisons.first?.changes == nil)
        #expect(export.comparisons.first?.refused?.contains("debug build") == true)
    }

    @Test func readsOnlyItsOwnFormat() throws {
        #expect(throws: BenchmarkExport.ReadError.notAnExport) {
            try BenchmarkExport.read(Data(#"{"results": []}"#.utf8))
        }
        var newer = BenchmarkExport(exported: Date(timeIntervalSince1970: 0), app: "otm", runs: [])
        newer.version = BenchmarkExport.currentVersion + 1
        let data = try newer.json()
        #expect(throws: BenchmarkExport.ReadError.newerVersion(BenchmarkExport.currentVersion + 1)) {
            try BenchmarkExport.read(data)
        }
    }

    @Test func markdownHasATablePerTestAndTheComparison() throws {
        let utc = TimeZone(identifier: "UTC") ?? .current
        let runs = [BenchmarkRun(gpu(at: 0)), BenchmarkRun(gpu(at: 60, rates: [9.2e12, 9.3e12, 9.1e12])), BenchmarkRun(network(at: 120))]
        let export = BenchmarkExport(exported: Date(timeIntervalSince1970: 180), app: "OpenTaskManager 0.1.0", runs: runs,
                                     comparisons: [(runs[0], runs[1])])
        let markdown = export.markdown(timeZone: utc)
        #expect(markdown.hasPrefix("# Benchmark results\n\nExported 1970-01-01 00:03 from OpenTaskManager 0.1.0 · 3 runs."))
        #expect(markdown.contains("## GPU benchmark"))
        #expect(markdown.contains("| When | Build | FP32 compute | Memory | Fill rate | Notes |"))
        #expect(markdown.contains("| 1970-01-01 00:01 | Release | 9.20 TFLOP/s ±1.1% |"))
        #expect(markdown.contains("### Compared: 1970-01-01 00:00 → 1970-01-01 00:01"))
        #expect(markdown.contains("| FP32 compute | 8.00 TFLOP/s | 9.20 TFLOP/s | +15% | ±1.9% / ±1.1% | better |"))
        #expect(markdown.contains("## Internet quality\n\nThese figures measure the Internet connection"))
        #expect(markdown.contains("| When | On | Download | Upload | Responsiveness | Idle latency | Notes |"))
        #expect(markdown.contains("Workloads v1."))
        #expect(markdown.contains("Test v1. Settings: Mode parallel."))
        // GPU before Internet, as the workspace orders them.
        let gpu = try #require(markdown.range(of: "## GPU"))
        let internet = try #require(markdown.range(of: "## Internet"))
        #expect(gpu.lowerBound < internet.lowerBound)
        #expect(!markdown.contains("timing unverified"))
    }

    @Test func aFigureInDoubtIsQualifiedWhereverItIsExported() throws {
        let utc = TimeZone(identifier: "UTC") ?? .current
        let runs = [BenchmarkRun(gpu(at: 0)), BenchmarkRun(gpu(at: 60, shortTimed: [.fill]))]
        let export = BenchmarkExport(exported: Date(timeIntervalSince1970: 120), app: "otm", runs: runs, comparisons: [(runs[0], runs[1])])
        let markdown = export.markdown(timeZone: utc)
        #expect(markdown.contains("| 8.00 Tpixel/s ±1.9% (timing unverified) |"))
        #expect(markdown.contains("| Fill rate | 8.00 Tpixel/s | 8.00 Tpixel/s (timing unverified) |"))
        #expect(markdown.contains("Timing unverified: The GPU's own clock"))
        #expect(markdown.contains("- Fill rate: timing unverified in the later run, so this change may not be real."))
        let read = try BenchmarkExport.read(export.json())
        #expect(read.runs.first?.measurement("fill")?.caveat == .timingUnverified)
        #expect(read.comparisons.first?.changes?.first { $0.id == "fill" }?.comparedCaveat == .timingUnverified)
    }

    @Test func libraryAdaptsEveryHistoryWithoutRewritingIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-benchlibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = BenchmarkLibrary(folder: folder)
        #expect(library.load().isEmpty)

        try SpeedTestHistory<CPUBenchmarkResult>(file: folder.appendingPathComponent("cpu-benchmark.json")).append(cpu(at: 100))
        try SpeedTestHistory<GPUBenchmarkResult>(file: folder.appendingPathComponent("gpu-benchmark.json")).append(gpu(at: 300))
        try SpeedTestHistory<DiskSpeedResult>(file: folder.appendingPathComponent("disk-speed.json")).append(disk(at: 200))
        try SpeedTestHistory<NetworkQualityResult>(file: folder.appendingPathComponent("network-quality.json")).append(network(at: 400))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let before = try files.map { try Data(contentsOf: $0) }

        let runs = library.load()
        #expect(runs.map(\.kind) == [.network, .gpu, .disk, .cpu])
        #expect(try files.map { try Data(contentsOf: $0) } == before)
    }
}
