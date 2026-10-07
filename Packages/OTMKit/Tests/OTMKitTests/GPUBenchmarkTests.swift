import Foundation
import Metal
@testable import OTMKit
import Testing

/// Small workloads and short command buffers, so a whole run takes a fraction of a second.
private var quick: GPUBenchmarkConfiguration {
    var configuration = GPUBenchmarkConfiguration()
    configuration.computeThreads = 1 << 12
    configuration.computeIterations = 64
    configuration.computeSeedGroups = 8
    configuration.memoryBytes = 1 << 20
    configuration.memoryLanes = 1 << 10
    configuration.fillSize = 64
    configuration.fillLayers = 8
    configuration.warmUpSeconds = 0.01
    configuration.repeatSeconds = 0.002
    configuration.repeats = 3
    return configuration
}

private func device(_ name: String = "Apple M5 Pro", cores: Int? = 20) -> GPUBenchmarkDevice {
    GPUBenchmarkDevice(name: name, cores: cores, model: "Mac17,8", unifiedMemory: true, workingSetBytes: 40 << 30)
}

private func measurement(_ rates: [Double], gpu: Double = 0.5, wall: Double = 0.501) -> GPUBenchmarkMeasurement {
    GPUBenchmarkMeasurement(repeats: rates, gpuSeconds: rates.map { _ in gpu }, wallSeconds: rates.map { _ in wall }, unitsPerRepeat: 100)
}

private func record(at time: TimeInterval, device: GPUBenchmarkDevice = device(), optimized: Bool = true,
                    start: ThermalState = .nominal, end: ThermalState = .nominal) -> GPUBenchmarkResult {
    let workloads = GPUWorkload.allCases.map { GPUWorkloadResult(workload: $0, measurement: measurement([8e12, 8.1e12, 7.9e12])) }
    return GPUBenchmarkResult(date: Date(timeIntervalSince1970: time), suiteVersion: GPUBenchmark.suiteVersion, configuration: .standard,
                              device: device, osVersion: "macOS 27.2 (27C61)", appVersion: "otm 0.1.0", optimized: optimized,
                              thermalStateAtStart: start, thermalStateAtEnd: end, lowPowerMode: false, seconds: 10,
                              workloads: workloads)
}

/// FNV-1a, to pin the shader source.
private func fingerprint(_ text: String) -> UInt64 {
    text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
}

struct GPUBenchmarkTests {
    /// The standard workloads' answers and shaders. If this fails, the
    /// workloads changed: bump `GPUBenchmark.suiteVersion` and update the pinned values.
    @Test func standardWorkloadsArePinned() {
        let standard = GPUBenchmarkConfiguration.standard
        #expect(GPUBenchmark.suiteVersion == 1)
        #expect(standard.computeThreads == 1 << 20 && standard.computeIterations == 1024 && standard.computeSeedGroups == 64)
        #expect(standard.memoryBytes == 256 << 20 && standard.memoryLanes == 1 << 17)
        #expect(standard.fillSize == 2048 && standard.fillLayers == 256)
        let shaders = fingerprint(GPUBenchmarkShaders.source)
        #expect(shaders == 0x55CF_30DE_58FC_E5D8)

        let compute = GPUComputeReference(groups: standard.computeSeedGroups, iterations: standard.computeIterations, seed: standard.seed)
        #expect(compute.seeds.count == 64 * 8)
        let computeAnswers = compute.expected.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
        #expect(computeAnswers == 0x2FA5_3B33_B3D2_DB75)

        let memory = GPUMemoryReference(bytes: standard.memoryBytes, lanes: standard.memoryLanes, seed: standard.seed)
        #expect(memory.rows == 128 && memory.bytes == 256 << 20)
        let memoryAnswers = memory.expected.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
        #expect(memoryAnswers == 0x2DF0_C7E3_6955_A880)

        #expect(GPUFillReference.maximumUnits(layers: standard.fillLayers) == 65536)
        #expect(abs(standard.plannedSeconds - 9.6) < 1e-9)
    }

