import Darwin
import Foundation
import OTMKit

// `otm cpubench --sustained [2|5]`: the CPU detail's sustained run, saved
// to the same history (SpeedTests/cpu-sustained.json).

/// Runs the floating-point workload on every core for 2 or 5 minutes and
/// reports how much of its first window's speed it held. Ctrl-C stops it;
/// a stopped run isn't saved.
func cpuSustainedCommand(_ options: Options) {
    let minutes = options.positional.first.map { argument in
        guard let minutes = Int(argument), CPUSustainedConfiguration.offeredMinutes.contains(minutes) else {
            fail("--sustained runs for 2 or 5 minutes, not \(argument)")
        }
        return minutes
    } ?? CPUSustainedConfiguration.offeredMinutes[0]
    let configuration = CPUSustainedConfiguration.standard(minutes: minutes)

    let cancellation = interruptCancels()
    defer { cancellation.interrupt.cancel() }

    let showsProgress = isatty(STDERR_FILENO) == 1 && !options.json
    if !options.json {
        let notice = "Running the floating-point workload on \(CPUBenchmark.defaultWorkers) workers for \(configuration.durationText), "
            + "timed in \(Format.timeSpan(configuration.windowSeconds)) windows. Other work on this Mac lowers the figures; "
            + "Ctrl-C stops it.\n"
        FileHandle.standardError.write(Data(notice.utf8))
    }
    let context = benchmarkContext()
    var result: CPUSustainedResult
    do throws(CPUBenchmarkError) {
        result = try CPUSustained.run(configuration: configuration, appVersion: "otm \(version)",
                                      cancellation: cancellation.token) { progress in
            guard showsProgress else { return }
            let latest = progress.windows.last.map { " · last window \(configuration.workload.format($0.throughput))" } ?? ""
            let line = progress.warmingUp ? "Warming up…"
                : "\(CPUSustainedSummary.clock(progress.elapsed)) of \(CPUSustainedSummary.clock(progress.plannedSeconds))\(latest)"
            FileHandle.standardError.write(Data("\u{1B}[2K\r\(line)".utf8))
        }
    } catch {
        if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
        fail(error == .cancelled ? "The sustained run was stopped, so nothing was saved." : error.message)
    }
    if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
    result.context = context.ended()
    _ = try? SpeedTestHistory.cpuSustained.append(result)
    if options.json {
        printJSON(result)
    } else {
        print(cpuSustainedSummary(result))
    }
}

func cpuSustainedSummary(_ result: CPUSustainedResult) -> String {
    let machine = result.machine
    let configuration = result.configuration
    let workload = configuration.workload
    let build = result.optimized ? "release build" : "debug build"
    var lines = [
        "\(machine.chip)\(machine.model.map { " (\($0))" } ?? "") · \(machine.coreSummary) · \(Format.wholeBytes(machine.memoryBytes))",
        "\(result.appVersion), \(build) · \(result.osVersion) · sustained run v\(result.suiteVersion)",
        "",
    ]
    guard let summary = result.summary else { return (lines + ["No window was measured."]).joined(separator: "\n") }
    lines += [
        "\(summary.heldText).",
        pad("First window", 16) + workload.format(summary.first),
        pad("Sustained", 16) + workload.format(summary.sustained) + "  (median of the last \(summary.sustainedWindows) windows)",
        "",
        pad("WINDOW", 10) + pad("FROM", 8) + pad("THROUGHPUT", 18) + pad("SLICES", 26) + "THERMAL",
    ]
    for (index, window) in result.windows.enumerated() {
        let slices = window.slices.isEmpty ? "—"
            : "\(workload.format(window.slices.min() ?? 0)) to \(workload.format(window.slices.max() ?? 0))"
        lines.append(pad("\(index + 1)", 10) + pad(CPUSustainedSummary.clock(window.start), 8)
            + pad(workload.format(window.throughput), 18) + pad(slices, 26) + window.thermalState.rawValue)
    }
    lines += [
        "",
        summary.changeText(format: workload.format, windowSeconds: configuration.windowSeconds),
        summary.thermalText + (result.lowPowerMode ? " Low Power Mode was on." : ""),
        contextLine(result.context),
        "\(workload.title): \(workload.summary), on \(result.workers) workers, after a \(Format.fixed(configuration.warmUpSeconds, 1)) s "
            + "warm-up. Took \(Format.fixed(result.seconds, 0)) s.",
        "A change in speed alone doesn't say why: heat, other work and power settings can each slow a run.",
    ]
    if !result.optimized {
        lines.append("This debug build runs the workload far slower than a release build (make cli), so its figures don't compare.")
    }
    return lines.joined(separator: "\n")
}
