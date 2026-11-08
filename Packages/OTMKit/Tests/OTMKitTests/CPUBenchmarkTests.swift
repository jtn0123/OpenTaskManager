import Foundation
@testable import OTMKit
import Testing

/// Small workloads and short passes, so a whole run takes a fraction of a second.
private var quick: CPUBenchmarkConfiguration {
    var configuration = CPUBenchmarkConfiguration()
    configuration.hashBytes = 16 << 10
    configuration.matrixSize = 16
    configuration.memoryBytes = 1 << 20
    configuration.memoryChunkBytes = 64 << 10
    configuration.warmUpSeconds = 0.01
    configuration.repeatSeconds = 0.02
    configuration.repeats = 3
    return configuration
}

private func machine(_ chip: String = "Apple M5 Pro") -> CPUBenchmarkMachine {
    CPUBenchmarkMachine(chip: chip, model: "Mac17,8", logicalCores: 18,
                        coreTypes: [.init(name: "Super", cores: 6), .init(name: "Performance", cores: 12)], memoryBytes: 48 << 30)
}

private func record(at time: TimeInterval, machine: CPUBenchmarkMachine = machine(), optimized: Bool = true,
                    start: ThermalState = .nominal, end: ThermalState = .nominal) -> CPUBenchmarkResult {
    let workloads = CPUWorkload.allCases.map {
        CPUWorkloadResult(workload: $0, single: CPUBenchmarkMeasurement(workers: 1, repeats: [10, 11, 9]),
                          multi: CPUBenchmarkMeasurement(workers: 18, repeats: [120, 100, 110]))
    }
    return CPUBenchmarkResult(date: Date(timeIntervalSince1970: time), suiteVersion: CPUBenchmark.suiteVersion,
                              configuration: .standard, machine: machine, osVersion: "macOS 27.2 (27C61)", appVersion: "otm 0.1.0",
                              optimized: optimized, thermalStateAtStart: start, thermalStateAtEnd: end, lowPowerMode: false,
                              seconds: 21, workloads: workloads)
}

/// A kernel whose units all pass except one.
private final class FailingKernel: BenchmarkKernel, BenchmarkWorker {
    let failingUnit: Int

    init(failingUnit: Int) {
        self.failingUnit = failingUnit
    }

    var workPerUnit: Double { 1 }
    func withWorker(_ index: Int, of count: Int, _ body: (any BenchmarkWorker) -> Void) { body(self) }
    func run(unit index: Int) -> Bool { index != failingUnit }
}

struct CPUBenchmarkTests {
    /// The standard workloads' answers. If this fails, the workloads changed:
    /// bump `CPUBenchmark.suiteVersion` and update the pinned values.
    @Test func standardWorkloadsArePinned() {
        let standard = CPUBenchmarkConfiguration.standard
        #expect(CPUBenchmark.suiteVersion == 1)
        #expect(standard.hashBytes == 256 << 10 && standard.matrixSize == 64 && standard.memoryBytes == 256 << 20)
        var random = BenchmarkRandom(state: standard.seed)
        #expect(random.next() == 0x57DE_D05E_A9F2_D938)
        #expect(HashKernel(bytes: standard.hashBytes, seed: standard.seed).expected == 0x8010_69C6_3EB2_A58D)
        #expect(MatrixKernel(size: standard.matrixSize, seed: standard.seed).expected == 0x3467_5A6F_93BE_9678)
        #expect(standard.plannedSeconds == 21)
    }

    @Test func everyUnitChecksOutWhereverItStarts() {
        let hash = HashKernel(bytes: 4 << 10, seed: 7)
        hash.withWorker(0, of: 1) { worker in
            #expect((0..<200).allSatisfy { worker.run(unit: $0) })
        }

        let matrix = MatrixKernel(size: 12, seed: 7)
        matrix.withWorker(0, of: 1) { worker in
            #expect((0..<40).allSatisfy { worker.run(unit: $0) })
        }

        let memory = MemoryKernel(bytes: 256 << 10, chunkBytes: 16 << 10, seed: 7)
        #expect(memory.chunkCount == 16)
        for index in 0..<5 {
            memory.withWorker(index, of: 5) { worker in
                #expect((0..<40).allSatisfy { worker.run(unit: $0) })
            }
        }
    }

    @Test func smallestWorkloadsKeepTheirGeometry() {
        let kernels: [any BenchmarkKernel] = [
            HashKernel(bytes: 0, seed: 7),
            MatrixKernel(size: 0, seed: 7),
            MemoryKernel(bytes: 0, chunkBytes: 0, seed: 7),
        ]
        #expect(kernels.map(\.workPerUnit) == [64, 2, 32])
        for kernel in kernels {
            kernel.withWorker(0, of: 1) { worker in
                #expect((0..<20).allSatisfy { worker.run(unit: $0) })
            }
        }
    }

