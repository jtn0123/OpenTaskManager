import AppKit
import Observation
import OTMKit

/// One review, already read before the sheet appears. Nothing is polled while it is open.
@MainActor
@Observable
final class StorageCleanupModel: Identifiable {
    let id = UUID()
    let items: [StorageCleanupItem]
    let scope: StorageScope
    var selection: Set<String>
    private(set) var moving = false
    private(set) var execution: StorageCleanupExecution?

    init(items: [StorageCleanupItem], scope: StorageScope) {
        self.items = items
        self.scope = scope
        selection = Set(items.filter(\.preselected).map(\.id))
    }

    var selectedCount: Int { items.filter { selection.contains($0.id) && $0.refusal == nil }.count }
    var summary: String { StorageCleanupText.selected(items, selection: selection) }

    func move() async {
        guard !moving, execution == nil, selectedCount > 0 else { return }
        moving = true
        execution = await StorageCleanupExecution.run(items, selection: selection, home: NSHomeDirectory(), recycler: WorkspaceRecycler())
        moving = false
    }
}

/// This is the only route from a storage review to the Trash.
@MainActor
private struct WorkspaceRecycler: StorageCleanupRecycler {
    func recycle(_ path: String) async -> RemovalResult {
        do {
            let moved = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: path)])
            return .moved(to: moved.values.first?.path ?? "")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension StorageStore {
    /// A pick uses the scan's metadata, never metadata first read after selection.
    func cleanupPick(_ path: String) -> StorageCleanupPick? {
        guard let usage = result?.usage else { return nil }
        if let file = usage.largestFiles.first(where: { $0.path == path }) {
            return StorageCleanupPick(path: path, identity: file.identity, allocated: file.allocatedSize, logical: file.logicalSize,
                                      modified: file.modified, scannedAt: usage.finishedAt, isFolder: file.isPackage)
        }
        guard let item = usage.item(atPath: path), item.kind != .smallerItems else { return nil }
        return StorageCleanupPick(path: path, identity: item.identity, allocated: item.allocatedSize, logical: item.logicalSize,
                                  modified: item.modified, scannedAt: usage.finishedAt, isFolder: item.kind != .file)
    }

    func addToCleanup(_ path: String) {
        if cleanupPick(path) != nil { cleanupSelection.insert(path) }
    }

    /// Cmd toggles one path; Shift spans the list's fixed scan order.
    func selectForCleanup(_ path: String, command: Bool, shift: Bool) {
        guard let files = result?.usage.largestFiles else { return }
        let selection = StorageCleanupRules.select(path, order: files.map(\.path), current: .init(paths: cleanupSelection, anchor: cleanupAnchor),
                                                   command: command, shift: shift)
        cleanupSelection = selection.paths
        cleanupAnchor = selection.anchor
    }

    func reviewCleanup() {
        guard !readingCleanup, !cleanupSelection.isEmpty, let result else { return }
        let picks = cleanupSelection.sorted().compactMap(cleanupPick)
        let home = NSHomeDirectory()
        let readID = cleanupReadID
        readingCleanup = true
        Task {
            let items = await Task.detached(priority: .userInitiated) { StorageCleanupReader.review(picks, home: home) }.value
            guard cleanupReadID == readID, self.result?.usage.finishedAt == result.usage.finishedAt, !isScanning else { return }
            readingCleanup = false
            cleanupReview = StorageCleanupModel(items: items, scope: result.scope)
        }
    }
}
