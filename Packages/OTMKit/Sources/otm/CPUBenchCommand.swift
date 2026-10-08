import Darwin
import Foundation
import OTMKit

// `otm cpubench`: the CPU benchmark the CPU page runs, saved to the same
// history, `otm cpubench --sustained`: its sustained run, and `otm cpubench
// layout`: the chip layout that page shows.

/// `otm cpubench [layout] [--json]`, `otm cpubench --sustained [2|5] [--json]`.
/// Ctrl-C stops a run cleanly.
func cpuBenchCommand(_ options: Options) {
    if options.positional.first == "layout" {
        let layout = ChipLayoutReader.read()
        if options.json {
            printJSON(layout)
        } else {
            print(chipLayoutSummary(layout))
        }
        return
    }
    if options.sustained {
        cpuSustainedCommand(options)
        return
    }

    let cancellation = interruptCancels()
    defer { cancellation.interrupt.cancel() }

    let showsProgress = isatty(STDERR_FILENO) == 1 && !options.json
    if !options.json {
        let seconds = Int(CPUBenchmarkConfiguration.standard.plannedSeconds.rounded())
        let notice = "Running integer, floating-point and memory workloads on one worker, then on \(CPUBenchmark.defaultWorkers), "
            + "for about \(seconds) s. Other work on this Mac lowers the figures.\n"
        FileHandle.standardError.write(Data(notice.utf8))
    }
    let context = benchmarkContext()
    var result: CPUBenchmarkResult
    do throws(CPUBenchmarkError) {
        result = try CPUBenchmark.run(appVersion: "otm \(version)", cancellation: cancellation.token) { progress in
            guard showsProgress else { return }
            let who = progress.phase.isMulti ? "\(progress.phase.workers) workers" : "one worker"
            let line = "\(progress.phase.workload.title), \(who): \(Format.percent(progress.fraction)) of the run"
            FileHandle.standardError.write(Data("\u{1B}[2K\r\(line)".utf8))
        }
    } catch {
        if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
        fail(error.message)
    }
    if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
    result.context = context.ended()
    _ = try? SpeedTestHistory.cpuBenchmark.append(result)
    if options.json {
        printJSON(result)
    } else {
        print(cpuBenchSummary(result))
    }
}

/// Ctrl-C cancels the CPU benchmark or sustained run in hand instead of
/// killing `otm`, so it stops cleanly between units of work.
func interruptCancels() -> (token: CPUBenchmarkCancellation, interrupt: any DispatchSourceSignal) {
    let cancellation = CPUBenchmarkCancellation()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { cancellation.cancel() }
    interrupt.resume()
    return (cancellation, interrupt)
}

/// The Mac's state before a test, saved with its result. `otm` keeps no
/// sampler, so the CPU's load comes from a second's probe of its tick counters.
func benchmarkContext() -> BenchmarkContext {
    BenchmarkContextReader.atStart(appVersion: "otm \(version)")
}

/// "Started on the power adapter · thermal nominal · CPU 3% busy before · 21.3 GB memory available."
func contextLine(_ context: BenchmarkContext?) -> String {
    guard let context, !context.conditionsLine.isEmpty else { return BenchmarkContext.notRecorded + "." }
    return "Started \(context.conditionsLine)."
}

