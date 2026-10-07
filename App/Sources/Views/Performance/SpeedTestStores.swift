import AppKit
import Observation
import OTMKit

/// The Internet quality test on the network detail. Nothing runs until the
/// user starts it, and only one test runs at a time (two would measure each
/// other). Kept for the session, so a run survives switching resources or
/// pages. The history loads once and each result is saved off the main actor.
@Observable
@MainActor
final class NetworkQualityStore {
    static let shared = NetworkQualityStore()

    struct Run: Equatable {
        let interface: String
        let started: Date
    }

    /// Saved results, newest first, every interface.
    private(set) var history: [NetworkQualityResult] = []
    private(set) var running: Run?
    /// Why the last run on each interface failed.
    private(set) var failures: [String: String] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start and cancel, so a stopped run's late result is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var handledLaunchArgument = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        let saved = await Task.detached(priority: .utility) { SpeedTestHistory.networkQuality.load() }.value
        let added = history.filter { result in !saved.contains { $0.date == result.date } }
        history = (added + saved).sorted { $0.date > $1.date }
    }

    /// This interface's results, newest first.
    func results(for interface: String) -> [NetworkQualityResult] {
        history.filter { $0.historyKey == interface }
    }

    func start(interface: String) {
        guard running == nil else { return }
        generation += 1
        let generation = generation
        running = Run(interface: interface, started: Date())
        failures[interface] = nil
        task = Task { [weak self] in
            do throws(NetworkQualityError) {
                let result = try await NetworkQuality.run(interface: interface)
                let saved = await Task.detached(priority: .utility) { try? SpeedTestHistory.networkQuality.append(result) }.value
                BenchmarkWorkspace.shared.noteResult(at: result.date)
                guard let self, self.generation == generation else { return }
                history = saved ?? [result] + history
            } catch {
                guard let self, self.generation == generation else { return }
                if error != .cancelled { failures[interface] = error.message }
            }
            self?.finish(generation)
        }
    }

    func cancel() {
        task?.cancel()
        finish(generation)
    }

    /// Returns once the test in progress, if any, has ended, for Run all.
    func waitForRun() async {
        await task?.value
    }

    private func finish(_ generation: Int) {
        guard generation == self.generation, running != nil else { return }
        self.generation += 1
        running = nil
        task = nil
    }

    /// `--args -openResource network -openSpeedTest start` starts a test
    /// when the card first shows, for screenshots of a running and a
    /// finished test.
    func handleLaunchArgument(interface: String) {
        guard !handledLaunchArgument else { return }
        handledLaunchArgument = true
        if LaunchArgument.startsTest(on: "network") { start(interface: interface) }
    }
}

/// Where a disk speed test makes its temporary file.
struct DiskSpeedTarget: Hashable, Identifiable {
    enum Kind: Hashable {
        /// A temporary folder on the home volume.
        case home
        case volume
        case folder
    }

    let kind: Kind
    let title: String
    /// The folder the file goes in.
    let path: String

    var id: String { path }

    var symbol: String {
        switch kind {
        case .home: "house"
        case .volume: "externaldrive"
        case .folder: "folder"
        }
    }

