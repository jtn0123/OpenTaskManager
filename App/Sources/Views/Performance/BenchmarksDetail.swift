import OTMKit
import SwiftUI

/// The Benchmarks workspace, at the foot of the Performance list: the CPU,
/// GPU, disk and Internet tests side by side, each with its latest figures,
/// its saved runs and a comparison of any two, and Run all. The tests run
/// through their own stores, so a run started here is the one the resource's
/// card shows, and the other way round. Its inputs don't change from tick to
/// tick and each section reads only its test's store, so the page redraws
/// with a run's progress, never per tick. There's no overall score: the
/// tests measure different things, and the Internet's figures aren't this Mac's.
struct BenchmarksDetail: View, Equatable {
    /// The startup volume's name ("Macintosh HD"), where the disk test writes.
    let homeVolume: String
    /// The disk it's on ("disk3"), as the snapshot has it.
    let homeDisk: String?
    /// The interface the Internet test goes over ("en0"), and its name ("Wi-Fi").
    let interface: String?
    let interfaceName: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.homeVolume == rhs.homeVolume && lhs.homeDisk == rhs.homeDisk && lhs.interface == rhs.interface
            && lhs.interfaceName == rhs.interfaceName
    }

    var body: some View {
        let places = BenchmarkPlaces(homeVolume: homeVolume, homeDisk: homeDisk, interface: interface, interfaceName: interfaceName)
        VStack(alignment: .leading, spacing: 16) {
            BenchmarksHeader()
            Text("Every saved run of the four tests, newest first. Tick two runs of a test to see how each figure moved, "
                + "and whether the move is bigger than the runs' own spread from slowest to fastest repeat. There's no overall "
                + "score: each test measures something different.")
                .font(.body)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            SuiteCard(places: places)
            GroupHeading(title: "This Mac", symbol: "laptopcomputer",
                         note: "The CPU, GPU and disk tests measure this Mac's hardware.")
            CPUSection()
            GPUSection()
            DiskSection(places: places)
            GroupHeading(title: "Your Internet connection", symbol: "globe",
                         note: "The Internet test measures the connection and the server it reached at the time, not this Mac, "
                             + "so its runs are kept apart from the hardware's.")
                .padding(.top, 6)
            NetworkSection(places: places)
        }
        .task {
            await DiskSpeedStore.shared.load()
            await NetworkQualityStore.shared.load()
            let runs = Dictionary(uniqueKeysWithValues: BenchmarkKind.allCases.map { ($0, BenchmarkHistories.runs($0)) })
            BenchmarkWorkspace.shared.handleLaunchArguments(runs: runs, targets: places.suiteTargets)
        }
    }
}

/// Where the disk and Internet tests run, from the page's snapshot.
private struct BenchmarkPlaces: Equatable {
    var homeVolume: String
    var homeDisk: String?
    var interface: String?
    var interfaceName: String?

    /// The disk store's home disk once read, else the snapshot's.
    @MainActor var disk: String? {
        DiskSpeedStore.shared.homeDisk ?? homeDisk
    }

    /// The disk card's pick on the home disk, or its temporary folder.
    @MainActor var diskTarget: DiskSpeedTarget? {
        guard let disk else { return nil }
        let root = DiskSpeedVolumeChoice(name: homeVolume, mountPoint: "/", isRoot: true)
        return DiskSpeedStore.shared.target(disk: disk, volumes: [root])
    }

    @MainActor var suiteTargets: BenchmarkWorkspace.SuiteTargets {
        BenchmarkWorkspace.SuiteTargets(disk: disk, diskTarget: diskTarget, interface: interface)
    }

    /// "Wi-Fi (en0)".
    var interfaceTitle: String? {
        guard let interface else { return nil }
        return interfaceName.map { $0 == interface ? interface : "\($0) (\(interface))" } ?? interface
    }
}

/// Each test's saved runs from its store, as the workspace shows them.
@MainActor
private enum BenchmarkHistories {
    static func runs(_ kind: BenchmarkKind) -> [BenchmarkRun] {
        switch kind {
        case .cpu: CPUBenchmarkStore.shared.history.map(BenchmarkRun.init)
        case .gpu: GPUBenchmarkStore.shared.history.map(BenchmarkRun.init)
        case .disk: DiskSpeedStore.shared.history.map(BenchmarkRun.init)
        case .network: NetworkQualityStore.shared.history.map(BenchmarkRun.init)
        }
    }

    static var anyRunning: Bool {
        CPUBenchmarkStore.shared.running != nil || GPUBenchmarkStore.shared.running != nil
            || DiskSpeedStore.shared.running != nil || NetworkQualityStore.shared.running != nil
    }
}

