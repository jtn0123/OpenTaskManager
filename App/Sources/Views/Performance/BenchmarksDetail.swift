import OTMKit
import SwiftUI

/// The Benchmarks workspace, at the foot of the Performance list: the CPU
/// benchmark and sustained run, GPU, disk and Internet tests, one family
/// on show at a time, with its saved-run picker before the comparison and
/// latest figures, how the Mac stood as it started, trends and Run all. The tests' sections are in
/// `BenchmarkSections.swift`. The tests run
/// through their own stores, so a run started here is the one the resource's
/// card shows, and the other way round. Its inputs don't change from tick to
/// tick and each section reads only its test's store, so the page redraws
/// with a run's progress, never per tick. There's no overall score: the
/// tests measure different things, and the Internet's figures aren't this Mac's.
///
/// A family selector pins as the page scrolls, with its saved run picker
/// directly below. Results, trends, Run all and methodology follow it.
struct BenchmarksDetail: View, Equatable {
    /// The startup volume's name ("Macintosh HD"), where the disk test writes.
    let homeVolume: String
    /// The disk it's on ("disk3"), as the snapshot has it.
    let homeDisk: String?
    /// The interface the Internet test goes over ("en0"), and its name ("Wi-Fi").
    let interface: String?
    let interfaceName: String?

    /// The pinned strip's height, which a jump clears so its target isn't under it.
    @State private var stripHeight: CGFloat = 0
    @State private var guidedPresented = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.homeVolume == rhs.homeVolume && lhs.homeDisk == rhs.homeDisk && lhs.interface == rhs.interface
            && lhs.interfaceName == rhs.interfaceName
    }

    var body: some View {
        let places = BenchmarkPlaces(homeVolume: homeVolume, homeDisk: homeDisk, interface: interface, interfaceName: interfaceName)
        ScrollViewReader { proxy in
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: .sectionHeaders) {
                BenchmarksHeader()
                Section {
                    let kind = BenchmarkWorkspace.shared.selectedKind
                    VStack(alignment: .leading, spacing: 16) {
                        SavedRuns(kind: kind, runs: BenchmarkHistories.runs(kind))
                            .equatable()
                            .modifier(BenchmarkScrollAnchor(id: BenchmarkAnchor.section(kind)))
                        selectedSection(kind, places: places)
                        SuiteCard(places: places)
                        WorkspaceMethodology()
                    }
                    .environment(\.benchmarkScrollClearance, stripHeight + 8)
                } header: {
                    BenchmarkContextStrip()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight = $0 }
                }
            }
            .onChange(of: BenchmarkWorkspace.shared.reveal) { _, reveal in
                guard let reveal else { return }
                Task {
                    // The comparison appears with the pick; scroll once it's laid out.
                    try? await Task.sleep(for: .milliseconds(120))
                    let target = reveal.section ? BenchmarkAnchor.section(reveal.kind) : BenchmarkAnchor.comparison(reveal.kind)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: reveal.aligned ? .top : nil)
                    }
                }
            }
        }
        .sheet(isPresented: $guidedPresented) {
            BenchmarkGuidedSheet(targets: places.suiteTargets, initialSelection: LaunchArgument.string("openBenchmarkGuided") ?? "all")
        }
        .task {
            #if DEBUG
            if LaunchArgument.string("openBenchmarkGuided") != nil { guidedPresented = true }
            #endif
            await DiskSpeedStore.shared.load()
            await NetworkQualityStore.shared.load()
            let runs = Dictionary(uniqueKeysWithValues: BenchmarkKind.allCases.map { ($0, BenchmarkHistories.runs($0)) })
            BenchmarkWorkspace.shared.handleLaunchArguments(runs: runs, targets: places.suiteTargets)
            // A card's Compare in Benchmarks opened the workspace.
            BenchmarkWorkspace.shared.revealPending()
        }
    }

    @ViewBuilder
    private func selectedSection(_ kind: BenchmarkKind, places: BenchmarkPlaces) -> some View {
        switch kind {
        case .cpu: CPUSection()
        case .sustained: SustainedSection()
        case .gpu: GPUSection()
        case .disk: DiskSection(places: places)
        case .network: NetworkSection(places: places)
        }
    }
}

