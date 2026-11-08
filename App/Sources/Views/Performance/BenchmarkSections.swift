import OTMKit
import SwiftUI

// MARK: - The tests' sections in the Benchmarks workspace

/// A test in progress, as its section shows it.
private struct SectionRun: Equatable {
    var text: String
    var started: Date
    var expected: String
    /// 0...1 when the test knows how far it is.
    var fraction: Double?
}

struct CPUSection: View {
    /// Read once: the chip doesn't change.
    static let chip = CPUBenchmarkMachine.current().chip

    var body: some View {
        let store = CPUBenchmarkStore.shared
        let suite = BenchmarkWorkspace.shared.suiteRunning
        let sustained = CPUSustainedStore.shared.running
        let seconds = Int(CPUBenchmarkConfiguration.standard.plannedSeconds.rounded())
        BenchmarkSection(
            kind: .cpu, runs: BenchmarkHistories.runs(.cpu),
            method: "Integer, floating point and memory, on 1 and \(CPUBenchmark.defaultWorkers) workers · about \(seconds) s",
            target: "Runs on the \(Self.chip), with one worker and then one per logical CPU.", blocked: nil,
            run: store.running.map { run in
                let progress = store.progress
                let text = progress.map { "\($0.phase.workload.title), \($0.phase.isMulti ? "\($0.phase.workers) workers" : "one worker")…" }
                return SectionRun(text: text ?? "Starting…", started: run.started, expected: "about \(seconds) s",
                                  fraction: progress?.fraction ?? 0)
            },
            failure: store.failure, canRun: !suite && sustained == nil, start: { store.start() }, cancel: { store.cancel() },
            waiting: sustained != nil ? "Wait for the sustained run to finish" : nil
        )
    }
}

/// The sustained CPU run: its own section, after the short benchmark's, and
/// never part of Run all, which it would hold up for minutes.
struct SustainedSection: View {
    var body: some View {
        let store = CPUSustainedStore.shared
        let configuration = CPUSustainedConfiguration.standard(minutes: store.minutes)
        BenchmarkSection(
            kind: .sustained, runs: BenchmarkHistories.runs(.sustained), method: CPUSustainedPanel.method,
            target: "Runs on the \(CPUSection.chip) for \(configuration.durationText): the floating-point workload on "
                + "\(CPUBenchmark.defaultWorkers) workers, timed every \(Format.timeSpan(configuration.windowSeconds)). "
                + "Only runs of the same length are compared.",
            blocked: nil,
            run: store.running.map { run in
                SectionRun(text: SustainedRunning.text(store.progress, windows: run.configuration.windowCount),
                           started: run.started, expected: run.configuration.durationText, fraction: store.progress?.fraction ?? 0)
            },
            failure: store.failure, canRun: store.canStart, start: { store.start() }, cancel: { store.cancel() },
            waiting: CPUBenchmarkStore.shared.running != nil ? "Wait for the CPU benchmark to finish" : nil, lengths: store
        )
    }
}

struct GPUSection: View {
    var body: some View {
        let store = GPUBenchmarkStore.shared
        let suite = BenchmarkWorkspace.shared.suiteRunning
        let seconds = Int(GPUBenchmarkConfiguration.standard.plannedSeconds.rounded())
        BenchmarkSection(
            kind: .gpu, runs: BenchmarkHistories.runs(.gpu),
            method: "FP32 compute, memory and fill rate, timed by the GPU · about \(seconds) s",
            target: store.device.map { "Runs on \($0.summary). Each figure is timed by the GPU's own clock and checked." },
            blocked: store.device == nil ? GPUBenchmarkError.noDevice.message : nil,
            run: store.running.map { run in
                let progress = store.progress
                return SectionRun(text: progress.map { "\($0.workload.title)…" } ?? "Compiling the shaders…", started: run.started,
                                  expected: "about \(seconds) s", fraction: progress?.fraction ?? 0)
            },
            failure: store.failure, canRun: !suite && store.device != nil, start: { store.start() }, cancel: { store.cancel() }
        )
    }
}

struct DiskSection: View {
    let places: BenchmarkPlaces

    var body: some View {
        let store = DiskSpeedStore.shared
        let suite = BenchmarkWorkspace.shared.suiteRunning
        let disk = places.disk
        let target = places.diskTarget
        BenchmarkSection(
            kind: .disk, runs: BenchmarkHistories.runs(.disk),
            method: "1 MB blocks in sequence, then 4K blocks at random, in one checked file",
            target: target.map {
                "Runs on \($0.title), in \($0.kind == .home ? "its temporary folder" : $0.subtitle): a file of up to "
                    + "\(Format.wholeBytes(DiskSpeedConfiguration.defaultFileSize)), written, read back and checked, then deleted. "
                    + "Pick another volume or folder on the disk's own page."
            },
            blocked: target == nil ? "There's no startup volume to test." : nil,
            run: store.running.map { run in
                let progress = store.progress
                return SectionRun(text: "\(run.target.title): " + (progress.map { "\($0.phase.title)…" } ?? "Starting…"),
                                  started: run.started, expected: "usually 10–30 s", fraction: progress?.fraction ?? 0)
            },
            failure: disk.flatMap { store.failures[$0] }, canRun: !suite && target != nil,
            start: { if let disk, let target { store.start(disk: disk, target: target) } }, cancel: { store.cancel() }
        )
    }
}

