import OTMKit
import SwiftUI

/// "Benchmark" on the CPU detail: when asked, times integer, floating-point
/// and memory workloads on one worker and then on one per logical CPU, and
/// shows each one's speed, spread and scaling, with the last runs on this
/// Mac. It has no inputs and reads only `CPUBenchmarkStore`, so it redraws
/// with the run's progress, not per tick.
struct CPUBenchmarkCard: View, Equatable {
    var body: some View {
        let store = CPUBenchmarkStore.shared
        let run = store.running
        let results = store.history
        Card(tint: Theme.cpu) {
            header(run: run, store: store)
            if let run {
                let progress = store.progress
                BenchmarkRunning(text: progress.map(Self.phaseText) ?? "Starting…", started: run.started,
                                 expected: "about \(Self.plannedSeconds) s", fraction: progress?.fraction ?? 0)
                tiles(result: nil, progress: progress, workers: run.workers)
            } else {
                Text(caption)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = store.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let latest = results.first {
                    tiles(result: latest, progress: nil, workers: latest.workloads.first?.multi.workers ?? CPUBenchmark.defaultWorkers)
                    Text(Self.details(latest))
                        .font(.metadata)
                        .foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !CPUBenchmark.isOptimizedBuild {
                Label("This is a debug build: it runs the workloads many times slower than a release build, "
                    + "so its figures don't compare with one.", systemImage: "ant")
                    .font(.callout)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if results.count > 1 {
                CPUBenchmarkHistory(results: results)
            }
        }
        .task { store.handleLaunchArgument() }
    }

    private static var plannedSeconds: Int {
        Int(CPUBenchmarkConfiguration.standard.plannedSeconds.rounded())
    }

    private var caption: String {
        let workers = CPUBenchmark.defaultWorkers
        return "Times three fixed workloads (version \(CPUBenchmark.suiteVersion)): integer hashing in cache, a floating-point "
            + "matrix product and reading a 256 MB buffer, on one worker thread and then on \(workers), one per logical CPU. "
            + "Each warms up, then runs \(CPUBenchmarkConfiguration.standard.repeats) timed repeats, and every result is checked. "
            + "It keeps the CPU busy for about \(Self.plannedSeconds) s. macOS decides which cores the workers run on."
    }

    private func header(run: CPUBenchmarkStore.Run?, store: CPUBenchmarkStore) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Benchmark", systemImage: "stopwatch")
                .font(.headline)
                .foregroundStyle(Theme.cpu)
            Spacer(minLength: 8)
            if run != nil {
                Button("Cancel") { store.cancel() }
                    .help("Stop the benchmark")
            } else {
                Button("Run Benchmark") { store.start() }
                    .help("Measure this Mac's CPU and memory speed for about \(Self.plannedSeconds) s")
            }
        }
    }

    private static func phaseText(_ progress: CPUBenchmarkProgress) -> String {
        let workers = progress.phase.isMulti ? "\(progress.phase.workers) workers" : "one worker"
        return "\(progress.phase.workload.title), \(workers)…"
    }

    /// When, and what the figures depend on.
    private static func details(_ result: CPUBenchmarkResult) -> String {
        var parts = [
            "Tested \(result.date.formatted(date: .abbreviated, time: .shortened))",
            result.optimized ? "release build" : "debug build",
            "workloads v\(result.suiteVersion)",
            result.osVersion,
            result.appVersion,
            "thermal state \(result.worstThermalState.rawValue)",
        ]
        if result.lowPowerMode { parts.append("Low Power Mode on") }
        return parts.joined(separator: " · ") + ". Medians of \(result.configuration.repeats) timed repeats; "
            + "± is half the gap between the slowest and fastest. Scaling is all workers' speed over one worker's."
    }

    // MARK: - Figures

    /// A tile per workload: its figures once measured, "measuring…" while
    /// its phase runs, a dash until then.
    private func tiles(result: CPUBenchmarkResult?, progress: CPUBenchmarkProgress?, workers: Int) -> some View {
        FillGrid(minimum: 165, spacing: 10) {
            ForEach(CPUWorkload.allCases, id: \.self) { workload in
                let measured = result?.result(workload)
                let current = progress?.phase.workload == workload ? progress?.phase : nil
                BenchmarkTile(workload: workload, workers: workers,
                              single: measured?.single ?? progress?.single[workload],
                              multi: measured?.multi ?? progress?.multi[workload],
                              measuringSingle: current.map { !$0.isMulti } ?? false,
                              measuringMulti: current?.isMulti ?? false)
            }
        }
    }
}

/// One workload's speed on one worker and on all, and the scaling between.
private struct BenchmarkTile: View {
    let workload: CPUWorkload
    let workers: Int
    let single: CPUBenchmarkMeasurement?
    let multi: CPUBenchmarkMeasurement?
    let measuringSingle: Bool
    let measuringMulti: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workload.title).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1)
                .help(workload.summary.prefix(1).uppercased() + workload.summary.dropFirst())
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                row("1 worker", single, measuring: measuringSingle)
                row("\(workers) workers", multi, measuring: measuringMulti)
            }
            Text(footer).font(.metadata).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cpu.fillShade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cpu.opacity(0.22)))
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ measurement: CPUBenchmarkMeasurement?, measuring: Bool) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1)
            Text(measurement.map { workload.format($0.median) } ?? (measuring ? "measuring…" : "—"))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(measurement == nil ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
                .help(measurement.map { "Spread ±\(Format.percent($0.spread / 2)) over \($0.repeats.count) repeats" } ?? "")
        }
    }

    /// "×11.4 scaling · ±1% / ±2%".
    private var footer: String {
        guard let single, let multi, single.median > 0 else { return " " }
        let scaling = multi.median / single.median
        return "×\(Format.fixed(scaling, 1)) scaling · ±\(Format.percent(single.spread / 2)) / ±\(Format.percent(multi.spread / 2))"
    }
}

