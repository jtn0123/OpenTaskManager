import Charts
import OTMKit
import SwiftUI

/// "Sustained run" at the foot of the CPU detail's Benchmark card: when
/// asked, the floating-point workload on every worker for 2 or 5 minutes,
/// timed every 10 s, then how much of its first window's speed it held, a
/// small chart of the windows and the thermal state macOS reported as it
/// went. It never says why the speed changed. It reads only
/// `CPUSustainedStore` (and whether the short benchmark is running), so it
/// redraws with a window or a slice, never per tick.
struct CPUSustainedPanel: View, Equatable {
    var body: some View {
        let store = CPUSustainedStore.shared
        let latest = store.history.first
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            SustainedHeader(store: store)
            if let run = store.running {
                SustainedRunning(run: run, progress: store.progress)
            } else {
                if let failure = store.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let latest {
                    let run = BenchmarkRun(latest)
                    if let trace = run.sustained {
                        SustainedOutcome(trace: trace, tint: Theme.cpu, explainsFigures: true)
                            .equatable()
                    }
                    Text(Self.tested(latest))
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    BenchmarkContextLine(context: run.context)
                } else if store.failure == nil {
                    Text("Repeats the benchmark's floating-point workload on all \(CPUBenchmark.defaultWorkers) workers for minutes, "
                        + "to show how much of its starting speed the CPU holds.")
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if store.history.count > 1 {
                SavedRunsDisclosure(kind: .sustained, runs: store.history.map(BenchmarkRun.init), place: "on this Mac")
                    .equatable()
            }
            MethodologyDisclosure(preview: Self.method) {
                ForEach(Self.methodology, id: \.self) { Text($0) }
            }
        }
        .task { store.handleLaunchArgument() }
    }

    /// "Floating point on 18 workers, timed every 10 s · 2 or 5 min".
    static var method: String {
        let lengths = CPUSustainedConfiguration.offeredMinutes.map(String.init).joined(separator: " or ")
        return "Floating point on \(CPUBenchmark.defaultWorkers) workers, timed every "
            + "\(Format.timeSpan(CPUSustainedConfiguration.standard().windowSeconds)) · \(lengths) min"
    }

    static var methodology: [String] {
        let configuration = CPUSustainedConfiguration.standard()
        return [
            "Runs the benchmark's floating-point workload (version \(CPUSustained.suiteVersion)) on one worker per logical CPU, "
                + "after a \(Format.fixed(configuration.warmUpSeconds, 1)) s warm-up, and times its throughput in "
                + "\(Format.timeSpan(configuration.windowSeconds)) windows of \(configuration.slicesPerWindow) slices each.",
            "The sustained level is the median of the last third of the windows; how much it held is that level as a share of "
                + "the first window's. It doesn't say why the speed changed: heat, other work and power settings can all slow a "
                + "run, so the thermal state macOS reported is shown as it went, and shaded on the chart when above nominal.",
            "Sustained runs are compared only with other sustained runs of the same length, never with the short benchmark.",
        ]
    }

    /// "Tested Oct 7, 2026 at 14:02 · 2 min · release build".
    private static func tested(_ result: CPUSustainedResult) -> String {
        var parts = ["Tested \(result.date.formatted(date: .abbreviated, time: .shortened))", result.configuration.durationText,
                     result.optimized ? "release build" : "debug build"]
        if result.lowPowerMode { parts.append("Low Power Mode on") }
        return parts.joined(separator: " · ")
    }
}

/// The panel's title, the length and Run or Cancel.
private struct SustainedHeader: View {
    let store: CPUSustainedStore

    var body: some View {
        let short = CPUBenchmarkStore.shared.running != nil
        let suite = BenchmarkWorkspace.shared.suiteRunning
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Sustained run", systemImage: "timer")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.cpu)
            Spacer(minLength: 8)
            SustainedLengthPicker(store: store)
            if store.running != nil {
                Button("Cancel") { store.cancel() }
                    .help("Stop the sustained run; nothing is saved")
            } else {
                Button("Run Sustained") { store.start() }
                    .disabled(!store.canStart)
                    .help(short ? "Wait for the benchmark to finish" : suite ? "Wait for Run all to finish"
                        : "Keep every core busy for \(store.minutes) min and chart how much of its starting speed the CPU holds")
            }
        }
    }
}

/// 2 or 5 minutes, fixed while a run goes.
struct SustainedLengthPicker: View {
    let store: CPUSustainedStore

    var body: some View {
        Picker("Length", selection: Binding(get: { store.minutes }, set: { store.minutes = $0 })) {
            ForEach(CPUSustainedConfiguration.offeredMinutes, id: \.self) { minutes in
                Text("\(minutes) min").tag(minutes)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(store.running != nil)
        .help("How long the next sustained run lasts")
    }
}

/// A sustained run in progress: the window it's in, the thermal state, the
/// time so far against the length, and the windows so far on the chart.
struct SustainedRunning: View {
    let run: CPUSustainedStore.Run
    let progress: CPUSustainedProgress?

    var body: some View {
        let configuration = run.configuration
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(Self.text(progress, windows: configuration.windowCount)).font(.callout)
                Spacer(minLength: 8)
                // The system ticks this text over; the view isn't redrawn.
                Text(timerInterval: run.started...run.started.addingTimeInterval(24 * 3600), countsDown: false)
                    .monospacedDigit()
                    .font(.callout)
                Text("of \(configuration.durationText)").font(.metadata).foregroundStyle(.secondaryText)
            }
            ProgressView(value: min(max(progress?.fraction ?? 0, 0), 1)).tint(Theme.cpu)
            if let windows = progress?.windows, !windows.isEmpty {
                SustainedChart(trace: BenchmarkSustainedTrace(unit: .flopsPerSecond, windowSeconds: configuration.windowSeconds,
                                                              thermalAtStart: windows[0].thermalState, windows: windows),
                               span: configuration.durationSeconds, tint: Theme.cpu)
                    .equatable()
            }
        }
    }