enum BenchmarkLook {
    /// A debug build's runs, as the CPU benchmark card marks them.
    static let debug = Theme.data(0.96, 0.50, 0.08)
    static let better = Theme.data(0.16, 0.66, 0.34)
    static let worse = Theme.data(0.92, 0.30, 0.26)

    static func tint(_ kind: BenchmarkKind) -> Color {
        switch kind {
        case .cpu: Theme.cpu
        case .gpu: Theme.gpu
        case .disk: Theme.disk
        case .network: Theme.network
        }
    }

    static func symbol(_ kind: BenchmarkKind) -> String {
        switch kind {
        case .cpu: "cpu"
        case .gpu: "cube.transparent"
        case .disk: "internaldrive"
        case .network: "globe"
        }
    }

    /// "Oct 6, 14:02".
    static func when(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

// MARK: - Header and Run all

private struct BenchmarksHeader: View {
    var body: some View {
        let count = BenchmarkKind.allCases.reduce(0) { $0 + BenchmarkHistories.runs($1).count }
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            DetailHeader(title: "Benchmarks", subtitle: count == 1 ? "1 saved run" : "\(count) saved runs")
            Menu("Export") {
                Button("Results as JSON…") { export(.json) }
                Button("Results as Markdown…") { export(.markdown) }
            }
            .fixedSize()
            .disabled(count == 0)
            .help("Save every run shown here, and any comparison picked, as a file")
        }
    }

    private func export(_ format: BenchmarkWorkspace.ExportFormat) {
        let workspace = BenchmarkWorkspace.shared
        let byKind = BenchmarkKind.allCases.map { BenchmarkHistories.runs($0) }
        let comparisons = zip(BenchmarkKind.allCases, byKind).compactMap { kind, runs -> (BenchmarkRun, BenchmarkRun)? in
            let picked = workspace.picked(kind, among: runs)
            return picked.count == 2 ? (picked[0], picked[1]) : nil
        }
        workspace.export(byKind.flatMap(\.self), comparisons: comparisons, as: format)
    }
}

private struct GroupHeading: View {
    var title: String
    var symbol: String
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            Text(note)
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Run all: the CPU and GPU benchmarks one after the other, then the disk
/// and Internet tests if ticked, with each step's state. It reads only the
/// workspace and whether a test is running, not any test's progress.
private struct SuiteCard: View {
    let places: BenchmarkPlaces

    var body: some View {
        let workspace = BenchmarkWorkspace.shared
        let targets = places.suiteTargets
        Card {
            HStack(alignment: .firstTextBaseline) {
                Label("Run all", systemImage: "list.number").font(.headline)
                Spacer(minLength: 8)
                if workspace.suiteRunning {
                    Button("Cancel All") { workspace.cancelAll() }
                        .help("Stop the test that's running and skip the rest")
                } else {
                    Button("Run All") { workspace.runAll(targets: targets) }
                        .disabled(BenchmarkHistories.anyRunning)
                        .help(BenchmarkHistories.anyRunning ? "Wait for the test that's running to finish"
                            : "Run the ticked tests one after the other")
                }
            }
            Text("Runs the CPU benchmark and then the GPU benchmark, one at a time so neither slows the other, about "
                + "\(Self.benchmarkSeconds) s in all. Each test's figures are saved and shown on their own.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                SuiteOption(isOn: Binding(get: { workspace.includesDisk }, set: { workspace.includesDisk = $0 }),
                            title: "Then the disk speed test on \(targets.diskTarget?.title ?? places.homeVolume)",
                            detail: "Writes a temporary file of up to \(Format.wholeBytes(DiskSpeedConfiguration.defaultFileSize)) in "
                                + "\(Self.folder(targets.diskTarget)), reads it back, then deletes it.",
                            enabled: !workspace.suiteRunning && targets.diskTarget != nil)
                SuiteOption(isOn: Binding(get: { workspace.includesNetwork }, set: { workspace.includesNetwork = $0 }),
                            title: "Then the Internet quality test over \(places.interfaceTitle ?? "the network")",
                            detail: places.interface == nil ? "There's no network connection to test."
                                : "Loads the connection for about \(Int(NetworkQuality.typicalSeconds)) s. Its figures measure "
                                + "the connection, not this Mac.",
                            enabled: !workspace.suiteRunning && places.interface != nil)
            }
            if !workspace.steps.isEmpty {
                SuiteSteps(steps: workspace.steps, position: workspace.position)
            }
        }
    }