/// The last runs on this Mac: each workload on one worker and on all, in
/// the unit that suits the column.
private struct CPUBenchmarkHistory: View {
    let results: [CPUBenchmarkResult]

    var body: some View {
        let workers = results.first?.workloads.first?.multi.workers ?? CPUBenchmark.defaultWorkers
        let scales = CPUWorkload.allCases.map(scale)
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent runs on this Mac").font(.subheadline.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(CPUWorkload.allCases.indices, id: \.self) { index in
                        Text("\(CPUWorkload.allCases[index].title) \(scales[index].unit)")
                            .gridCellColumns(2)
                            .gridCellAnchor(.center)
                    }
                    Text("")
                }
                GridRow {
                    Text("When")
                    ForEach(CPUWorkload.allCases, id: \.self) { _ in
                        Text("1")
                        Text("\(workers)")
                    }
                    Text("")
                }
                .help("One worker, then one per logical CPU")
                ForEach(results) { result in
                    GridRow {
                        Text(result.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .fixedSize()
                        ForEach(CPUWorkload.allCases.indices, id: \.self) { index in
                            let measured = result.result(CPUWorkload.allCases[index])
                            Text(measured.map { number($0.single.median, scales[index].divisor) } ?? "—")
                            Text(measured.map { number($0.multi.median, scales[index].divisor) } ?? "—")
                        }
                        Text(note(result)).foregroundStyle(.secondaryText).gridColumnAlignment(.leading)
                    }
                    .font(.tableText)
                    .help("\(result.appVersion) · \(result.osVersion) · thermal state \(result.worstThermalState.rawValue)")
                }
            }
            .font(.metadata)
            .foregroundStyle(.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    /// GB/s or MB/s (GFLOP/s or MFLOP/s), by the column's largest figure.
    private func scale(_ workload: CPUWorkload) -> (unit: String, divisor: Double) {
        let largest = results.compactMap { $0.result(workload)?.multi.median }.max() ?? 0
        let giga = largest >= 1e9
        if workload.countsBytes { return giga ? ("GB/s", 1e9) : ("MB/s", 1e6) }
        return giga ? ("GFLOP/s", 1e9) : ("MFLOP/s", 1e6)
    }

    private func number(_ value: Double, _ divisor: Double) -> String {
        let scaled = value / divisor
        return Format.fixed(scaled, scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2)
    }

    /// What sets a run apart from the newest: a debug build, other workloads, or heat.
    private func note(_ result: CPUBenchmarkResult) -> String {
        var notes: [String] = []
        if !result.optimized { notes.append("debug") }
        if let newest = results.first, result.suiteVersion != newest.suiteVersion { notes.append("v\(result.suiteVersion)") }
        if result.worstThermalState != .nominal { notes.append(result.worstThermalState.rawValue) }
        if result.lowPowerMode { notes.append("low power") }
        return notes.joined(separator: ", ")
    }
}

/// A run in progress: what it's measuring, the time so far, and how far it is.
private struct BenchmarkRunning: View {
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
            ProgressView(value: min(max(fraction, 0), 1)).tint(Theme.cpu)
        }
    }
}