    /// Shared inputs serve overlapping workers without sharing their scratch buffers.
    @Test func workersBorrowSharedInputsConcurrently() async {
        let kernels: [any BenchmarkKernel] = [
            HashKernel(bytes: 4 << 10, seed: 7),
            MatrixKernel(size: 12, seed: 7),
            MemoryKernel(bytes: 256 << 10, chunkBytes: 16 << 10, seed: 7),
        ]
        for kernel in kernels {
            await withTaskGroup(of: Bool.self) { group in
                for index in 0..<5 {
                    group.addTask {
                        var passed = false
                        kernel.withWorker(index, of: 5) { worker in
                            passed = (0..<80).allSatisfy { worker.run(unit: $0) }
                        }
                        return passed
                    }
                }
                for await passed in group { #expect(passed) }
            }
            // A later pass borrows the same storage after every earlier worker has returned.
            kernel.withWorker(0, of: 1) { worker in
                #expect((0..<80).allSatisfy { worker.run(unit: $0) })
            }
        }
    }

    @Test func otherInputsGiveOtherAnswers() {
        #expect(HashKernel(bytes: 4 << 10, seed: 1).expected != HashKernel(bytes: 4 << 10, seed: 2).expected)
        #expect(MatrixKernel(size: 8, seed: 1).expected != MatrixKernel(size: 8, seed: 2).expected)
        #expect(HashKernel(bytes: 4 << 10, seed: 1).expected != HashKernel(bytes: 8 << 10, seed: 1).expected)
    }

    @Test func aWrongResultStopsThePass() {
        let phase = CPUBenchmarkPhase(workload: .integer, workers: 2, isMulti: true)
        #expect(throws: CPUBenchmarkError.verificationFailed(.integer)) {
            try CPUBenchmark.pass(phase, kernel: FailingKernel(failingUnit: 3), seconds: 1, cancellation: nil)
        }
        let passed = try? CPUBenchmark.pass(phase, kernel: FailingKernel(failingUnit: -1), seconds: 0.02, cancellation: nil)
        #expect((passed?.work ?? 0) > 0)
        #expect((passed?.seconds ?? 0) > 0)
    }

    @Test func runsEveryPhaseAndReportsProgress() throws {
        var reports: [CPUBenchmarkProgress] = []
        let result = try CPUBenchmark.run(configuration: quick, workers: 2, appVersion: "tests") { reports.append($0) }

        #expect(result.workloads.map(\.workload) == CPUWorkload.allCases)
        for workload in result.workloads {
            #expect(workload.single.workers == 1)
            #expect(workload.multi.workers == 2)
            #expect(workload.single.repeats.count == quick.repeats)
            #expect(workload.multi.repeats.count == quick.repeats)
            #expect(workload.single.median > 0 && workload.multi.median > 0)
        }
        #expect(result.suiteVersion == CPUBenchmark.suiteVersion)
        #expect(result.configuration == quick)
        #expect(result.optimized == CPUBenchmark.isOptimizedBuild)
        #expect(result.appVersion == "tests")
        #expect(result.osVersion.hasPrefix("macOS "))
        #expect(result.historyKey == CPUBenchmarkMachine.current().key)
        #expect(result.seconds > 0)

        // Each phase in order, fractions rising to the end.
        var phases: [CPUBenchmarkPhase] = []
        for report in reports where phases.last != report.phase { phases.append(report.phase) }
        #expect(phases == CPUBenchmark.phases(workers: 2))
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        #expect(reports.first?.fraction == 0)
        #expect(abs((reports.last?.fraction ?? 0) - 1) < 1e-9)
        #expect(reports.last?.multi.count == CPUWorkload.allCases.count)
    }

    @Test func phasesRunOneWorkerFirst() {
        let phases = CPUBenchmark.phases(workers: 6)
        #expect(phases.map(\.workers) == [1, 1, 1, 6, 6, 6])
        #expect(phases.map(\.isMulti) == [false, false, false, true, true, true])
        #expect(phases.map(\.workload) == CPUWorkload.allCases + CPUWorkload.allCases)
        #expect(CPUBenchmark.phases(workers: 0).last?.workers == 1)
    }