    private static var benchmarkSeconds: Int {
        Int((CPUBenchmarkConfiguration.standard.plannedSeconds + GPUBenchmarkConfiguration.standard.plannedSeconds).rounded())
    }

    /// "the home volume's temporary folder", or the folder the disk card picked.
    private static func folder(_ target: DiskSpeedTarget?) -> String {
        switch target?.kind {
        case .volume, .folder: (target.map { ($0.path as NSString).abbreviatingWithTildeInPath }) ?? ""
        case .home, nil: "the temporary folder"
        }
    }
}

private struct SuiteOption: View {
    @Binding var isOn: Bool
    var title: String
    var detail: String
    var enabled: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
    }
}

/// The suite's steps in order, each with its state, and which is running.
private struct SuiteSteps: View {
    var steps: [BenchmarkWorkspace.Step]
    var position: (step: Int, of: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let position, let running = steps.first(where: { $0.state == .running }) {
                Text("Step \(position.step) of \(position.of): \(running.kind.title)…").font(.body.weight(.medium))
            } else {
                Text("Last Run all").font(.body.weight(.medium))
            }
            FlowRow(spacing: 16, lineSpacing: 6) {
                ForEach(steps) { step in
                    HStack(spacing: 5) {
                        Image(systemName: Self.symbol(step.state)).foregroundStyle(Self.color(step.state))
                        Text(step.kind.title).font(.callout.weight(step.state == .running ? .semibold : .regular))
                        Text(Self.title(step.state)).font(.callout).foregroundStyle(.secondaryText)
                    }
                    .help(Self.failure(step.state) ?? "")
                }
            }
            ForEach(steps) { step in
                if let failure = Self.failure(step.state) {
                    Label("\(step.kind.title): \(failure)", systemImage: "exclamationmark.triangle")
                        .font(.explanation)
                        .foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func symbol(_ state: BenchmarkWorkspace.StepState) -> String {
        switch state {
        case .waiting: "circle"
        case .running: "play.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .notRun: "minus.circle"
        }
    }

    private static func color(_ state: BenchmarkWorkspace.StepState) -> AnyShapeStyle {
        switch state {
        case .running: AnyShapeStyle(Color.accentColor)
        case .finished: AnyShapeStyle(BenchmarkLook.better)
        case .failed: AnyShapeStyle(BenchmarkLook.debug)
        case .waiting, .cancelled, .notRun: AnyShapeStyle(.secondaryText)
        }
    }

    private static func title(_ state: BenchmarkWorkspace.StepState) -> String {
        switch state {
        case .waiting: "waiting"
        case .running: "running"
        case .finished: "done"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .notRun: "not run"
        }
    }

    private static func failure(_ state: BenchmarkWorkspace.StepState) -> String? {
        if case let .failed(message) = state { return message }
        return nil
    }
}

// MARK: - The four tests

/// A test in progress, as its section shows it.
private struct SectionRun: Equatable {
    var text: String
    var started: Date
    var expected: String
    /// 0...1 when the test knows how far it is.
    var fraction: Double?
}

private struct CPUSection: View {
    /// Read once: the chip doesn't change.
    private static let chip = CPUBenchmarkMachine.current().chip

    var body: some View {
        let store = CPUBenchmarkStore.shared
        let suite = BenchmarkWorkspace.shared.suiteRunning
        let seconds = Int(CPUBenchmarkConfiguration.standard.plannedSeconds.rounded())
        BenchmarkSection(
            kind: .cpu, runs: BenchmarkHistories.runs(.cpu),
            target: "On the \(Self.chip), with one worker and then one per logical CPU.",
            run: store.running.map { run in
                let progress = store.progress
                let text = progress.map { "\($0.phase.workload.title), \($0.phase.isMulti ? "\($0.phase.workers) workers" : "one worker")…" }
                return SectionRun(text: text ?? "Starting…", started: run.started, expected: "about \(seconds) s",
                                  fraction: progress?.fraction ?? 0)
            },
            failure: store.failure, canRun: !suite, start: { store.start() }, cancel: { store.cancel() }
        )
    }
}

private struct GPUSection: View {
    var body: some View {
        let store = GPUBenchmarkStore.shared
        let suite = BenchmarkWorkspace.shared.suiteRunning
        let seconds = Int(GPUBenchmarkConfiguration.standard.plannedSeconds.rounded())
        BenchmarkSection(
            kind: .gpu, runs: BenchmarkHistories.runs(.gpu),
            target: store.device.map { "On \($0.summary)." } ?? GPUBenchmarkError.noDevice.message,
            run: store.running.map { run in
                let progress = store.progress
                return SectionRun(text: progress.map { "\($0.workload.title)…" } ?? "Compiling the shaders…", started: run.started,
                                  expected: "about \(seconds) s", fraction: progress?.fraction ?? 0)
            },
            failure: store.failure, canRun: !suite && store.device != nil, start: { store.start() }, cancel: { store.cancel() }
        )
    }
}

private struct DiskSection: View {
    let places: BenchmarkPlaces

    var body: some View {
        let store = DiskSpeedStore.shared
        let suite = BenchmarkWorkspace.shared.suiteRunning
        let disk = places.disk
        let target = places.diskTarget
        BenchmarkSection(
            kind: .disk, runs: BenchmarkHistories.runs(.disk),
            target: target.map { "On \($0.title), in \($0.kind == .home ? "its temporary folder" : $0.subtitle). Pick another volume "
                + "or folder on the disk's own page." } ?? "There's no startup volume to test.",
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

private struct NetworkSection: View {
    let places: BenchmarkPlaces

    var body: some View {
        let store = NetworkQualityStore.shared
        let suite = BenchmarkWorkspace.shared.suiteRunning
        let interface = places.interface
        BenchmarkSection(
            kind: .network, runs: BenchmarkHistories.runs(.network),
            target: places.interfaceTitle.map { "Over \($0), to Apple's test servers with macOS's networkQuality." }
                ?? "There's no network connection to test.",
            run: store.running.map { run in
                SectionRun(text: "Filling the connection to measure it…", started: run.started,
                           expected: "about \(Int(NetworkQuality.typicalSeconds)) s", fraction: nil)
            },
            failure: interface.flatMap { store.failures[$0] }, canRun: !suite && interface != nil,
            start: { if let interface { store.start(interface: interface) } }, cancel: { store.cancel() }
        )
    }
}

/// One test: its name, where it runs and Run or Cancel; its progress while
/// it runs; the latest run's figures; then its saved runs and comparison.
private struct BenchmarkSection: View {
    let kind: BenchmarkKind
    /// Newest first.
    let runs: [BenchmarkRun]
    let target: String
    let run: SectionRun?
    let failure: String?
    let canRun: Bool
    let start: () -> Void
    let cancel: () -> Void

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
                if run != nil {
                    Button("Cancel", action: cancel).help("Stop the test")
                } else {
                    Button("Run", action: start)
                        .disabled(!canRun)
                        .help(canRun ? "Run the \(kind.title.lowercased()) now" : "Run all is running the tests one at a time")
                }
            }
            Text(target)
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let run {
                SectionProgress(run: run, tint: tint)
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
                SavedRuns(kind: kind, runs: runs)
                    .equatable()
            } else if run == nil {
                Text("No saved runs yet. Run the test, here or on its resource's page, and its figures are kept here.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

/// The newest run's figures, a tile per measure, and when and how it ran.
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
            Text(Self.summary(run))
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Latest run Oct 6, 2026 at 14:02 · release build · workloads v2 · Apple M2 · Mac14,2."
    private static func summary(_ run: BenchmarkRun) -> String {
        var parts = ["Latest run \(run.date.formatted(date: .abbreviated, time: .shortened))"]
        if let build = run.build { parts.append("\(build.title.lowercased()) build") }
        parts.append("\(run.kind.versionName) v\(run.workloadVersion)")
        if let machine = run.machine?.name, !machine.isEmpty { parts.append(machine) }
        if let target = run.target {
            // The Internet test's server; a disk test's folder is in its row's tooltip.
            let server = run.kind == .network ? target.detail : nil
            parts.append(server.map { "\(target.name) to \($0)" } ?? target.name)
        }
        var text = parts.joined(separator: " · ") + "."
        if !run.conditions.isEmpty { text += " " + run.conditions.joined(separator: "; ").capitalizedFirst + "." }
        if run.measurements.contains(where: { $0.repeats != nil }) {
            text += " Medians of timed repeats; ± is half the gap between the slowest and fastest."
        }
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

private struct FigureTile: View {
    var name: String
    var measurements: [BenchmarkMeasurement]
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.callout.weight(.medium)).foregroundStyle(.secondaryText).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(measurements) { measurement in
                    GridRow(alignment: .firstTextBaseline) {
                        if measurements.count > 1 {
                            Text(measurement.variant ?? "").font(.callout).foregroundStyle(.secondaryText).lineLimit(1)
                        }
                        Text(measurement.unit.format(measurement.value))
                            .font(.body.weight(.semibold))
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.fillShade.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.22)))
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