    /// "Warming up…", "Window 4 of 12 · thermal state nominal…".
    static func text(_ progress: CPUSustainedProgress?, windows: Int) -> String {
        guard let progress, !progress.warmingUp else { return "Warming up…" }
        let window = min(progress.windows.count + 1, windows)
        let thermal = progress.windows.last.map { " · thermal state \($0.thermalState.rawValue)" } ?? ""
        return "Window \(window) of \(windows)\(thermal)…"
    }
}

/// What a sustained run came to: how much it held, the chart, what changed
/// in figures (left out where tiles show them) and what macOS reported about heat.
struct SustainedOutcome: View, Equatable {
    let trace: BenchmarkSustainedTrace
    let tint: Color
    let explainsFigures: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trace == rhs.trace && lhs.tint == rhs.tint && lhs.explainsFigures == rhs.explainsFigures
    }

    var body: some View {
        if let summary = trace.summary {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.heldText)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                SustainedChart(trace: trace, span: nil, tint: tint)
                    .equatable()
                if explainsFigures {
                    Text(summary.changeText(format: trace.unit.format, windowSeconds: trace.windowSeconds))
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label {
                    Text(summary.thermalText)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "thermometer.medium")
                }
                .font(.explanation)
                .foregroundStyle(.secondaryText)
            }
        }
    }
}

/// A sustained run's windows as a line, throughput from zero over the run's
/// time, the first window's level dashed across it, and the windows where
/// macOS reported a thermal state above nominal shaded. Static: built when
/// its windows change, never per tick.
struct SustainedChart: View, Equatable {
    let trace: BenchmarkSustainedTrace
    /// The whole run's length while it's in progress, so the line grows across it.
    let span: Double?
    let tint: Color

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trace == rhs.trace && lhs.span == rhs.span && lhs.tint == rhs.tint
    }

    var body: some View {
        let axis = trace.axis
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 14, lineSpacing: 2, spreads: false) {
                Text("\(axis.unit), each \(Format.timeSpan(trace.windowSeconds)) window")
                if trace.windows.count > 1 {
                    HStack(spacing: 5) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 4))
                            path.addLine(to: CGPoint(x: 16, y: 4))
                        }
                        .stroke(Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 16, height: 8)
                        Text("First window")
                    }
                }
                if trace.windows.contains(where: { $0.thermalState != .nominal }) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.shade(.serious)).frame(width: 12, height: 10)
                        Text("Thermal state above nominal")
                    }
                }
            }
            .font(.metadata)
            .foregroundStyle(.secondaryText)
            chart(axis)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Throughput every \(Format.timeSpan(trace.windowSeconds)) over the run")
        .accessibilityValue(trace.narrative ?? "")
    }

    private func chart(_ axis: SustainedChartAxis) -> some View {
        let seconds = max(span ?? 0, axis.seconds)
        let windows = Array(trace.windows.enumerated())
        return Chart {
            ForEach(windows, id: \.offset) { _, window in
                if window.thermalState != .nominal {
                    RectangleMark(xStart: .value("From", window.start), xEnd: .value("To", window.end))
                        .foregroundStyle(Self.shade(window.thermalState))
                }
            }
            if let first = trace.windows.first, trace.windows.count > 1 {
                RuleMark(y: .value("First window", first.throughput))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(windows, id: \.offset) { _, window in
                LineMark(x: .value("Time", window.start + window.seconds / 2), y: .value("Throughput", window.throughput))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Time", window.start + window.seconds / 2), y: .value("Throughput", window.throughput))
                    .foregroundStyle(tint)
                    .symbolSize(14)
            }
        }
        // Room past the last tick for its label, which would otherwise be cut.
        .chartXScale(domain: 0...seconds, range: .plotDimension(startPadding: 0, endPadding: 16))
        .chartYScale(domain: 0...axis.top)
        .chartXAxis {
            AxisMarks(values: axis.timeTicks.filter { $0 <= seconds }) { value in
                let time = value.as(Double.self) ?? 0
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.06))
                // The first label starts at the plot's edge, so it's never cut.
                AxisValueLabel(anchor: time <= 0 ? .topLeading : .top) {
                    Text(CPUSustainedSummary.clock(time))
                }
                .font(.metadata)
                .foregroundStyle(.secondaryText)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: axis.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.10))
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(axis.label(number)) }
                }
                .font(.metadata)
                .foregroundStyle(.secondaryText)
            }
        }
        .chartPlotStyle { plot in
            plot.background(tint.opacity(0.04))
        }
        .frame(height: 110)
    }

    private static func shade(_ state: ThermalState) -> Color {
        switch state {
        case .nominal: .clear
        case .fair: BenchmarkLook.caution.opacity(0.12)
        case .serious: BenchmarkLook.caution.opacity(0.24)
        case .critical: BenchmarkLook.worse.opacity(0.24)
        }
    }
}

/// How the Mac stood as a run started, in a line, or that the run is from
/// before contexts were recorded; what ran and on what in its tooltip.
struct BenchmarkContextLine: View {
    let context: BenchmarkContext?

    var body: some View {
        let line = context.map(\.conditionsLine) ?? ""
        Label {
            Text(line.isEmpty ? "\(BenchmarkContext.notRecorded)." : "Started \(line).")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
        .font(.explanation)
        .foregroundStyle(.secondaryText)
        .help(context.map { $0.provenanceLine.isEmpty ? "" : "Recorded as it started: \($0.provenanceLine)" }
            ?? "Runs saved before this version of the app don't record the power, heat and load they started with.")
    }
}