    /// Where it is, in a few words.
    var subtitle: String {
        switch kind {
        case .home: "temporary folder"
        case .volume: path
        case .folder: (path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// A volume on the disk the detail shows, as far as the test cares. Only
/// what doesn't change from tick to tick, so the card isn't redrawn per tick.
struct DiskSpeedVolumeChoice: Hashable {
    let name: String
    let mountPoint: String
    let isRoot: Bool
}

/// The disk speed test on the disk detail. Like the network test: nothing
/// runs until asked, one at a time, kept for the session, history loaded
/// once and each result saved off the main actor. Progress arrives at most
/// four times a second.
@Observable
@MainActor
final class DiskSpeedStore {
    static let shared = DiskSpeedStore()

    struct Run: Equatable {
        let disk: String
        let target: DiskSpeedTarget
        let started: Date
    }

    /// Saved results, newest first, every volume.
    private(set) var history: [DiskSpeedResult] = []
    private(set) var running: Run?
    private(set) var progress: DiskSpeedProgress?
    /// Why the last run on each disk failed.
    private(set) var failures: [String: String] = [:]
    /// The disk the home volume is on, where the default target lives.
    private(set) var homeDisk: String?
    /// The pick on each disk, when it isn't the default.
    private(set) var picks: [String: DiskSpeedTarget] = [:]
    /// The volume behind each target path, for its results.
    private(set) var volumeKeys: [String: String] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var handledLaunchArgument = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        let (saved, home) = await Task.detached(priority: .utility) {
            (SpeedTestHistory.diskSpeed.load(), DiskSpeedVolume.containing(DiskSpeedTest.defaultFolder))
        }.value
        let added = history.filter { result in !saved.contains { $0.date == result.date } }
        history = (added + saved).sorted { $0.date > $1.date }
        homeDisk = home?.physicalDisk
        if let home { volumeKeys[DiskSpeedTest.defaultFolder] = home.key }
    }

    /// The places on `disk` a test can use: the home volume's temporary
    /// folder when it's on this disk, the disk's other volumes, and any folder picked.
    func targets(disk: String, volumes: [DiskSpeedVolumeChoice]) -> [DiskSpeedTarget] {
        var targets: [DiskSpeedTarget] = []
        let holdsHome = homeDisk.map { $0 == disk } ?? volumes.contains(where: \.isRoot)
        if holdsHome {
            let name = volumes.first(where: \.isRoot)?.name ?? "Home volume"
            targets.append(DiskSpeedTarget(kind: .home, title: name, path: DiskSpeedTest.defaultFolder))
        }
        targets += volumes.filter { !$0.isRoot }.map { DiskSpeedTarget(kind: .volume, title: $0.name, path: $0.mountPoint) }
        if let pick = picks[disk], !targets.contains(pick) { targets.append(pick) }
        return targets
    }

    func target(disk: String, volumes: [DiskSpeedVolumeChoice]) -> DiskSpeedTarget? {
        let targets = targets(disk: disk, volumes: volumes)
        return picks[disk].flatMap { targets.contains($0) ? $0 : nil } ?? targets.first
    }

    func pick(_ target: DiskSpeedTarget, disk: String) {
        picks[disk] = target
        resolveVolume(of: target.path)
    }

    /// The results for the volume `target` is on, newest first.
    func results(for target: DiskSpeedTarget) -> [DiskSpeedResult] {
        guard let key = volumeKeys[target.path] else { return [] }
        return history.filter { $0.historyKey == key }
    }

    /// Looks up which volume a path is on, once per path, off the main actor.
    func resolveVolume(of path: String) {
        guard volumeKeys[path] == nil else { return }
        Task {
            let volume = await Task.detached(priority: .utility) { DiskSpeedVolume.containing(path) }.value
            if let volume { volumeKeys[path] = volume.key }
        }
    }

    func start(disk: String, target: DiskSpeedTarget) {
        guard running == nil else { return }
        generation += 1
        let generation = generation
        running = Run(disk: disk, target: target, started: Date())
        progress = nil
        failures[disk] = nil
        let report: @Sendable (DiskSpeedProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.progress = progress
            }
        }
        task = Task { [weak self] in
            do throws(DiskSpeedError) {
                let result = try await DiskSpeedTest.measure(in: target.path, progress: report)
                let saved = await Task.detached(priority: .utility) { try? SpeedTestHistory.diskSpeed.append(result) }.value
                BenchmarkWorkspace.shared.noteResult(at: result.date)
                guard let self, self.generation == generation else { return }
                volumeKeys[target.path] = result.historyKey
                history = saved ?? [result] + history
            } catch {
                guard let self, self.generation == generation else { return }
                if error != .cancelled { failures[disk] = error.message }
            }
            self?.finish(generation)
        }
    }

    func cancel() {
        task?.cancel()
        finish(generation)
    }

    /// Returns once the test in progress, if any, has ended, for Run all.
    func waitForRun() async {
        await task?.value
    }

    private func finish(_ generation: Int) {
        guard generation == self.generation, running != nil else { return }
        self.generation += 1
        running = nil
        progress = nil
        task = nil
    }

    /// Picks a folder with the open panel, for a disk test there.
    func chooseFolder(disk: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder on the volume to test. The test writes a temporary file there and deletes it when done."
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            let title = FileManager.default.displayName(atPath: url.path)
            self?.pick(DiskSpeedTarget(kind: .folder, title: title, path: url.path), disk: disk)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// `--args -openResource disk -openSpeedTest start` starts a test when
    /// the card first shows, for screenshots of a running and a finished test.
    func handleLaunchArgument(disk: String, target: DiskSpeedTarget?) {
        guard !handledLaunchArgument else { return }
        handledLaunchArgument = true
        if LaunchArgument.startsTest(on: "disk"), let target { start(disk: disk, target: target) }
    }
}