    @Test func computeAnswersFollowTheShadersArithmetic() {
        let reference = GPUComputeReference(groups: 3, iterations: 50, seed: 7)
        #expect(reference.seeds.count == 3 * GPUComputeReference.chains)
        #expect(reference.seeds.allSatisfy { $0 >= 0.5 && $0 < 1.5 })
        // One chain by hand: x ← x × a + b, rounded once per step.
        var sum: UInt32 = 0
        for chain in 0..<GPUComputeReference.chains {
            var value = Double(reference.seeds[GPUComputeReference.chains + chain])
            for _ in 0..<50 { value = Double(Float(value * Double(GPUComputeReference.multiplier) + Double(GPUComputeReference.addend))) }
            sum &+= Float(value).bitPattern
        }
        #expect(reference.expected[1] == sum)
        // Chains stay normal, well away from overflow or subnormals.
        #expect(GPUComputeReference.multiplier < 1 && GPUComputeReference.multiplier * 4096 == 4095)
        #expect(GPUComputeReference(groups: 2, iterations: 50, seed: 8).expected != Array(reference.expected.prefix(2)))
    }

    @Test func memoryTotalsMatchTheFilledData() {
        let reference = GPUMemoryReference(bytes: 64 << 10, lanes: 256, seed: 99)
        #expect(reference.rows == 16)
        #expect(reference.bytes == 64 << 10)
        for lane in [0, 1, 37, 255] {
            for word in 0..<4 {
                var sum: UInt32 = 0
                for row in 0..<reference.rows {
                    sum &+= GPUMemoryReference.element(row: row, lane: lane, word: word, seed: reference.seed)
                }
                #expect(reference.expected[lane * 4 + word] == sum)
            }
        }
        // Rows come in fours, as the shader reads them.
        #expect(GPUMemoryReference(bytes: 6 * 16 * 8, lanes: 8, seed: 1).rows == 4)
    }

    @Test func checksCatchAWrongOrMissingUnit() {
        let compute = GPUComputeReference(groups: 4, iterations: 10, seed: 3)
        var results = (0..<64).map { compute.expected[$0 % 4] &* 3 }
        #expect(results.withUnsafeBufferPointer { compute.verify($0, units: 3) })
        #expect(!results.withUnsafeBufferPointer { compute.verify($0, units: 2) })
        results[41] &+= 1
        #expect(!results.withUnsafeBufferPointer { compute.verify($0, units: 3) })

        let memory = GPUMemoryReference(bytes: 16 << 10, lanes: 64, seed: 3)
        var sums = memory.expected.map { $0 &* 5 }
        #expect(sums.withUnsafeBufferPointer { memory.verify($0, units: 5) })
        #expect(!sums.withUnsafeBufferPointer { memory.verify($0, units: 4) })
        sums[200] ^= 1
        #expect(!sums.withUnsafeBufferPointer { memory.verify($0, units: 5) })
        #expect(!Array(memory.expected.dropLast()).withUnsafeBufferPointer { memory.verify($0, units: 1) })

        var pixels = [Float](repeating: 24, count: 100)
        #expect(pixels.withUnsafeBufferPointer { GPUFillReference.verify($0, units: 3, layers: 8) })
        pixels[99] = 23
        #expect(!pixels.withUnsafeBufferPointer { GPUFillReference.verify($0, units: 3, layers: 8) })
    }

    @Test func sizesCommandBuffersFromTheWarmUp() {
        #expect(GPUBenchmark.units(forSeconds: 0.5, unitSeconds: 0.002, limit: 1 << 20) == 250)
        #expect(GPUBenchmark.units(forSeconds: 0.5, unitSeconds: 2, limit: 1 << 20) == 1)
        #expect(GPUBenchmark.units(forSeconds: 0.5, unitSeconds: 1e-9, limit: 65536) == 65536)
        #expect(GPUBenchmark.units(forSeconds: 0.5, unitSeconds: 0, limit: 10) == 1)
        #expect(GPUBenchmark.units(forSeconds: 0.5, unitSeconds: .nan, limit: 10) == 1)
    }

