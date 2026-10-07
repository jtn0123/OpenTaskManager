import AppKit
import Observation
import OTMKit
import UniformTypeIdentifiers

/// The Benchmarks workspace's own state, kept for the session: the newest
/// saved result's date for the resource list, the two runs picked for
/// comparison in each test (remembered between launches), and Run all,
/// which starts the tests' own stores one after another, so a run started
/// here is the same run each resource's card shows. Nothing here runs per tick.
@Observable
@MainActor
final class BenchmarkWorkspace {
    static let shared = BenchmarkWorkspace()

    enum StepState: Equatable {
        case waiting, running, finished, cancelled
        case failed(String)
        /// Left out after a cancel, or skipped because an earlier step was stopped.
        case notRun
    }

    struct Step: Identifiable, Equatable {
        let kind: BenchmarkKind
        var state: StepState
        var id: BenchmarkKind { kind }
    }

    /// A request to bring a test's comparison into view: when a second run is
    /// ticked, only as far as it takes, and for `-openBenchmarkCompare`, to the
    /// top. The serial tells two requests for the same test apart.
    struct Reveal: Equatable {
        let kind: BenchmarkKind
        /// Scrolled to the top of the page, under the pinned strip.
        let aligned: Bool
        let serial: Int
    }

    /// Where Run all's disk test writes and which interface its Internet test loads.
    struct SuiteTargets: Equatable {
        /// The disk holding the folder ("disk3"), as the disk store keys its runs.
        var disk: String?
        var diskTarget: DiskSpeedTarget?
        var interface: String?
    }

    private static let picksKey = "benchmarkComparePicks"
    private static let includesDiskKey = "benchmarkSuiteIncludesDisk"
    private static let includesNetworkKey = "benchmarkSuiteIncludesNetwork"

    /// The newest saved result of any test; nil until the files are read, or with none.
    private(set) var newest: Date?
    /// Run all's steps: the last suite's, or the running one's.
    private(set) var steps: [Step] = []
    private(set) var suiteRunning = false
    /// Each test's runs picked for comparison, by id, in the order picked: at most two.
    private(set) var picks: [BenchmarkKind: [String]]
    /// The last request to show a comparison; the workspace scrolls when it changes.
    private(set) var reveal: Reveal?
    /// Whether Run all adds the disk test, which writes a temporary file.
    var includesDisk: Bool {
        didSet { UserDefaults.standard.set(includesDisk, forKey: Self.includesDiskKey) }
    }

    /// Whether Run all adds the Internet test, which loads the connection.
    var includesNetwork: Bool {
        didSet { UserDefaults.standard.set(includesNetwork, forKey: Self.includesNetworkKey) }
    }

