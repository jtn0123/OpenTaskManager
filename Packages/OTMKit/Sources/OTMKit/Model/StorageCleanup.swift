import Foundation

/// The volume and file identifiers read by the scan, kept only for its bounded results.
public struct StorageFileIdentity: Sendable, Codable, Hashable {
    public let volume: String
    public let file: String

    public init(volume: String, file: String) {
        self.volume = volume
        self.file = file
    }

    public init?(attributes: [FileAttributeKey: Any]) {
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        self.init(volume: volume.stringValue, file: file.stringValue)
    }

    public static func read(_ url: URL) -> StorageFileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return StorageFileIdentity(attributes: attributes)
    }
}

/// What the scan knew about one picked path. A folder's sizes include its contents.
public struct StorageCleanupPick: Sendable, Hashable {
    public let path: String
    public let identity: StorageFileIdentity?
    public let allocated: UInt64
    public let logical: UInt64
    public let modified: Date?
    public let scannedAt: Date
    public let isFolder: Bool

    public init(path: String, identity: StorageFileIdentity?, allocated: UInt64, logical: UInt64,
                modified: Date?, scannedAt: Date, isFolder: Bool) {
        self.path = path
        self.identity = identity
        self.allocated = allocated
        self.logical = logical
        self.modified = modified
        self.scannedAt = scannedAt
        self.isFolder = isFolder
    }
}

/// A refreshed path, with unknown figures left unknown rather than treated as zero.
public struct StorageCleanupState: Sendable, Equatable {
    public var exists = false
    public var identity: StorageFileIdentity?
    public var allocated: UInt64?
    public var logical: UInt64?
    public var modified: Date?
    public var readable = false
    public var owned = false
    public var isFolder = false
    public var itemCount: Int?
    public var local = false
    public var readOnly = false
    public var placeholder = false
    public var symbolicLink = false
    public var mountPoint = false
    public var containsMount = false
    public var resolvedPath = ""
    public var volumePath: String?
    public var error: String?

    public init() {}
}

public struct StorageCleanupItem: Sendable, Identifiable {
    public var id: String { pick.path }
    public let pick: StorageCleanupPick
    public let state: StorageCleanupState
    public let includedPicks: Int
    public let refusal: String?
    public let warnings: [String]

    public var preselected: Bool { refusal == nil && warnings.isEmpty }
    public var includesText: String? {
        guard includedPicks > 0 else { return nil }
        return "Includes \(includedPicks) picked \(includedPicks == 1 ? "item" : "items") inside it"
    }

    public init(pick: StorageCleanupPick, state: StorageCleanupState, includedPicks: Int = 0, home: String) {
        self.pick = pick
        self.state = state
        self.includedPicks = includedPicks
        refusal = StorageCleanupRules.refusal(path: pick.path, state: state, home: home)
        warnings = StorageCleanupRules.warnings(pick: pick, state: state, home: home)
    }
}

public enum StorageCleanupRules {
    public static let standardFolders = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"]

    public static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// These folders are never offered, including a parent that would move them along with it.
    public static func refusal(path: String, state: StorageCleanupState, home: String) -> String? {
        let paths = [path, state.resolvedPath].filter { !$0.isEmpty }
        let roots = [home] + standardFolders.map { home + "/" + $0 }
        if paths.contains(where: { candidate in roots.contains { contains(candidate, $0) } }) {
            return "The home folder and its standard folders must stay in place."
        }
        if state.mountPoint || state.containsMount { return "A volume mount point must stay in place." }
        if state.symbolicLink { return "Symbolic links aren't offered for cleanup." }
        if state.readOnly { return "This volume is read-only." }
        if !state.exists { return "This item is missing or couldn't be accessed." }
        if state.identity == nil { return "The file's identity couldn't be verified." }
        return nil
    }

    public static func protectedLocation(_ path: String, home: String) -> Bool {
        if ["/System", "/usr", "/bin", "/sbin"].contains(where: { contains($0, path) }) { return true }
        if contains("/Library", path), !contains(home, path) { return true }
        if ["Library/Containers", "Library/Group Containers"].contains(where: { contains(home + "/" + $0, path) }) { return true }
        let components = path.split(separator: "/")
        return components.dropLast().contains { $0.lowercased().hasSuffix(".app") }
    }

    public static func changed(_ pick: StorageCleanupPick, _ state: StorageCleanupState) -> Bool {
        guard let identity = pick.identity, let modified = pick.modified, let nowModified = state.modified else { return true }
        return identity != state.identity || pick.allocated != state.allocated || pick.logical != state.logical
            || modified != nowModified || nowModified > pick.scannedAt || pick.isFolder != state.isFolder
    }

