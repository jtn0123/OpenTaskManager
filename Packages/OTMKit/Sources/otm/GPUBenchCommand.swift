import Darwin
import Foundation
import OTMKit

// `otm gpubench`: the GPU benchmark the GPU page runs, saved to the same history.

/// `otm gpubench [--json]`. Ctrl-C stops a run before its next submission.
func gpuBenchCommand(_ options: Options) {
    let cancellation = GPUBenchmarkCancellation()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { cancellation.cancel() }
    interrupt.resume()
    defer { interrupt.cancel() }

    let showsProgress = isatty(STDERR_FILENO) == 1 && !options.json
    if !options.json {
        let seconds = Int(GPUBenchmarkConfiguration.standard.plannedSeconds.rounded())
        let notice = "Running FP32 compute, memory and fill-rate workloads on the GPU for about \(seconds) s. "
            + "Other work on the GPU lowers the figures.\n"
        FileHandle.standardError.write(Data(notice.utf8))
    }
    let result: GPUBenchmarkResult
    do throws(GPUBenchmarkError) {
        result = try GPUBenchmark.run(appVersion: "otm \(version)", cancellation: cancellation) { progress in
            guard showsProgress else { return }
            let line = "\(progress.workload.title): \(Format.percent(progress.fraction)) of the run"
            FileHandle.standardError.write(Data("\u{1B}[2K\r\(line)".utf8))
        }
    } catch {
        if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
        fail(error.message)
    }
    if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
    _ = try? SpeedTestHistory.gpuBenchmark.append(result)
    if options.json {
        printJSON(result)
    } else {
        print(gpuBenchSummary(result))
    }
}

func gpuBenchSummary(_ result: GPUBenchmarkResult) -> String {
    let device = result.device
    let build = result.optimized ? "release build" : "debug build"
    let memory = device.unifiedMemory ? "unified memory" : "its own memory"
    var lines = [
        "\(device.summary)\(device.model.map { " (\($0))" } ?? "") · \(memory)",
        "\(result.appVersion), \(build) · \(result.osVersion) · workloads v\(result.suiteVersion)",
        "",
        pad("", 16) + pad("MEDIAN", 18) + pad("SPREAD", 10) + pad("GPU TIME", 12) + "COMMIT TO DONE",
    ]
    for workload in result.workloads {
        let measurement = workload.measurement
        // A figure whose GPU time looked short says so on its own row, not only in the note below.
        let flag = measurement.gpuTimeLooksShort ? "   " + BenchmarkFigureCaveat.timingUnverified.title.lowercased() : ""
        lines.append(pad(workload.workload.title, 16) + pad(workload.workload.format(measurement.median), 18)
            + pad("±" + spread(measurement.spread / 2), 10) + pad(milliseconds(measurement.medianGPUSeconds), 12)
            + milliseconds(measurement.medianWallSeconds) + flag)
    }
    lines += [
        "",
        "Medians of \(result.configuration.repeats) timed repeats after a warm-up, each a command buffer timed by the GPU "
            + "(gpuStartTime to gpuEndTime); ± is half the gap between the slowest and fastest. Commit to done adds "
            + "scheduling and the wake-up. Every result was checked.",
    ]
    for workload in GPUWorkload.allCases {
        lines.append("\(workload.title): \(workload.summary).")
    }
    if let note = result.timingNote { lines.append(note) }
    let thermal = result.thermalStateAtStart == result.thermalStateAtEnd
        ? "Thermal state \(result.thermalStateAtStart.rawValue) throughout"
        : "Thermal state \(result.thermalStateAtStart.rawValue) at the start, \(result.thermalStateAtEnd.rawValue) at the end"
    lines.append("\(thermal)\(result.lowPowerMode ? ", Low Power Mode on" : ""). Took \(Format.fixed(result.seconds, 1)) s.")
    return lines.joined(separator: "\n")
}

/// "0.4%", or "3%" once it's large.
private func spread(_ fraction: Double) -> String {
    Format.percent(fraction, digits: fraction < 0.1 ? 1 : 0)
}

private func milliseconds(_ seconds: Double) -> String {
    "\(Format.fixed(seconds * 1000, 0)) ms"
}
