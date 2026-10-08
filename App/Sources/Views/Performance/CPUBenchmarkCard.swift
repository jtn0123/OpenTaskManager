import OTMKit
import SwiftUI

/// "Benchmark" on the CPU detail: when asked, times integer, floating-point
/// and memory workloads on one worker and then on one per logical CPU, and
/// shows each one's speed, spread and scaling. The last runs on this Mac fold
/// away under Saved runs, beside a link to compare them in the Benchmarks
/// workspace, which charts their trends. It has no inputs and reads only
/// `CPUBenchmarkStore`, so it redraws with the run's progress, not per tick.
/// Figures from a debug build, which runs the workloads many times slower,
/// carry a badge by the title and a line just above them, so they're never
/// read as this Mac's speed; a release build's carry nothing extra. The
/// figures come first; what the workloads do and how they're timed fold away
/// under Methodology. The sustained run (`CPUSustainedPanel`) follows, its
/// own section; only one of the two runs goes at a time.
struct CPUBenchmarkCard: View, Equatable {
    /// Debug builds' figures, in the badge.
    private static let debugColor = BenchmarkLook.debug

    var body: some View {
        let store = CPUBenchmarkStore.shared
        let run = store.running
        let results = store.history
        // The figures on show: the run's, from this build, or the latest's.
        let debugFigures = run != nil || results.isEmpty ? !CPUBenchmark.isOptimizedBuild : results.first?.optimized == false
        Card(tint: Theme.cpu) {
            header(run: run, store: store, debugFigures: debugFigures)
            if let run {
                let progress = store.progress
                BenchmarkRunning(text: progress.map(Self.phaseText) ?? "Starting…", started: run.started,
                                 expected: "about \(Self.plannedSeconds) s", fraction: progress?.fraction ?? 0)
                if debugFigures { debugQualification }
                tiles(result: nil, progress: progress, workers: run.workers)
            } else {
                if let failure = store.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let latest = results.first {
                    if debugFigures { debugQualification }
                    tiles(result: latest, progress: nil, workers: latest.workloads.first?.multi.workers ?? CPUBenchmark.defaultWorkers)
                    Text(Self.tested(latest))
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if results.count > 1 {
                SavedRunsDisclosure(kind: .cpu, runs: results.map(BenchmarkRun.init), place: "on this Mac")
                    .equatable()
            }
            MethodologyDisclosure(preview: "Integer, floating point and memory, on 1 and \(CPUBenchmark.defaultWorkers) workers · "
                + "about \(Self.plannedSeconds) s") {
                Text(caption)
                if run == nil, let latest = results.first {
                    Text(Self.details(latest))
                }
            }
            CPUSustainedPanel()
                .equatable()
        }
        .task { store.handleLaunchArgument() }
    }

    /// What the debug badge means, just above the figures it qualifies.
    private var debugQualification: some View {
        Label("Debug build, many times slower than a release build: don't compare these figures with one.", systemImage: "ant")
            .font(.callout)
            .foregroundStyle(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
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

    private func header(run: CPUBenchmarkStore.Run?, store: CPUBenchmarkStore, debugFigures: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Benchmark", systemImage: "stopwatch")
                .font(.headline)
                .foregroundStyle(Theme.cpu)
            if debugFigures {
                Text("Debug build")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Self.debugColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Self.debugColor.fillShade.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(Self.debugColor.opacity(0.4)))
                    .fixedSize()
                    .help(run != nil || store.history.isEmpty
                        ? "This is a debug build, which runs the workloads many times slower than a release build."
                        : "These figures are from a debug build, which runs the workloads many times slower than a release build.")
            }
            Spacer(minLength: 8)
            if run != nil {
                Button("Cancel") { store.cancel() }
                    .help("Stop the benchmark")
            } else {
                let sustained = CPUSustainedStore.shared.running != nil
                Button("Run Benchmark") { store.start() }
                    .disabled(sustained)
                    .help(sustained ? "Wait for the sustained run to finish"
                        : "Measure this Mac's CPU and memory speed for about \(Self.plannedSeconds) s")
            }
        }
    }

    private static func phaseText(_ progress: CPUBenchmarkProgress) -> String {
        let workers = progress.phase.isMulti ? "\(progress.phase.workers) workers" : "one worker"
        return "\(progress.phase.workload.title), \(workers)…"
    }

    /// Under the figures: when, in which build, and anything that held them back.
    private static func tested(_ result: CPUBenchmarkResult) -> String {
        var parts = [
            "Tested \(result.date.formatted(date: .abbreviated, time: .shortened))",
            result.optimized ? "release build" : "debug build",
            "thermal state \(result.worstThermalState.rawValue)",
        ]
        if result.lowPowerMode { parts.append("Low Power Mode on") }
        return parts.joined(separator: " · ")
    }

    /// In the methodology: the versions, and how the figures are taken.
    private static func details(_ result: CPUBenchmarkResult) -> String {
        let parts = ["Workloads v\(result.suiteVersion)", result.osVersion, result.appVersion]
        return parts.joined(separator: " · ") + ". Medians of \(result.configuration.repeats) timed repeats; "
            + "± is half the gap between the slowest and fastest. Scaling is all workers' speed over one worker's."
    }

    // MARK: - Figures

    /// A tile per workload: its figures once measured, "measuring…" while
    /// its phase runs, a dash until then.
    private func tiles(result: CPUBenchmarkResult?, progress: CPUBenchmarkProgress?, workers: Int) -> some View {
        FillGrid(minimum: 175, spacing: 10) {
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
            Text(workload.title).font(.callout.weight(.medium)).foregroundStyle(.secondaryText).lineLimit(1)
                .help(workload.summary.prefix(1).uppercased() + workload.summary.dropFirst())
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                row("1 worker", single, measuring: measuringSingle)
                row("\(workers) workers", multi, measuring: measuringMulti)
            }
            Text(footer).font(.callout).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(1)
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
            Text(label).font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
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