    @Test func runsEveryWorkloadOnThisMacsGPU() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            // Without Metal, a run says so rather than failing some other way.
            #expect(throws: GPUBenchmarkError.noDevice) { try GPUBenchmark.run(configuration: quick, appVersion: "tests") }
            #expect(GPUBenchmarkDevice.current() == nil)
            return
        }
        var reports: [GPUBenchmarkProgress] = []
        let result = try GPUBenchmark.run(configuration: quick, appVersion: "tests") { reports.append($0) }

        #expect(result.workloads.map(\.workload) == GPUWorkload.allCases)
        for workload in result.workloads {
            let measured = workload.measurement
            #expect(measured.repeats.count == quick.repeats)
            #expect(measured.gpuSeconds.count == quick.repeats && measured.wallSeconds.count == quick.repeats)
            #expect(measured.median > 0 && measured.unitsPerRepeat >= 1)
            #expect(measured.gpuSeconds.allSatisfy { $0 > 0 })
        }
        #expect(result.suiteVersion == GPUBenchmark.suiteVersion)
        #expect(result.configuration == quick)
        #expect(result.optimized == CPUBenchmark.isOptimizedBuild)
        #expect(result.appVersion == "tests")
        #expect(result.osVersion.hasPrefix("macOS "))
        #expect(result.historyKey == GPUBenchmarkDevice.current()?.key)
        #expect(result.seconds > 0)

        // Each workload in order, fractions rising to the end.
        var order: [GPUWorkload] = []
        for report in reports where order.last != report.workload { order.append(report.workload) }
        #expect(order == GPUWorkload.allCases)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        #expect(reports.first?.fraction == 0)
        #expect(abs((reports.last?.fraction ?? 0) - 1) < 1e-9)
        #expect(reports.last?.measured.count == GPUWorkload.allCases.count)
    }

    @Test func aCancelledRunStops() {
        let cancellation = GPUBenchmarkCancellation()
        cancellation.cancel()
        #expect(throws: GPUBenchmarkError.cancelled) {
            try GPUBenchmark.run(configuration: quick, appVersion: "tests", cancellation: cancellation)
        }
    }

    @Test func cancellingTheTaskStopsBetweenSubmissions() async {
        // Thousands of short command buffers: a cancel lands at the next one.
        var long = quick
        long.repeats = 100_000
        let started = Date()
        let task = Task { () async -> GPUBenchmarkError? in
            do throws(GPUBenchmarkError) {
                _ = try await GPUBenchmark.measure(configuration: long, appVersion: "tests") { _ in }
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let error = await task.value
        #expect(error == .cancelled || (MTLCreateSystemDefaultDevice() == nil && error == .noDevice))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func summarisesRepeats() {
        let odd = GPUBenchmarkMeasurement(repeats: [9, 12, 10], gpuSeconds: [0.5, 0.4, 0.6], wallSeconds: [0.51, 0.41, 0.61],
                                          unitsPerRepeat: 7)
        #expect(odd.median == 10)
        #expect(abs(odd.spread - 0.3) < 1e-12)
        #expect(odd.medianGPUSeconds == 0.5)
        #expect(odd.medianWallSeconds == 0.51)
        let even = measurement([40, 36, 44, 38])
        #expect(even.median == 39)
        #expect(measurement([]).median == 0)
        #expect(measurement([]).spread == 0)
    }

    @Test func flagsGPUTimeShortOfTheCommandBuffers() {
        // As the paravirtual GPU reported its fill-rate passes.
        #expect(measurement([3.4e11], gpu: 0.448, wall: 0.498).gpuTimeLooksShort)
        #expect(!measurement([3e11], gpu: 0.499, wall: 0.500).gpuTimeLooksShort)
        // A few milliseconds of wake-up on a short repeat isn't a gap.
        #expect(!measurement([3e11], gpu: 0.020, wall: 0.024).gpuTimeLooksShort)

        var result = record(at: 1)
        #expect(result.timingNote == nil)
        result.workloads[2].measurement = measurement([3.4e11], gpu: 0.448, wall: 0.498)
        #expect(result.shortTimedWorkloads.map(\.workload) == [.fill])
        #expect(result.timingNote?.hasPrefix("The GPU timed fill rate at 448 ms a repeat, against 498 ms from commit to completion.") == true)
        #expect(result.timingNote?.hasSuffix("so that figure may read high.") == true)
    }

    @Test func formatsInDecimalUnits() {
        #expect(GPUWorkload.compute.format(8_020_000_000_000) == "8.02 TFLOP/s")
        #expect(GPUWorkload.memory.format(279_000_000_000) == "279 GB/s")
        #expect(GPUWorkload.fill.format(30_640_000_000) == "30.6 Gpixel/s")
        #expect(GPUWorkload.compute.format(950) == "950 FLOP/s")
        #expect(GPUWorkload.memory.format(.nan) == "—")
        #expect(GPUWorkload.memory.scale(279e9).unit == "GB/s")
        #expect(GPUWorkload.fill.scale(306e9).divisor == 1e9)
    }

    @Test func describesTheDevice() {
        #expect(device().summary == "Apple M5 Pro · 20 cores")
        #expect(device().key == "Mac17,8|Apple M5 Pro|20")
        let virtual = GPUBenchmarkDevice(name: "Apple Paravirtual device", cores: nil, model: "VirtualMac2,1", unifiedMemory: true,
                                         workingSetBytes: 5 << 30)
        #expect(virtual.summary == "Apple Paravirtual device")
        #expect(virtual.key == "VirtualMac2,1|Apple Paravirtual device|")
    }

    @Test func tellsWhichResultsCompare() {
        let base = record(at: 1)
        #expect(base.isComparable(with: record(at: 2)))
        // The GPU runs the same shaders in a debug build.
        #expect(base.isComparable(with: record(at: 2, optimized: false)))
        #expect(!base.isComparable(with: record(at: 2, device: device("Apple M4 Max", cores: 40))))
        var smaller = record(at: 3)
        smaller.configuration.fillSize = 1024
        #expect(!base.isComparable(with: smaller))
        #expect(record(at: 1, start: .nominal, end: .serious).worstThermalState == .serious)
        #expect(record(at: 1, start: .fair, end: .nominal).worstThermalState == .fair)
    }

    @Test func explainsFailuresPlainly() {
        #expect(GPUBenchmarkError.noDevice.message.contains("no Metal GPU"))
        #expect(GPUBenchmarkError.unsupported("its compiler rejected the shaders").message
            == "This GPU can't run the benchmark: its compiler rejected the shaders. A virtual machine's GPU often can't.")
        #expect(GPUBenchmarkError.verificationFailed(.memory).message.hasPrefix("The memory workload gave a wrong result"))
        #expect(GPUBenchmarkError.failed(.fill, "it couldn't start a render pass").message
            == "The GPU stopped the fill rate workload: it couldn't start a render pass.")
    }

    @Test func keepsTheLastTenOnEachMac() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-gpubench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = SpeedTestHistory<GPUBenchmarkResult>(file: folder.appendingPathComponent("gpu-benchmark.json"), keptPerKey: 10,
                                                           keptKeys: 5)
        for time in 1...12 { try history.append(record(at: TimeInterval(time))) }
        try history.append(record(at: 13, device: device("Apple M4", cores: 10)))

        let kept = history.load()
        #expect(history.results(for: device().key).map(\.date.timeIntervalSince1970) == (3...12).reversed().map(TimeInterval.init))
        #expect(history.results(for: device("Apple M4", cores: 10).key).count == 1)
        #expect(kept.first == record(at: 13, device: device("Apple M4", cores: 10)))
        #expect(SpeedTestHistory<GPUBenchmarkResult>.gpuBenchmark.file.path.hasSuffix("OpenTaskManager/SpeedTests/gpu-benchmark.json"))
        #expect(SpeedTestHistory<GPUBenchmarkResult>.gpuBenchmark.keptPerKey == 10)
    }
}
