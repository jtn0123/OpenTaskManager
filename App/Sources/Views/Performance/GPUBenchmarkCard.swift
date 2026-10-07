import OTMKit
import SwiftUI

/// "Benchmark" on the GPU detail: when asked, times FP32 compute, memory and
/// fill-rate workloads in Metal on the GPU's own clock, and shows each one's
/// speed and spread, with the last runs on this Mac. It has no inputs and
/// reads only `GPUBenchmarkStore`, so it redraws with the run's progress,
/// not per tick. Without a Metal GPU, or when the GPU can't run or time the
/// workloads (as a VM's might not), it says so in place of the figures. The
/// figures come first and the workloads' description folds away under
/// Methodology; a figure whose GPU time looked short says so at the figure.
struct GPUBenchmarkCard: View, Equatable {
    var body: some View {
        let store = GPUBenchmarkStore.shared
        let run = store.running
        let results = store.history
        Card(tint: Theme.gpu) {
            header(run: run, store: store)
            if let run {
                let progress = store.progress
                GPUBenchmarkRunning(text: progress.map { "\($0.workload.title)…" } ?? "Compiling the shaders…", started: run.started,
                                    expected: "about \(Self.plannedSeconds) s", fraction: progress?.fraction ?? 0)
                tiles(result: nil, progress: progress)
            } else {
                if store.device == nil {
                    SpeedTestFailure(text: GPUBenchmarkError.noDevice.message)
                } else if let failure = store.failure {
                    SpeedTestFailure(text: failure)
                }
                if let latest = results.first {
                    tiles(result: latest, progress: nil)
                    Text(Self.tested(latest))
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if results.count > 1 {
                GPUBenchmarkHistory(results: results)
            }
            MethodologyDisclosure(preview: "FP32 compute, memory and fill rate, timed by the GPU · about \(Self.plannedSeconds) s") {
                Text(caption(store.device))
                Text("The GPU runs the same shaders and times them itself in any build, so a debug build's figures match a release build's.")
                if run == nil, let latest = results.first {
                    if let note = latest.timingNote {
                        Label(note, systemImage: "clock.badge.exclamationmark")
                    }
                    Text(Self.details(latest))
                }
            }
        }
        .task { store.handleLaunchArgument() }
    }

    private static var plannedSeconds: Int {
        Int(GPUBenchmarkConfiguration.standard.plannedSeconds.rounded())
    }

    private func caption(_ device: GPUBenchmarkDevice?) -> String {
        let standard = GPUBenchmarkConfiguration.standard
        let target = device.map { device in device.name + (device.cores.map { " (\($0) cores)" } ?? "") } ?? "this Mac's GPU"
        return "Times three fixed Metal workloads (version \(GPUBenchmark.suiteVersion)) on \(target): chains of 32-bit fused "
            + "multiply–adds, reading a \(Format.wholeBytes(UInt64(standard.memoryBytes))) buffer, and blending full-screen layers "
            + "into an offscreen \(standard.fillSize) × \(standard.fillSize) image. Each warms up, then runs \(standard.repeats) "
            + "repeats timed by the GPU itself, and every result is checked. It keeps the GPU busy for about \(Self.plannedSeconds) s."
    }

    private func header(run: GPUBenchmarkStore.Run?, store: GPUBenchmarkStore) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Benchmark", systemImage: "stopwatch")
                .font(.headline)
                .foregroundStyle(Theme.gpu)
            if !CPUBenchmark.isOptimizedBuild { DebugBuildBadge() }
            Spacer(minLength: 8)
            if run != nil {
                Button("Cancel") { store.cancel() }
                    .help("Stop the benchmark before its next batch of GPU work")
            } else {
                Button("Run Benchmark") { store.start() }
                    .disabled(store.device == nil)
                    .help(store.device == nil ? "There's no Metal GPU to benchmark"
                        : "Measure this GPU's compute, memory and fill-rate speed for about \(Self.plannedSeconds) s")
            }
        }
    }