/// Where the disk and Internet tests run, from the page's snapshot.
struct BenchmarkPlaces: Equatable {
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
enum BenchmarkHistories {
    static func runs(_ kind: BenchmarkKind) -> [BenchmarkRun] {
        if let fixture = GuidedBenchmarkFixture.runs(kind) { return BenchmarkRun.groupedSessions(fixture) }
        let runs: [BenchmarkRun] = switch kind {
        case .cpu: CPUBenchmarkStore.shared.history.map(BenchmarkRun.init)
        case .sustained: CPUSustainedStore.shared.history.map(BenchmarkRun.init)
        case .gpu: GPUBenchmarkStore.shared.history.map(BenchmarkRun.init)
        case .disk: DiskSpeedStore.shared.history.map(BenchmarkRun.init)
        case .network: NetworkQualityStore.shared.history.map(BenchmarkRun.init)
        }
        return BenchmarkRun.groupedSessions(runs)
    }

    static var anyRunning: Bool {
        CPUBenchmarkStore.shared.running != nil || CPUSustainedStore.shared.running != nil || GPUBenchmarkStore.shared.running != nil
            || DiskSpeedStore.shared.running != nil || NetworkQualityStore.shared.running != nil
    }
}

enum BenchmarkLook {
    /// A debug build's runs, as the CPU benchmark card marks them.
    static let debug = Theme.data(0.96, 0.50, 0.08)
    static let better = Theme.data(0.16, 0.66, 0.34)
    static let worse = Theme.data(0.92, 0.30, 0.26)
    /// A figure whose timing is in doubt: its mark and label.
    static let caution = Theme.data(0.86, 0.60, 0.02)

    static func tint(_ kind: BenchmarkKind) -> Color {
        switch kind {
        case .cpu, .sustained: Theme.cpu
        case .gpu: Theme.gpu
        case .disk: Theme.disk
        case .network: Theme.network
        }
    }

    static func symbol(_ kind: BenchmarkKind) -> String {
        switch kind {
        case .cpu: "cpu"
        case .sustained: "timer"
        case .gpu: "cube.transparent"
        case .disk: "internaldrive"
        case .network: "globe"
        }
    }

    /// "CPU", "Internet": the test's name in the pinned strip.
    static func shortTitle(_ kind: BenchmarkKind) -> String {
        switch kind {
        case .cpu: "CPU"
        case .sustained: "Sustained"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .network: "Internet"
        }
    }

    /// A verdict's mark, in a comparison's table and beside a trend.
    static func symbol(_ verdict: BenchmarkChange.Verdict) -> String {
        switch verdict {
        case .better: "checkmark.circle.fill"
        case .worse: "exclamationmark.circle.fill"
        case .withinSpread, .negligible, .unchanged: "equal.circle"
        case .measuredOnce, .timingUnverified: "questionmark.circle"
        }
    }

    /// Better and worse in colour; the verdicts that aren't a change in secondary text.
    static func color(_ verdict: BenchmarkChange.Verdict) -> AnyShapeStyle {
        switch verdict {
        case .better: AnyShapeStyle(better)
        case .worse: AnyShapeStyle(worse)
        case .withinSpread, .negligible, .measuredOnce, .unchanged, .timingUnverified: AnyShapeStyle(.secondaryText)
        }
    }

    static func color(_ change: BenchmarkChange) -> AnyShapeStyle {
        if change.isQualified { return AnyShapeStyle(caution) }
        return change.caveat == nil ? color(change.verdict) : AnyShapeStyle(.secondaryText)
    }

    static func symbol(_ change: BenchmarkChange) -> String {
        change.isQualified ? "exclamationmark.triangle" : symbol(change.verdict)
    }

