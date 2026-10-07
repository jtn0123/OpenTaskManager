import AppKit
import Observation
import OTMKit

/// Where a scan starts.
enum StorageScope: Hashable, Identifiable {
    case home
    case volume(VolumeInfo)
    case folder(URL)

    var id: String { path }

    var path: String {
        switch self {
        case .home: NSHomeDirectory()
        case let .volume(volume): volume.mountPoint
        case let .folder(url): url.path
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case let .volume(volume): volume.name
        case let .folder(url): FileManager.default.displayName(atPath: url.path)
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case let .volume(volume): volume.isRemovable || !volume.isInternal ? "externaldrive" : "internaldrive"
        case .folder: "folder"
        }
    }

    /// Where it is, in a word or a short path.
    var subtitle: String {
        switch self {
        case .home: NSHomeDirectory()
        case let .volume(volume): volume.isRoot ? "Startup disk" : volume.mountPoint
        case let .folder(url): (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    var request: DiskScanRequest {
        switch self {
        case .home: DiskScanRequest(root: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        case let .volume(volume): .volume(mountPoint: volume.mountPoint, isRoot: volume.isRoot)
        case let .folder(url): DiskScanRequest(root: url)
        }
    }

    /// The space a volume reports in use, for a rough idea of how far along a scan is.
    var expectedBytes: UInt64? {
        if case let .volume(volume) = self { return volume.usedBytes }
        return nil
    }

    /// The scope for a path: home, a volume's mount point, or any other folder.
    static func resolve(_ path: String, volumes: [VolumeInfo]) -> StorageScope {
        let standard = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        if standard == (NSHomeDirectory() as NSString).standardizingPath { return .home }
        if let volume = volumes.first(where: { $0.mountPoint == standard }) { return .volume(volume) }
        return .folder(URL(fileURLWithPath: standard, isDirectory: true))
    }
}

/// Which list sits beside the treemap.
enum StorageList: String, CaseIterable, Identifiable {
    case contents = "This Folder"
    case largest = "Largest Files"

    var id: String { rawValue }
}

/// A finished scan and where it started.
struct StorageResult {
    let scope: StorageScope
    let usage: DiskUsage
}

/// The Storage page's state, kept for the whole session so a scan survives
/// switching pages. Nothing scans until asked: a scan starts from the Scan
/// button or a scope pick, runs on its own thread, and reports progress at
/// most four times a second.
@Observable
@MainActor
final class StorageStore {
    static let shared = StorageStore()
    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    private(set) var volumes: [VolumeInfo] = []
    /// The scope the next Scan uses: the last one picked.
    private(set) var scope: StorageScope = .home
    /// Set while a scan runs.
    private(set) var scanning: StorageScope?
    private(set) var progress: DiskScanProgress?
    private(set) var result: StorageResult?
    /// The folder the treemap and list show, as an item of `result`.
    var folder = 0
    var list: StorageList = .contents
    /// Launch arguments are acted on once per run.
    @ObservationIgnored private var handledLaunchArguments = false
    /// A folder `-openStorageFolder` asked to open once the scan is in.
    @ObservationIgnored private var requestedFolder: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every scan and stop, so a stale scan's late progress is ignored.
    @ObservationIgnored private var generation = 0

    var isScanning: Bool { scanning != nil }

    /// Home, the startup disk, then the other local volumes.
    var scopes: [StorageScope] {
        let local = volumes.filter { $0.physicalDisk != nil || $0.isRoot }
            .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
        return [.home] + local.map { .volume($0) }
    }

    func loadVolumes() async {
        let read = await Task.detached(priority: .userInitiated) { VolumeReader.read() }.value
        if read != volumes { volumes = read }
    }

    func scan(_ scope: StorageScope) {
        task?.cancel()
        generation += 1
        let generation = generation
        self.scope = scope
        scanning = scope
        progress = nil
        let request = scope.request
        let report: @Sendable (DiskScanProgress) -> Void = { [weak self] progress in
            let store = self
            Task { @MainActor in
                guard let store, store.generation == generation else { return }
                store.progress = progress
            }
        }
        task = Task { [weak self] in
            let usage = try? await DiskUsageScanner.scan(request, progress: report)
            guard let self, self.generation == generation else { return }
            if let usage {
                result = StorageResult(scope: scope, usage: usage)
                folder = 0
                if let path = requestedFolder, let item = usage.item(atPath: path), item.isFolder { folder = item.id }
                requestedFolder = nil
            }
            scanning = nil
            progress = nil
        }
    }

    func rescan() {
        scan(scope)
    }

    func stop() {
        task?.cancel()
        task = nil
        generation += 1
        scanning = nil
        progress = nil
    }

    /// Picks a folder with the open panel, then scans it.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to see what's using its space."
        if case let .folder(url) = scope { panel.directoryURL = url.deletingLastPathComponent() }
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            self?.scan(.folder(url))
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// `--args -openStorageScope ~/Downloads` scans that folder (or volume)
    /// when the page first opens; `-openStorageFolder Library/Caches` then
    /// opens that folder in the results, and `-openStorageList largest`
    /// shows the largest files. For screenshots.
    func handleLaunchArguments() {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        if LaunchArgument.string("openStorageList") == "largest" { list = .largest }
        guard let path = LaunchArgument.string("openStorageScope") else { return }
        requestedFolder = LaunchArgument.string("openStorageFolder")
        scan(StorageScope.resolve(path, volumes: volumes))
    }

    // MARK: - Actions

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func openFullDiskAccessSettings() {
        if let url = Self.fullDiskAccessSettings { NSWorkspace.shared.open(url) }
    }
}