    /// Under the figures: when, on what, and anything that held them back.
    private static func tested(_ result: GPUBenchmarkResult) -> String {
        var parts = [
            "Tested \(result.date.formatted(date: .abbreviated, time: .shortened))",
            result.device.summary,
            "thermal state \(result.worstThermalState.rawValue)",
        ]
        if result.lowPowerMode { parts.append("Low Power Mode on") }
        return parts.joined(separator: " · ")
    }

    /// In the methodology: the build, versions, and how the figures are taken.
    private static func details(_ result: GPUBenchmarkResult) -> String {
        let parts = [
            result.optimized ? "Release build" : "Debug build",
            "workloads v\(result.suiteVersion)",
            result.osVersion,
            result.appVersion,
        ]
        return parts.joined(separator: " · ") + ". Medians of \(result.configuration.repeats) repeats, each timed by the GPU "
            + "from start to finish; ± is half the gap between the slowest and fastest."
    }

    // MARK: - Figures

    /// A tile per workload: its figure once measured, "measuring…" while it
    /// runs, a dash until then.
    private func tiles(result: GPUBenchmarkResult?, progress: GPUBenchmarkProgress?) -> some View {
        FillGrid(minimum: 165, spacing: 10) {
            ForEach(GPUWorkload.allCases, id: \.self) { workload in
                GPUBenchmarkTile(workload: workload, measurement: result?.result(workload) ?? progress?.measured[workload],
                                 measuring: progress?.workload == workload)
            }
        }
    }
}

/// One workload's median and spread. A figure whose GPU time looked short
/// (as a VM's can) is drawn in the secondary colour with "Timing
/// unverified" under it, the reason and the timings in its tooltip.
private struct GPUBenchmarkTile: View {
    let workload: GPUWorkload
    let measurement: GPUBenchmarkMeasurement?
    let measuring: Bool