func cpuBenchSummary(_ result: CPUBenchmarkResult) -> String {
    let machine = result.machine
    let build = result.optimized ? "release build" : "debug build"
    let workers = result.workloads.first?.multi.workers ?? 0
    var lines = [
        "\(machine.chip)\(machine.model.map { " (\($0))" } ?? "") · \(machine.coreSummary) · \(Format.wholeBytes(machine.memoryBytes))",
        "\(result.appVersion), \(build) · \(result.osVersion) · workloads v\(result.suiteVersion)",
        "",
        pad("", 16) + pad("ONE WORKER", 20) + pad("ALL CORES (\(workers))", 20) + "SCALING",
    ]
    for workload in result.workloads {
        let single = workload.workload.format(workload.single.median) + "  ±" + Format.percent(workload.single.spread / 2)
        let multi = workload.workload.format(workload.multi.median) + "  ±" + Format.percent(workload.multi.spread / 2)
        let scaling = "×\(Format.fixed(workload.scaling, 1)) (\(Format.percent(workload.efficiency)) per worker)"
        lines.append(pad(workload.workload.title, 16) + pad(single, 20) + pad(multi, 20) + scaling)
    }
    let repeats = result.configuration.repeats
    lines += [
        "",
        "Medians of \(repeats) timed repeats after a warm-up; ± is half the gap between the slowest and fastest.",
    ]
    for workload in CPUWorkload.allCases {
        lines.append("\(workload.title): \(workload.summary).")
    }
    let thermal = result.thermalStateAtStart == result.thermalStateAtEnd
        ? "Thermal state \(result.thermalStateAtStart.rawValue) throughout"
        : "Thermal state \(result.thermalStateAtStart.rawValue) at the start, \(result.thermalStateAtEnd.rawValue) at the end"
    lines.append("\(thermal)\(result.lowPowerMode ? ", Low Power Mode on" : ""). Took \(Format.fixed(result.seconds, 1)) s.")
    lines.append(contextLine(result.context))
    lines.append("macOS chooses which cores run the workers; nothing pins them to a kind of core.")
    if !result.optimized {
        lines.append("This debug build runs the workloads far slower than a release build (make cli), so its figures don't compare.")
    }
    return lines.joined(separator: "\n")
}

func chipLayoutSummary(_ layout: ChipLayout) -> String {
    var lines = [
        "\(layout.chip)\(layout.model.map { " (\($0))" } ?? "") · \(layout.architecture) · \(layout.coreSummary)",
        "",
        pad("CORE TYPE", 14) + pad("CORES", 7, right: true) + pad("CLUSTERS", 10, right: true) + "  " + pad("CPUS", 16)
            + pad("L1 I + D", 18) + "L2",
    ]
    for type in layout.coreTypes {
        let clusters = layout.clusters(of: type.level)
        let cpus = clusters.isEmpty ? "—" : clusters.map { ChipLayout.cpuRanges($0.cpus) }.joined(separator: " | ")
        let l1 = [type.l1InstructionBytes, type.l1DataBytes].map { $0.map { Format.wholeBytes(UInt64($0)) } ?? "—" }.joined(separator: " + ")
        let l2 = type.l2Bytes.map { bytes in
            Format.wholeBytes(UInt64(bytes)) + (type.coresPerL2.map { " per \($0) cores" } ?? "")
        } ?? "—"
        lines.append(pad(type.name, 14) + pad(String(type.physicalCores), 7, right: true)
            + pad(clusters.isEmpty ? "—" : String(clusters.count), 10, right: true) + "  " + pad(cpus, 16) + pad(l1, 18) + l2)
    }
    lines.append("")
    if let l3 = layout.l3Bytes { lines.append(pad("L3 cache", 15) + Format.wholeBytes(UInt64(l3))) }
    if let line = layout.cacheLineBytes { lines.append(pad("Cache line", 15) + "\(line) bytes") }
    for gpu in layout.gpus {
        lines.append(pad("GPU", 15) + gpu.name + (gpu.cores.map { ", \($0) cores" } ?? ", core count not reported"))
    }
    if let engine = layout.neuralEngine {
        lines.append(pad("Neural Engine", 15) + (engine.cores.map { "\($0) cores" } ?? "present, core count not reported"))
    }
    lines.append(pad("Memory", 15) + Format.wholeBytes(layout.memoryBytes) + (layout.memoryType.map { " \($0)" } ?? ""))
    lines += ["", ChipLayoutReader.sources]
    return lines.joined(separator: "\n")
}