struct NetworkSection: View {
    let places: BenchmarkPlaces

    var body: some View {
        let store = NetworkQualityStore.shared
        let suite = BenchmarkWorkspace.shared.suiteRunning
        let interface = places.interface
        BenchmarkSection(
            kind: .network, runs: BenchmarkHistories.runs(.network),
            method: "macOS's networkQuality, to Apple's test servers · about \(Int(NetworkQuality.typicalSeconds)) s",
            target: places.interfaceTitle.map {
                "Runs over \($0), to Apple's test servers with macOS's networkQuality, which fills the connection for about "
                    + "\(Int(NetworkQuality.typicalSeconds)) s."
            },
            blocked: interface == nil ? "There's no network connection to test." : nil,
            run: store.running.map { run in
                SectionRun(text: "Filling the connection to measure it…", started: run.started,
                           expected: "about \(Int(NetworkQuality.typicalSeconds)) s", fraction: nil)
            },
            failure: interface.flatMap { store.failures[$0] }, canRun: !suite && interface != nil,
            start: { if let interface { store.start(interface: interface) } }, cancel: { store.cancel() }
        )
    }
}

/// One test: its name and Run or Cancel; its progress while it runs; the
/// latest run's figures, then its saved runs and comparison; and last, under
/// Methodology, where it runs and how its figures are taken.
private struct BenchmarkSection: View {
    let kind: BenchmarkKind
    /// Newest first.
    let runs: [BenchmarkRun]
    /// What the test measures, in a line, beside Methodology.
    let method: String
    /// Where the next run goes, and how.
    let target: String?
    /// Why the test can't run here.
    let blocked: String?
    let run: SectionRun?
    let failure: String?
    let canRun: Bool
    let start: () -> Void
    let cancel: () -> Void
    /// Why Run is off for now, when it isn't Run all.
    var waiting: String?
    /// The sustained run's length picker, beside Run.
    var lengths: CPUSustainedStore?

    var body: some View {
        let tint = BenchmarkLook.tint(kind)
        let latest = runs.first
        Card(tint: tint) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(kind.title, systemImage: BenchmarkLook.symbol(kind))
                    .font(.headline)
                    .foregroundStyle(tint)
                if latest?.build?.optimized == false {
                    DebugBadge()
                }
                Spacer(minLength: 8)
                if let lengths {
                    SustainedLengthPicker(store: lengths)
                }
                if run != nil {
                    Button("Cancel", action: cancel).help("Stop the test")
                } else {
                    Button("Run", action: start)
                        .disabled(!canRun)
                        .help(canRun ? "Run the \(kind.title.lowercased()) now"
                            : blocked ?? waiting ?? "Run all is running the tests one at a time")
                }
            }
            if let run {
                SectionProgress(run: run, tint: tint)
            }
            if let blocked, run == nil {
                Label(blocked, systemImage: "exclamationmark.triangle")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure, run == nil {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let latest {
                LatestFigures(run: latest, tint: tint)
                    .equatable()
                if runs.count > 1 {
                    BenchmarkTrendView(kind: kind, runs: runs)
                        .equatable()
                }
                SavedRuns(kind: kind, runs: runs)
                    .equatable()
            } else if run == nil {
                Text("No saved runs yet. Run the test, here or on its resource's page, and its figures are kept here.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MethodologyDisclosure(preview: method) {
                if let target { Text(target) }
                if let latest { Text(Self.provenance(latest)) }
                if runs.contains(where: { $0.measurements.contains { $0.repeats != nil } }) {
                    Text("Figures are medians of timed repeats; ± is half the gap between the slowest and fastest repeat.")
                }
            }
        }
    }

    /// "Latest run: workloads v2 · Apple M2 · Mac14,2 · macOS 26.1 · OpenTaskManager 0.1.0 · 6 workers."
    private static func provenance(_ run: BenchmarkRun) -> String {
        var parts = ["\(run.kind.versionName) v\(run.workloadVersion)"]
        if let machine = run.machine?.name, !machine.isEmpty { parts.append(machine) }
        // The Internet test's server; a disk test's folder is in its row's tooltip.
        if run.kind == .network, let server = run.target?.detail, !server.isEmpty { parts.append("server \(server)") }
        if let os = run.osVersion { parts.append(os) }
        if let app = run.build?.app { parts.append(app) }
        if !run.settingsSummary.isEmpty { parts.append(run.settingsSummary) }
        return "Latest run: " + parts.joined(separator: " · ") + "."
    }
}

private struct DebugBadge: View {
    var body: some View {
        Text("Debug build")
            .font(.callout.weight(.semibold))
            .foregroundStyle(BenchmarkLook.debug)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(BenchmarkLook.debug.fillShade.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(BenchmarkLook.debug.opacity(0.4)))
            .fixedSize()
            .help("The latest run is from a debug build, which runs the app's own code many times slower: "
                + "it isn't compared with a release build's runs.")
    }
}

/// A run in progress: what it's measuring, the time so far, and how far it is.
private struct SectionProgress: View {
    var run: SectionRun
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if run.fraction == nil { ProgressView().controlSize(.small) }
                Text(run.text).font(.callout)
                Spacer(minLength: 8)
                // The system ticks this text over; the view isn't redrawn.
                Text(timerInterval: run.started...run.started.addingTimeInterval(24 * 3600), countsDown: false)
                    .monospacedDigit()
                    .font(.callout)
                Text("of \(run.expected)").font(.metadata).foregroundStyle(.secondaryText)
            }
            if let fraction = run.fraction {
                ProgressView(value: min(max(fraction, 0), 1)).tint(tint)
            }
        }
    }
}