    var body: some View {
        let caveat: BenchmarkFigureCaveat? = measurement?.gpuTimeLooksShort == true ? .timingUnverified : nil
        VStack(alignment: .leading, spacing: 4) {
            Text(workload.title).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1)
                .help(workload.summary.prefix(1).uppercased() + workload.summary.dropFirst())
            Text(measurement.map { workload.format($0.median) } ?? (measuring ? "measuring…" : "—"))
                .font(.title3.weight(caveat == nil ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(measurement == nil || caveat != nil ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
                .help(measurement.map(timing) ?? "")
            if let caveat, let measurement {
                FigureCaveatLabel(caveat: caveat, detail: repeatTiming(measurement))
            }
            Text(footer).font(.explanation).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // The row's height, so a tile with a caveat's extra line doesn't stand taller than its neighbours.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.gpu.fillShade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(caveat == nil ? Theme.gpu.opacity(0.22) : BenchmarkLook.caution.opacity(0.45)))
        .accessibilityElement(children: .combine)
    }

    /// "±0.4% over 5 repeats".
    private var footer: String {
        guard let measurement, !measurement.repeats.isEmpty else { return " " }
        return "±\(spread(measurement.spread / 2)) over \(measurement.repeats.count) repeats"
    }

    /// What a repeat held and how long it took, on the GPU and from commit to completion.
    private func timing(_ measurement: GPUBenchmarkMeasurement) -> String {
        let units = workload == .fill ? "render passes" : "dispatches"
        return "Each repeat: \(measurement.unitsPerRepeat) \(units), \(repeatTiming(measurement))"
    }

    /// "449 ms on the GPU, 492 ms from commit to completion".
    private func repeatTiming(_ measurement: GPUBenchmarkMeasurement) -> String {
        "\(milliseconds(measurement.medianGPUSeconds)) on the GPU, \(milliseconds(measurement.medianWallSeconds)) from commit to completion"
    }
}

/// "0.4%", or "3%" once it's large.
private func spread(_ fraction: Double) -> String {
    Format.percent(fraction, digits: fraction < 0.1 ? 1 : 0)
}

private func milliseconds(_ seconds: Double) -> String {
    "\(Format.fixed(seconds * 1000, 0)) ms"
}

/// The last runs on this Mac, each workload in the unit that suits its
/// column. A figure whose GPU time looked short carries the caution mark,
/// in the secondary colour, as the card's tile does.
private struct GPUBenchmarkHistory: View {
    let results: [GPUBenchmarkResult]

    var body: some View {
        let scales = GPUWorkload.allCases.map(scale)
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent runs on this Mac").font(.callout.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                // Each workload's unit goes under its name, so the columns
                // stay narrow enough for the smallest window.
                GridRow(alignment: .lastTextBaseline) {
                    Text("When").gridColumnAlignment(.leading)
                    ForEach(GPUWorkload.allCases.indices, id: \.self) { index in
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(GPUWorkload.allCases[index].title)
                            Text(scales[index].unit)
                        }
                    }
                    Text("Build").gridColumnAlignment(.leading)
                    Text("")
                }
                .font(.metadata)
                ForEach(results) { result in
                    GridRow {
                        Text(result.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .fixedSize()
                        ForEach(GPUWorkload.allCases.indices, id: \.self) { index in
                            figure(result.result(GPUWorkload.allCases[index]), divisor: scales[index].divisor)
                        }
                        Text(result.optimized ? "release" : "debug")
                        Text(note(result)).gridColumnAlignment(.leading)
                    }
                    .font(.tableText)
                    .help("\(result.appVersion) · \(result.osVersion) · thermal state \(result.worstThermalState.rawValue)")
                }
            }
            .foregroundStyle(.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
            if results.contains(where: { !$0.shortTimedWorkloads.isEmpty }) {
                FigureCaveatFootnote(caveat: .timingUnverified)
            }
        }
    }

    @ViewBuilder
    private func figure(_ measurement: GPUBenchmarkMeasurement?, divisor: Double) -> some View {
        if let measurement, measurement.gpuTimeLooksShort {
            HStack(spacing: 3) {
                FigureCaveatMark(caveat: .timingUnverified)
                Text(number(measurement.median, divisor))
            }
            .help(BenchmarkFigureCaveat.timingUnverified.explanation)
        } else {
            Text(measurement.map { number($0.median, divisor) } ?? "—")
        }
    }

    /// TFLOP/s or GFLOP/s (GB/s or MB/s, Gpixel/s or Mpixel/s), by the column's largest figure.
    private func scale(_ workload: GPUWorkload) -> (unit: String, divisor: Double) {
        workload.scale(results.compactMap { $0.result(workload)?.median }.max() ?? 0)
    }

    private func number(_ value: Double, _ divisor: Double) -> String {
        let scaled = value / divisor
        return Format.fixed(scaled, scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2)
    }

    /// What sets a run apart from the newest: other workloads or heat. A
    /// GPU timing that looked short is marked on its figure instead.
    private func note(_ result: GPUBenchmarkResult) -> String {
        var notes: [String] = []
        if let newest = results.first, result.suiteVersion != newest.suiteVersion { notes.append("v\(result.suiteVersion)") }
        if result.worstThermalState != .nominal { notes.append(result.worstThermalState.rawValue) }
        if result.lowPowerMode { notes.append("low power") }
        return notes.joined(separator: ", ")
    }
}

/// Beside the title in a debug build: a debug build's figures match a
/// release build's here, but the reader should know which they're seeing.
private struct DebugBuildBadge: View {
    var body: some View {
        Text("Debug build")
            .font(.metadata)
            .foregroundStyle(.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45)))
            .fixedSize()
            .help("The GPU runs the same shaders in any build and times them itself, so a debug build's figures match a release build's.")
    }
}

/// A run in progress: what it's measuring, the time so far, and how far it is.
private struct GPUBenchmarkRunning: View {
    var text: String
    var started: Date
    var expected: String
    var fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(text).font(.callout)
                Spacer(minLength: 8)
                // The system ticks this text over; the view isn't redrawn.
                Text(timerInterval: started...started.addingTimeInterval(24 * 3600), countsDown: false)
                    .monospacedDigit()
                    .font(.callout)
                Text("of \(expected)").font(.metadata).foregroundStyle(.secondaryText)
            }
            ProgressView(value: min(max(fraction, 0), 1)).tint(Theme.gpu)
        }
    }
}