    @ObservationIgnored private var summaryLoaded = false
    @ObservationIgnored private var suiteTask: Task<Void, Never>?
    @ObservationIgnored private var current: BenchmarkKind?
    @ObservationIgnored private var handledLaunchArguments = false

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.dictionary(forKey: Self.picksKey) as? [String: [String]] ?? [:]
        picks = Dictionary(uniqueKeysWithValues: saved.compactMap { key, ids in BenchmarkKind(rawValue: key).map { ($0, ids) } })
        includesDisk = defaults.bool(forKey: Self.includesDiskKey)
        includesNetwork = defaults.bool(forKey: Self.includesNetworkKey)
    }

    // MARK: - The newest result

    /// Reads the four history files once, off the main actor, for the date
    /// of the newest result.
    func loadSummary() async {
        guard !summaryLoaded else { return }
        summaryLoaded = true
        let date = await Task.detached(priority: .utility) { BenchmarkLibrary().load().first?.date }.value
        if let date { noteResult(at: date) }
    }

    /// Called by each test's store when a result is saved.
    func noteResult(at date: Date) {
        if newest.map({ date > $0 }) ?? true { newest = date }
    }

    // MARK: - Comparison picks

    /// The picked runs of a test that are still saved, the earlier first.
    func picked(_ kind: BenchmarkKind, among runs: [BenchmarkRun]) -> [BenchmarkRun] {
        (picks[kind] ?? []).compactMap { id in runs.first { $0.id == id } }.sorted { $0.date < $1.date }
    }

    /// Picks a run, or drops it if picked; a third pick drops the oldest pick.
    /// A pick that makes a pair asks for the comparison to be shown.
    func togglePick(_ run: BenchmarkRun) {
        var ids = picks[run.kind] ?? []
        if let index = ids.firstIndex(of: run.id) {
            ids.remove(at: index)
        } else {
            ids.append(run.id)
            if ids.count > 2 { ids.removeFirst(ids.count - 2) }
            if ids.count == 2 { requestReveal(run.kind, aligned: false) }
        }
        picks[run.kind] = ids
        savePicks()
    }

    private func requestReveal(_ kind: BenchmarkKind, aligned: Bool) {
        reveal = Reveal(kind: kind, aligned: aligned, serial: (reveal?.serial ?? 0) + 1)
    }

    func clearPicks(_ kind: BenchmarkKind) {
        picks[kind] = nil
        savePicks()
    }

    private func savePicks() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: picks.map { ($0.key.rawValue, $0.value) }), forKey: Self.picksKey)
    }

    // MARK: - Run all

    /// Runs the CPU and GPU benchmarks, then the disk and Internet tests if
    /// ticked, one at a time through their own stores. A failed step is
    /// noted and the next one starts; a cancelled one ends the suite.
    func runAll(targets: SuiteTargets) {
        guard !suiteRunning else { return }
        var kinds: [BenchmarkKind] = [.cpu, .gpu]
        if includesDisk, targets.diskTarget != nil { kinds.append(.disk) }
        if includesNetwork, targets.interface != nil { kinds.append(.network) }
        steps = kinds.map { Step(kind: $0, state: .waiting) }
        suiteRunning = true
        suiteTask = Task { [weak self] in
            for index in kinds.indices {
                guard let self, !Task.isCancelled else { break }
                steps[index].state = .running
                current = kinds[index]
                let state = await run(kinds[index], targets: targets)
                steps[index].state = Task.isCancelled && state != .finished ? .cancelled : state
                if Task.isCancelled || state == .cancelled { break }
            }
            self?.endSuite()
        }
    }

    func cancelAll() {
        suiteTask?.cancel()
        switch current {
        case .cpu: CPUBenchmarkStore.shared.cancel()
        case .gpu: GPUBenchmarkStore.shared.cancel()
        case .disk: DiskSpeedStore.shared.cancel()
        case .network: NetworkQualityStore.shared.cancel()
        case nil: break
        }
    }

    /// The step running now, 1-based, and how many there are.
    var position: (step: Int, of: Int)? {
        guard suiteRunning, let index = steps.firstIndex(where: { $0.state == .running }) else { return nil }
        return (index + 1, steps.count)
    }

    private func endSuite() {
        for index in steps.indices where steps[index].state == .waiting || steps[index].state == .running {
            steps[index].state = .notRun
        }
        suiteRunning = false
        current = nil
        suiteTask = nil
    }

    private func run(_ kind: BenchmarkKind, targets: SuiteTargets) async -> StepState {
        let started = Date()
        switch kind {
        case .cpu:
            let store = CPUBenchmarkStore.shared
            store.start()
            await store.waitForRun()
            return Self.outcome(failure: store.failure, newest: store.history.first?.date, since: started)
        case .gpu:
            let store = GPUBenchmarkStore.shared
            guard store.device != nil else { return .failed(GPUBenchmarkError.noDevice.message) }
            store.start()
            await store.waitForRun()
            return Self.outcome(failure: store.failure, newest: store.history.first?.date, since: started)
        case .disk:
            let store = DiskSpeedStore.shared
            guard let disk = targets.disk, let target = targets.diskTarget else { return .notRun }
            await store.load()
            store.start(disk: disk, target: target)
            await store.waitForRun()
            return Self.outcome(failure: store.failures[disk], newest: store.history.first?.date, since: started)
        case .network:
            let store = NetworkQualityStore.shared
            guard let interface = targets.interface else { return .notRun }
            await store.load()
            store.start(interface: interface)
            await store.waitForRun()
            return Self.outcome(failure: store.failures[interface], newest: store.history.first?.date, since: started)
        }
    }

    /// A step that ended with neither a new result nor a failure was cancelled.
    private static func outcome(failure: String?, newest: Date?, since started: Date) -> StepState {
        if let failure { return .failed(failure) }
        return (newest ?? .distantPast) >= started ? .finished : .cancelled
    }

    // MARK: - Launch arguments

    /// For screenshots: `-openBenchmarkCompare gpu:1,2` picks a test's
    /// first and second saved runs, newest first, for this launch only, and
    /// scrolls to their comparison; `-openResource benchmarks -openSpeedTest
    /// start` starts Run all.
    func handleLaunchArguments(runs: [BenchmarkKind: [BenchmarkRun]], targets: SuiteTargets) {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        if let request = LaunchArgument.string("openBenchmarkCompare") {
            let parts = request.split(separator: ":")
            if parts.count == 2, let kind = BenchmarkKind(rawValue: String(parts[0])), let saved = runs[kind] {
                let ids = parts[1].split(separator: ",").compactMap { Int($0) }.compactMap { saved.indices.contains($0 - 1) ? saved[$0 - 1].id : nil }
                picks[kind] = Array(ids.prefix(2))
                if ids.count >= 2 { requestReveal(kind, aligned: true) }
            }
        }
        if LaunchArgument.startsTest(on: "benchmarks") { runAll(targets: targets) }
    }

    // MARK: - Export

    enum ExportFormat {
        case json, markdown
    }

    /// Saves the runs on show, and each test's comparison, with a save panel.
    func export(_ runs: [BenchmarkRun], comparisons: [(BenchmarkRun, BenchmarkRun)], as format: ExportFormat) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let export = BenchmarkExport(exported: Date(), app: "OpenTaskManager \(version)".trimmingCharacters(in: .whitespaces), runs: runs,
                                     comparisons: comparisons)
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        switch format {
        case .json:
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Benchmarks \(day).json"
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "Benchmarks \(day).md"
        }
        panel.canCreateDirectories = true
        panel.message = "The saved benchmark results and any comparisons, as \(format == .json ? "JSON" : "Markdown")."
        let write = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            let data: Data? = switch format {
            case .json: try? export.json()
            case .markdown: Data(export.markdown().utf8)
            }
            do {
                try data?.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }
}
