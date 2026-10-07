import AppKit
import Observation
import OTMKit

/// One removal review: what was found with the app, what's selected, what's
/// running from it, and what happened once it ran.
///
/// Finding and measuring happen off the main actor when the sheet opens.
/// While it's open, the processes running from the app are checked once a
/// second, so the review notices the app quitting (or starting). Removal
/// unloads the app's launch agents, waits for the app to stop, then moves
/// the bundle to the Trash and, only if that worked, the rest, one item at
/// a time so each failure is reported.
@MainActor
@Observable
final class AppRemovalModel {
    enum Phase: Equatable {
        case finding
        case reviewing
        /// Running a removal; the text says which step.
        case removing(String)
        case finished
    }

    let app: InstalledApp
    private(set) var phase = Phase.finding
    private(set) var plan: AppRemovalPlan?
    var selection: Set<LeftoverItem.ID> = []
    private(set) var sizes: [LeftoverItem.ID: UInt64] = [:]
    private(set) var isMeasuring = false
    private(set) var running = RunningCheck()
    /// Quit was pressed and the processes it asked haven't all gone yet.
    private(set) var isQuitting = false
    private(set) var outcomes: [RemovalOutcome] = []
    private(set) var icons: [String: NSImage] = [:]
    /// When each item was last modified, as Finder's Date Modified shows it,
    /// to tell a leftover in use from one long forgotten. Read once, with the plan.
    private(set) var modified: [String: Date] = [:]

    init(app: InstalledApp) {
        self.app = app
    }

    // MARK: Derived

    var selectedItems: [LeftoverItem] {
        plan?.items.filter { selection.contains($0.id) } ?? []
    }

    var selectedBytes: UInt64 {
        selectedItems.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    /// Whether the bundle went to the Trash, so the Apps list can drop it.
    var appWasMoved: Bool {
        outcomes.contains { $0.path == app.resolvedPath && $0.result.succeeded }
    }

    var canRemove: Bool {
        phase == .reviewing && plan?.blocker == nil && running.isClear && !selectedItems.isEmpty
    }

    private var bundles: [String] { [app.path, app.resolvedPath] }

    // MARK: Finding

    /// Reads launchd's jobs and the Library folders, then starts the review.
    func load(otherApps: [InstalledApp]) async {
        let app = app
        let (plan, modified) = await Task.detached(priority: .userInitiated) {
            let plan = AppRemoval.plan(for: app, otherApps: otherApps, launchItems: LaunchItems.scan())
            var modified: [String: Date] = [:]
            for path in plan.items.map(\.path) + plan.protected.map(\.path) {
                // Not following a link, so a link to the app says when the link was made.
                if let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date {
                    modified[path] = date
                }
            }
            return (plan, modified)
        }.value
        guard !Task.isCancelled else { return }
        self.plan = plan
        self.modified = modified
        selection = plan.preselected
        for path in plan.items.map(\.path) + plan.protected.map(\.path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 32, height: 32)
            icons[path] = icon
        }
        await refreshRunning()
        phase = .reviewing
    }

    /// Measures each item in turn, until done or the sheet closes.
    func measureSizes() async {
        guard let items = plan?.items.filter(\.location.isMeasured) else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        for item in items {
            let stop = CancellationFlag()
            let path = item.path
            let bytes = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) { AppRemoval.allocatedSize(atPath: path, isCancelled: { stop.isSet }) }.value
            } onCancel: {
                stop.set()
            }
            guard !Task.isCancelled else { return }
            if let bytes { sizes[item.id] = bytes }
        }
    }

    // MARK: Running processes

    /// Checks once a second while the review is up.
    func watchRunning() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if phase == .reviewing { await refreshRunning() }
        }
    }

    func refreshRunning() async {
        let bundles = bundles
        let agents = selectedItems.compactMap(\.launchItem)
        let check = await Task.detached(priority: .userInitiated) {
            AppRemoval.classify(AppRemoval.runningProcesses(inside: bundles), unloading: agents)
        }.value
        if check != running { running = check }
        if running.needQuitting.isEmpty { isQuitting = false }
    }

    /// Asks the app, and anything else of yours running from it, to quit:
    /// apps the way the Dock's Quit does (they can ask to save), other
    /// processes with SIGTERM.
    func quit() {
        isQuitting = true
        for process in running.needQuitting {
            if let runningApp = NSRunningApplication(processIdentifier: process.pid) {
                runningApp.terminate()
            } else {
                kill(process.pid, SIGTERM)
            }
        }
    }

    // MARK: Removing

    func remove() async {
        guard canRemove else { return }
        let order = AppRemoval.trashOrder(selectedItems)
        var results: [String: RemovalResult] = [:]

        // Unload agents first, so launchd neither restarts what runs from the
        // app nor keeps a job whose property list is gone.
        phase = .removing("Unloading launch agents…")
        for agent in order.unload {
            if let error = await Task.detached(priority: .userInitiated, operation: { AppRemoval.unload(agent) }).value {
                results[agent.plistPath] = .failed("Couldn't unload it, so it stays: \(error)")
            }
        }

        // Don't move an app that's still running.
        phase = .removing("Waiting for \(app.name) to stop…")
        let stillRunning = await waitUntilStopped()
        if !stillRunning.isEmpty {
            let names = stillRunning.map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", ")
            for item in order.app + order.rest where results[item.path] == nil {
                results[item.path] = .skipped("Left in place: \(names) is still running from the app.")
            }
            finish(with: results)
            return
        }

        phase = .removing("Moving to the Trash…")
        for item in order.app {
            results[item.path] = await recycle(item.path)
        }
        let appMoved = order.app.allSatisfy { results[$0.path]?.succeeded == true }
        for item in order.rest where results[item.path] == nil {
            results[item.path] = appMoved ? await recycle(item.path) : .skipped("Left in place because the app couldn't be moved.")
        }
        finish(with: results)
    }

    /// Waits up to five seconds for every process running from the app to
    /// exit, and returns those that haven't.
    private func waitUntilStopped() async -> [BundleProcess] {
        let bundles = bundles
        var remaining: [BundleProcess] = []
        for attempt in 0..<20 {
            remaining = await Task.detached(priority: .userInitiated) { AppRemoval.runningProcesses(inside: bundles) }.value
            if remaining.isEmpty || attempt == 19 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return remaining
    }

    /// Moves one item to the Trash the way Finder does, so it can be put back.
    private func recycle(_ path: String) async -> RemovalResult {
        do {
            let moved = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: path)])
            return .moved(to: moved.values.first?.path ?? "")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func finish(with results: [String: RemovalResult]) {
        outcomes = (plan?.items ?? []).compactMap { item in
            results[item.path].map { RemovalOutcome(path: item.path, result: $0) }
        }
        phase = .finished
    }
}