    public static func warnings(pick: StorageCleanupPick, state: StorageCleanupState, home: String) -> [String] {
        var warnings: [String] = []
        if changed(pick, state) { warnings.append("Changed since the scan, or its scan identity couldn't be verified.") }
        if !state.owned { warnings.append("Not owned by you.") }
        if !state.readable { warnings.append("Couldn't read this item.") }
        if !state.local { warnings.append("Not on a verified local volume.") }
        if state.placeholder { warnings.append("An iCloud Drive placeholder; its contents haven't been downloaded.") }
        if protectedLocation(pick.path, home: home) || protectedLocation(state.resolvedPath, home: home) {
            warnings.append("Inside a protected or system location.")
        }
        if state.allocated == nil { warnings.append("Current contents couldn't be measured completely.") }
        if let error = state.error { warnings.append(error) }
        return warnings
    }

    /// A folder represents all picked descendants, so the review never offers to move a path twice.
    public static func collapse(_ picks: [StorageCleanupPick]) -> [Collapsed] {
        let unique = Dictionary(picks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { $0.path < $1.path }
        let kept = unique.filter { pick in
            !unique.contains { $0.path != pick.path && $0.isFolder && contains($0.path, pick.path) }
        }
        return kept.map { pick in
            Collapsed(pick: pick, included: unique.filter { $0.path != pick.path && contains(pick.path, $0.path) }.count)
        }
    }

    public struct Collapsed: Sendable {
        public let pick: StorageCleanupPick
        public let included: Int
    }

    public struct Selection: Sendable, Equatable {
        public let paths: Set<String>
        public let anchor: String?

        public init(paths: Set<String> = [], anchor: String? = nil) {
            self.paths = paths
            self.anchor = anchor
        }
    }

    /// A range follows the scan's list order, while a Cmd-click keeps other picks, including treemap picks.
    public static func select(_ path: String, order: [String], current: Selection, command: Bool, shift: Bool) -> Selection {
        let selected = current.paths
        let anchor = current.anchor
        guard order.contains(path) else { return Selection(paths: selected, anchor: anchor) }
        if shift, let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: path) {
            let range = Set(order[min(start, end)...max(start, end)])
            return Selection(paths: command ? selected.union(range) : range, anchor: anchor)
        }
        var paths = selected
        if command {
            if !paths.insert(path).inserted { paths.remove(path) }
        } else {
            paths = [path]
        }
        return Selection(paths: paths, anchor: path)
    }

    /// A change after the review needs a new review, even when the earlier scan already warned about it.
    public static func revalidationFailure(_ item: StorageCleanupItem, now: StorageCleanupState, home: String) -> String? {
        if let refusal = refusal(path: item.id, state: now, home: home) { return refusal }
        if now != item.state { return "Changed after the review. Rescan and review it again." }
        return nil
    }
}

public enum StorageCleanupText {
    public static func selected(_ items: [StorageCleanupItem], selection: Set<String>) -> String {
        let picked = items.filter { selection.contains($0.id) && $0.refusal == nil }
        var seen = Set<StorageFileIdentity>()
        let bytes = picked.reduce(UInt64(0)) { total, item in
            if let identity = item.state.identity, !seen.insert(identity).inserted { return total }
            return total + (item.state.allocated ?? 0)
        }
        let qualifier = picked.contains { $0.state.allocated == nil } ? "at least " : ""
        return "Selected: \(qualifier)\(Format.bytes(bytes)) allocated · space you get back may be less "
            + "(clones, hard links and snapshots can keep blocks)"
    }

    /// Figures that still match the scan read once; a change keeps the scan's beside today's.
    public static func sizes(_ item: StorageCleanupItem) -> [String] {
        let pick = item.pick
        let state = item.state
        if state.allocated == pick.allocated, state.logical == pick.logical {
            return ["\(Format.bytes(pick.allocated)) allocated · \(Format.bytes(pick.logical)) file size · as at the scan"]
        }
        func now(_ bytes: UInt64?) -> String { bytes.map(Format.bytes) ?? "not measured" }
        return ["At scan: \(Format.bytes(pick.allocated)) allocated · Now: \(now(state.allocated))",
                "File size at scan: \(Format.bytes(pick.logical)) · Now: \(now(state.logical))"]
    }

    public static func capacityChange(before: Int64?, after: Int64?) -> String {
        guard let before, let after else { return "Volume available space change couldn't be measured." }
        let change = after - before
        let sign = change < 0 ? "−" : "+"
        return "Volume available space changed by \(sign)\(Format.bytes(UInt64(change.magnitude)))"
    }
}