    @Test func aCancelledRunStops() {
        let cancellation = CPUBenchmarkCancellation()
        cancellation.cancel()
        #expect(throws: CPUBenchmarkError.cancelled) {
            try CPUBenchmark.run(configuration: quick, workers: 2, appVersion: "tests", cancellation: cancellation)
        }
    }

    /// The cancel lands as the warm-up ends, with the run held there, so the
    /// first timed repeat starts cancelled. How the run then stopped is read
    /// from the cancellation, never from a clock that a loaded Mac stretches.
    @Test func cancellingTheTaskStopsAMeasurement() async {
        var long = quick
        long.repeatSeconds = 30
        let cancellation = CPUBenchmarkCancellation()
        let gate = ProgressGate(holdingAt: 1)
        // As the app runs it: a typed catch inside a task.
        let task = Task { () async -> CPUBenchmarkError? in
            defer { gate.runEnded() }
            do throws(CPUBenchmarkError) {
                _ = try await CPUBenchmark.measure(configuration: long, workers: 2, appVersion: "tests", cancellation: cancellation) {
                    gate.report(fraction: $0.fraction)
                }
                return nil
            } catch {
                return error
            }
        }
        let held = await gate.waitUntilHeld()
        task.cancel()
        gate.open()
        #expect(held, "the run reached its first timed repeat")
        #expect(await task.value == .cancelled)
        // Its one worker had 30 s to run: it saw the cancel and stopped partway.
        #expect(cancellation.stoppedWorkers == 1, "the worker stops when cancelled rather than running out the repeat")
        #expect(gate.reportsAfterHold == 0, "no repeat finishes after the cancel")
    }

    @Test func summarisesRepeats() {
        let odd = CPUBenchmarkMeasurement(workers: 1, repeats: [9, 12, 10])
        #expect(odd.median == 10)
        #expect(abs(odd.spread - 0.3) < 1e-12)
        let even = CPUBenchmarkMeasurement(workers: 4, repeats: [40, 36, 44, 38])
        #expect(even.median == 39)
        #expect(CPUBenchmarkMeasurement(workers: 1, repeats: []).median == 0)
        #expect(CPUBenchmarkMeasurement(workers: 1, repeats: []).spread == 0)

        let result = CPUWorkloadResult(workload: .memory, single: odd, multi: even)
        #expect(abs(result.scaling - 3.9) < 1e-12)
        #expect(abs(result.efficiency - 0.975) < 1e-12)
    }

    @Test func formatsInDecimalUnits() {
        #expect(CPUWorkload.integer.format(12_400_000_000) == "12.4 GB/s")
        #expect(CPUWorkload.memory.format(302_000_000_000) == "302 GB/s")
        #expect(CPUWorkload.floatingPoint.format(1_790_000_000) == "1.79 GFLOP/s")
        #expect(CPUWorkload.floatingPoint.format(950) == "950 FLOP/s")
        #expect(CPUWorkload.integer.format(.nan) == "—")
    }

    @Test func describesTheMachine() {
        #expect(machine().coreSummary == "6 Super + 12 Performance cores")
        #expect(machine().key == "Mac17,8|Apple M5 Pro|18")
        let vm = CPUBenchmarkMachine(chip: "Apple M5 Pro (Virtual)", model: nil, logicalCores: 6,
                                     coreTypes: [.init(name: "Standard", cores: 6)], memoryBytes: 8 << 30)
        #expect(vm.coreSummary == "6 cores")
    }

    @Test func tellsWhichResultsCompare() {
        let base = record(at: 1)
        #expect(base.isComparable(with: record(at: 2)))
        #expect(!base.isComparable(with: record(at: 2, optimized: false)))
        var smaller = record(at: 3)
        smaller.configuration.matrixSize = 32
        #expect(!base.isComparable(with: smaller))
        #expect(record(at: 1, start: .nominal, end: .serious).worstThermalState == .serious)
        #expect(record(at: 1, start: .fair, end: .nominal).worstThermalState == .fair)
    }

    @Test func keepsTheLastTenOnEachMac() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otm-cpubench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = SpeedTestHistory<CPUBenchmarkResult>(file: folder.appendingPathComponent("cpu-benchmark.json"), keptPerKey: 10,
                                                           keptKeys: 5)
        for time in 1...12 { try history.append(record(at: TimeInterval(time))) }
        try history.append(record(at: 13, machine: machine("Apple M4")))

        let kept = history.load()
        #expect(history.results(for: machine().key).map(\.date.timeIntervalSince1970) == (3...12).reversed().map(TimeInterval.init))
        #expect(history.results(for: machine("Apple M4").key).count == 1)
        #expect(kept.first == record(at: 13, machine: machine("Apple M4")))
        #expect(SpeedTestHistory<CPUBenchmarkResult>.cpuBenchmark.file.path.hasSuffix("OpenTaskManager/SpeedTests/cpu-benchmark.json"))
        #expect(SpeedTestHistory<CPUBenchmarkResult>.cpuBenchmark.keptPerKey == 10)
    }
}