/// The newest run's figures, a tile per measure, then when and how it ran in
/// a line, with anything that held the figures back or flattered them.
private struct LatestFigures: View, Equatable {
    let run: BenchmarkRun
    let tint: Color

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.run == rhs.run && lhs.tint == rhs.tint
    }

    var body: some View {
        let groups = BenchmarkFigureGroup.groups(run.measurements.map(\.id), in: [run])
        VStack(alignment: .leading, spacing: 8) {
            FigureGrid(spacing: 10) {
                ForEach(groups) { group in
                    FigureTile(name: group.name, measurements: group.ids.compactMap(run.measurement), tint: tint)
                }
            }
            if let trace = run.sustained {
                SustainedOutcome(trace: trace, tint: tint, explainsFigures: false)
                    .equatable()
            }
            Text(Self.summary(run))
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            BenchmarkContextLine(context: run.context)
        }
    }

    /// "Latest run Oct 6, 2026 at 14:02 · release build · Macintosh HD."
    private static func summary(_ run: BenchmarkRun) -> String {
        var parts = ["Latest run \(run.date.formatted(date: .abbreviated, time: .shortened))"]
        if let build = run.build { parts.append("\(build.title.lowercased()) build") }
        if let target = run.target { parts.append(target.name) }
        var text = parts.joined(separator: " · ") + "."
        if !run.conditions.isEmpty { text += " " + run.conditions.joined(separator: "; ").capitalizedFirst + "." }
        return text
    }
}

/// A `FillGrid` whose minimum is the widest tile's own width, so in a narrow
/// window the tiles go two to a row, or one, before a figure is cut. Widths
/// are measured when the tiles change (a new run), not on every layout pass.
private struct FigureGrid: Layout {
    var spacing: CGFloat

    func makeCache(subviews: Subviews) -> CGFloat {
        (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0).rounded(.up)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) -> CGSize {
        var none: Void = ()
        return FillGrid(minimum: cache, spacing: spacing).sizeThatFits(proposal: proposal, subviews: subviews, cache: &none)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) {
        var none: Void = ()
        FillGrid(minimum: cache, spacing: spacing).placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &none)
    }
}

/// A measure's figures. One whose timing is in doubt is set in secondary
/// text, with the caution right under it and the reason in its tooltip.
private struct FigureTile: View {
    var name: String
    var measurements: [BenchmarkMeasurement]
    var tint: Color

    var body: some View {
        let caveat = measurements.lazy.compactMap(\.caveat).first
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.callout.weight(.medium)).foregroundStyle(.secondaryText).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(measurements) { measurement in
                    GridRow(alignment: .firstTextBaseline) {
                        if measurements.count > 1 {
                            Text(measurement.variant ?? "").font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
                        }
                        Text(measurement.unit.format(measurement.value))
                            .font(.body.weight(measurement.caveat == nil ? .semibold : .regular))
                            .foregroundStyle(measurement.caveat == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondaryText))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(measurement.plusMinus ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .help(measurement.repeats.map { "Median of \($0) timed repeats; ± is half the gap between the slowest and fastest" }
                        ?? "Measured once")
                }
            }
            if let caveat {
                FigureCaveatLabel(caveat: caveat, detail: nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.fillShade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(caveat == nil ? tint.opacity(0.22) : BenchmarkLook.caution.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

extension String {
    /// "Low Power Mode on; thermal state fair" with its first letter raised, for a sentence of conditions.
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