    /// "Oct 6, 14:02".
    static func when(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// "Oct 6, 14:02 and 14:31", or "Oct 2, 09:10 and Oct 6, 14:02".
    static func span(_ earlier: Date, _ later: Date) -> String {
        let sameDay = Calendar.current.isDate(earlier, inSameDayAs: later)
        return "\(when(earlier)) and \(sameDay ? later.formatted(date: .omitted, time: .shortened) : when(later))"
    }
}

// MARK: - Header, methodology and the pinned strip

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

/// How the workspace compares runs, folded away under the page's intro.
private struct WorkspaceMethodology: View {
    var body: some View {
        MethodologyDisclosure(preview: "No overall score; a change counts only beyond the runs' own spread") {
            Text("Each test measures something different, so there's no overall score, and the Internet test's runs are kept "
                + "apart from the hardware's: they measure the connection and the server it reached at the time.")
            Text("Two runs are compared only when they ran the same test and workload version, on the same hardware, volume or "
                + "interface, with the same settings, from the same kind of build: a debug build runs the app's own code many "
                + "times slower.")
            Text("A change counts only when the two runs' ranges of repeats, slowest to fastest, don't overlap. A figure "
                + "measured once can't show that, and a figure whose timing is unverified is left out of the verdicts.")
        }
    }
}

/// The family selector stays visible while results scroll. It reads saved
/// histories and the selection, never a sample or a test's progress.
private struct BenchmarkContextStrip: View {
    var body: some View {
        let workspace = BenchmarkWorkspace.shared
        FlowRow(spacing: 6, lineSpacing: 6, spreads: false) {
            ForEach(BenchmarkKind.allCases, id: \.self) { kind in
                SectionLink(kind: kind, count: BenchmarkHistories.runs(kind).count, selected: workspace.selectedKind == kind) {
                    workspace.selectedKind = kind
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle().fill(.background).padding(.horizontal, -20)
        }
        .overlay(alignment: .bottom) {
            Divider().padding(.horizontal, -20)
        }
    }
}

/// A family choice with its run count; the selected one has a firmer outline.
private struct SectionLink: View {
    let kind: BenchmarkKind
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let tint = BenchmarkLook.tint(kind)
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: BenchmarkLook.symbol(kind)).foregroundStyle(tint)
                Text(BenchmarkLook.shortTitle(kind)).fontWeight(.medium)
                Text(count == 1 ? "1 run" : "\(count) runs").monospacedDigit().foregroundStyle(.secondaryText)
            }
            .font(.callout)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(tint.fillShade.opacity(selected ? 0.24 : 0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(selected ? 0.8 : 0.3)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Show \(kind.title): \(count == 1 ? "1 saved run" : "\(count) saved runs")")
        .accessibilityLabel("\(kind.title), \(count == 1 ? "1 saved run" : "\(count) saved runs")")
    }
}

// MARK: - Run all

/// Run all: the CPU and GPU benchmarks one after the other, then the disk
/// and Internet tests if ticked, with each step's state. It reads only the
/// workspace and whether a test is running, not any test's progress.
private struct SuiteCard: View {
    @State private var guidedPresented = false
    let places: BenchmarkPlaces

    var body: some View {
        let workspace = BenchmarkWorkspace.shared
        let targets = places.suiteTargets
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Run all", systemImage: "list.number").font(.headline)
                Text("CPU, then GPU, one at a time · about \(Self.benchmarkSeconds) s")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("One at a time, so neither slows the other. Each test's figures are saved and shown on their own.")
                Spacer(minLength: 8)
                if workspace.suiteRunning {
                    Button("Cancel All") { workspace.cancelAll() }
                        .help("Stop the test that's running and skip the rest")
                } else {
                    Button("Guided run…") { guidedPresented = true }
                        .disabled(BenchmarkHistories.anyRunning || GuidedBenchmarkFixture.enabled)
                    Button("Run All") { workspace.runAll(targets: targets) }
                        .disabled(BenchmarkHistories.anyRunning || GuidedBenchmarkFixture.enabled)
                        .help(BenchmarkHistories.anyRunning ? "Wait for the test that's running to finish"
                            : "Run the ticked tests one after the other")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SuiteOption(isOn: Binding(get: { workspace.includesDisk }, set: { workspace.includesDisk = $0 }),
                            title: "Then the disk test on \(targets.diskTarget?.title ?? places.homeVolume)",
                            detail: "writes a temporary file of up to \(Format.wholeBytes(DiskSpeedConfiguration.defaultFileSize)) in "
                                + "\(Self.folder(targets.diskTarget)), reads it back, then deletes it",
                            enabled: !workspace.suiteRunning && targets.diskTarget != nil)
                SuiteOption(isOn: Binding(get: { workspace.includesNetwork }, set: { workspace.includesNetwork = $0 }),
                            title: "Then the Internet test over \(places.interfaceTitle ?? "the network")",
                            detail: places.interface == nil ? "there's no network connection to test"
                                : "fills the connection for about \(Int(NetworkQuality.typicalSeconds)) s",
                            enabled: !workspace.suiteRunning && places.interface != nil)
            }
            if !workspace.steps.isEmpty {
                SuiteSteps(steps: workspace.steps, position: workspace.position)
            }
        }
        .sheet(isPresented: $guidedPresented) {
            BenchmarkGuidedSheet(targets: targets, initialSelection: "all")
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

/// An optional step in a line: what it is, then what it does in secondary text.
private struct SuiteOption: View {
    @Binding var isOn: Bool
    var title: String
    var detail: String
    var enabled: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("\(title)  \(Text(detail).font(.explanation).foregroundStyle(.secondaryText))")
                .fixedSize(horizontal: false, vertical: true)
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
                Text((BenchmarkWorkspace.shared.passTitle.map { $0 + " · " } ?? "")
                    + "Step \(position.step) of \(position.of): \(running.kind.title)…")
                    .font(.body.weight(.medium))
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
