import Foundation

/// What a saved scan says about one path's size: exactly, at most some
/// amount (it was too small to keep), or not at all (it couldn't be read).
public struct DiskSizeEstimate: Sendable, Equatable {
    /// The least it can be.
    public let low: UInt64
    /// The most it can be; `UInt64.max` when there's no telling.
    public let high: UInt64
    /// For a folder the summary lists: folders inside it the scan couldn't read.
    public let unreadableCount: Int?

    public init(low: UInt64, high: UInt64, unreadableCount: Int? = nil) {
        self.low = low
        self.high = max(low, high)
        self.unreadableCount = unreadableCount
    }

    public static func exact(_ size: UInt64, unreadableCount: Int? = nil) -> DiskSizeEstimate {
        DiskSizeEstimate(low: size, high: size, unreadableCount: unreadableCount)
    }

    /// Left out of a summary that kept everything bigger than `limit`.
    public static func atMost(_ limit: UInt64) -> DiskSizeEstimate {
        DiskSizeEstimate(low: 0, high: limit)
    }

    /// Not there, or empty.
    public static let absent = exact(0)
    /// Inside a folder that couldn't be read.
    public static let unknown = DiskSizeEstimate(low: 0, high: .max)

    public var isExact: Bool { low == high }
    public var isBounded: Bool { high != .max }

    /// The same figure as a floor: part of it couldn't be read, so the
    /// real size could be anything above it.
    var orMore: DiskSizeEstimate {
        DiskSizeEstimate(low: low, high: .max, unreadableCount: unreadableCount)
    }
}

/// How one folder, package or file changed between two scans. Only what
/// the two summaries prove counts as growth or shrinkage: a folder that
/// couldn't be read in the later scan never looks like space freed.
public struct DiskSizeChange: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case folder
        case package
        case file
    }

    public enum Direction: Sendable, Equatable {
        case grew
        case shrank
        case same
        /// The summaries can't tell: it was too small to keep in one of
        /// them, or couldn't be read in one.
        case unclear
    }

    /// Below the scanned folder; "" for the scanned folder itself.
    public let path: String
    public let kind: Kind
    public let before: DiskSizeEstimate
    public let after: DiskSizeEstimate
    /// One of the scans couldn't read a folder here that the other could.
    public let readabilityChanged: Bool
    /// The earlier summary lists it (rather than bounding it).
    public let wasListed: Bool
    /// The later summary lists it.
    public let isListed: Bool

    public init(path: String, kind: Kind, before: DiskSizeEstimate, after: DiskSizeEstimate, readabilityChanged: Bool = false,
                wasListed: Bool = true, isListed: Bool = true) {
        self.path = path
        self.kind = kind
        self.before = before
        self.after = after
        self.readabilityChanged = readabilityChanged
        self.wasListed = wasListed
        self.isListed = isListed
    }

    public var id: String { "\(kind):\(path)" }
    public var name: String { (path as NSString).lastPathComponent }
    /// The folder holding it, below the scanned folder.
    public var parentPath: String { (path as NSString).deletingLastPathComponent }

    /// Space it certainly gained: the least it holds now, less the most it held before.
    public var growth: UInt64 { after.low > before.high ? after.low - before.high : 0 }
    /// Space it certainly lost.
    public var shrinkage: UInt64 { before.low > after.high ? before.low - after.high : 0 }
    /// Both sizes are known exactly.
    public var isExact: Bool { before.isExact && after.isExact }
    /// The measured difference, with whatever a summary left out taken as
    /// zero. Only meaningful as it stands when `isExact`.
    public var measuredDelta: Int64 {
        Int64(clamping: after.low) - Int64(clamping: before.low)
    }

    /// Wasn't there (or was empty) and now holds something.
    public var isNew: Bool { before.high == 0 && after.low > 0 }
    /// Held something and is gone (or empty) now.
    public var isGone: Bool { after.high == 0 && before.low > 0 }

    /// Which way it went, counting a change of `threshold` or less as none.
    public func direction(ignoringUnder threshold: UInt64 = 0) -> Direction {
        if growth > threshold { return .grew }
        if shrinkage > threshold { return .shrank }
        // The most it could have moved either way.
        let rise = after.high > before.low ? after.high - before.low : 0
        let fall = before.high > after.low ? before.high - after.low : 0
        return max(rise, fall) <= threshold ? .same : .unclear
    }
}

/// What changed in one folder between two scans, for the Changes list.
public struct DiskScanReport: Sendable {
    /// The folder covered, below the scanned folder.
    public let path: String
    public let total: DiskSizeChange
    /// Folders and packages that grew most, each one whose growth isn't
    /// mostly one folder inside it.
    public let grew: [DiskSizeChange]
    public let shrank: [DiskSizeChange]
    /// Files (and packages) new among the largest.
    public let filesAdded: [DiskSizeChange]
    /// Files (and packages) gone from the largest.
    public let filesRemoved: [DiskSizeChange]
    /// Folders only one of the scans could read.
    public let becameUnreadable: [DiskSizeChange]
    public let becameReadable: [DiskSizeChange]

    public var isEmpty: Bool {
        grew.isEmpty && shrank.isEmpty && filesAdded.isEmpty && filesRemoved.isEmpty && becameUnreadable.isEmpty && becameReadable.isEmpty
    }

    /// The change to show first: the most space certainly gained or lost,
    /// the list's order breaking ties (so a folder beats the file that
    /// explains it). Nil when nothing grew or shrank.
    public var largest: DiskSizeChange? {
        (grew + shrank + filesAdded + filesRemoved).max { max($0.growth, $0.shrinkage) < max($1.growth, $1.shrinkage) }
    }

    /// Whether `id` (a `DiskSizeChange.id`) is one of the changes listed.
    public func lists(_ id: String) -> Bool {
        [grew, shrank, filesAdded, filesRemoved, becameUnreadable, becameReadable].contains { $0.contains { $0.id == id } }
    }
}

/// Two saved scans of the same scope, compared.
///
/// Sizes a summary left out count as "at most" the limit it noted, and
/// anything inside a folder that couldn't be read as unknown, so every
/// growth or shrinkage reported is certain. Paths are below the scanned
/// folder.
public struct DiskScanComparison: Sendable {
    /// A folder whose growth comes this much from one folder inside it is
    /// left out of the report in favour of that folder.
    static let explainedShare = 0.9

    /// Changes this small are noise in a folder of `size`: 64 KB, or a
    /// ten-thousandth of the folder, so a big disk isn't all lit up by
    /// caches ticking over.
    public static func noiseFloor(for size: UInt64) -> UInt64 {
        max(64 * 1024, size / 10_000)
    }

    public let earlier: DiskScanSummary
    public let later: DiskScanSummary
    /// Every folder and package either summary lists, but the scanned folder.
    public let folders: [DiskSizeChange]
    /// Every file and package either summary lists among the largest.
    public let files: [DiskSizeChange]
    public let total: DiskSizeChange

    private let before: SummaryIndex
    private let after: SummaryIndex
    /// The folders the report ranks: a package that came or went among
    /// the largest files shows there instead, not twice.
    private let ranked: [DiskSizeChange]
    /// The most growth and shrinkage of a ranked folder inside each folder.
    private let childGrowth: [String: UInt64]
    private let childShrinkage: [String: UInt64]

    public init(earlier: DiskScanSummary, later: DiskScanSummary) {
        self.earlier = earlier
        self.later = later
        let before = SummaryIndex(earlier)
        let after = SummaryIndex(later)
        self.before = before
        self.after = after

        var folders: [DiskSizeChange] = []
        var seen = Set<String>()
        for (index, path) in after.paths.enumerated() where !path.isEmpty && seen.insert(path).inserted {
            folders.append(Self.change(path: path, kind: later.folders[index].isPackage ? .package : .folder, before: before, after: after))
        }
        for (index, path) in before.paths.enumerated() where !path.isEmpty && seen.insert(path).inserted {
            folders.append(Self.change(path: path, kind: earlier.folders[index].isPackage ? .package : .folder, before: before, after: after))
        }
        var files: [DiskSizeChange] = []
        var seenFiles = Set<String>()
        for file in later.largestFiles + earlier.largestFiles where seenFiles.insert(file.path).inserted {
            files.append(Self.change(path: file.path, kind: file.isPackage ? .package : .file, before: before, after: after))
        }
        self.folders = folders
        self.files = files
        total = Self.change(path: "", kind: .folder, before: before, after: after)

        let filePaths = Set(files.map(\.path))
        let ranked = folders.filter { $0.kind == .folder || !($0.isNew || $0.isGone) || !filePaths.contains($0.path) }
        self.ranked = ranked
        var childGrowth: [String: UInt64] = [:]
        var childShrinkage: [String: UInt64] = [:]
        for change in ranked {
            childGrowth[change.parentPath, default: 0] = max(childGrowth[change.parentPath] ?? 0, change.growth)
            childShrinkage[change.parentPath, default: 0] = max(childShrinkage[change.parentPath] ?? 0, change.shrinkage)
        }
        self.childGrowth = childGrowth
        self.childShrinkage = childShrinkage
    }

    /// How a folder or package (`isPackage`) at `path` changed, given its
    /// size now. For the treemap, whose items the later summary may be too
    /// small to list.
    public func change(ofFolder path: String, isPackage: Bool = false, now: DiskSizeEstimate) -> DiskSizeChange {
        Self.change(path: path, kind: isPackage ? .package : .folder, before: before, after: after, now: now)
    }

    /// How a file at `path` changed, given its size now.
    public func change(ofFile path: String, now: UInt64) -> DiskSizeChange {
        Self.change(path: path, kind: .file, before: before, after: after, now: .exact(now))
    }

    /// The changes inside the folder at `path` ("" for everything), up to
    /// `limit` of each kind, leaving out any of `threshold` or less.
    public func report(under path: String = "", limit: Int = 8, ignoringUnder threshold: UInt64 = 0) -> DiskScanReport {
        let prefix = path.isEmpty ? "" : path + "/"
        func inside(_ change: DiskSizeChange) -> Bool { change.path.hasPrefix(prefix) }
        let listed = ranked.filter(inside)
        let scopedFiles = files.filter(inside)
        let grew = listed
            .filter { $0.growth > threshold && Double(childGrowth[$0.path] ?? 0) < Self.explainedShare * Double($0.growth) }
            .sorted { ($0.growth, $1.path) > ($1.growth, $0.path) }
        let shrank = listed
            .filter { $0.shrinkage > threshold && Double(childShrinkage[$0.path] ?? 0) < Self.explainedShare * Double($0.shrinkage) }
            .sorted { ($0.shrinkage, $1.path) > ($1.shrinkage, $0.path) }
        let added = scopedFiles.filter { !$0.wasListed && $0.growth > threshold }.sorted { ($0.growth, $1.path) > ($1.growth, $0.path) }
        let removed = scopedFiles.filter { !$0.isListed && $0.shrinkage > threshold }
            .sorted { ($0.shrinkage, $1.path) > ($1.shrinkage, $0.path) }

        let wasUnreadable = Set(earlier.unreadablePaths)
        let isUnreadable = Set(later.unreadablePaths)
        func readability(_ paths: [String], excluding other: Set<String>) -> [DiskSizeChange] {
            paths.filter { $0.hasPrefix(prefix) && !other.contains($0) }.prefix(limit).map {
                Self.change(path: $0, kind: .folder, before: before, after: after)
            }
        }
        return DiskScanReport(
            path: path,
            total: Self.change(path: path, kind: .folder, before: before, after: after),
            grew: Array(grew.prefix(limit)), shrank: Array(shrank.prefix(limit)),
            filesAdded: Array(added.prefix(limit)), filesRemoved: Array(removed.prefix(limit)),
            becameUnreadable: readability(later.unreadablePaths, excluding: wasUnreadable),
            becameReadable: readability(earlier.unreadablePaths, excluding: isUnreadable)
        )
    }

    // MARK: - Estimates

    private static func change(path: String, kind: DiskSizeChange.Kind, before: SummaryIndex, after: SummaryIndex,
                               now: DiskSizeEstimate? = nil) -> DiskSizeChange {
        var old = kind == .file ? before.fileEstimate(path) : before.folderEstimate(path)
        var new = now ?? (kind == .file ? after.fileEstimate(path) : after.folderEstimate(path))
        // A folder unreadable in only one scan undercounts that scan.
        let (earlierHidesMore, laterHidesMore) = readabilityShift(path, old: old, new: new, before: before, after: after)
        if earlierHidesMore { old = old.orMore }
        if laterHidesMore { new = new.orMore }
        return DiskSizeChange(path: path, kind: kind, before: old, after: new, readabilityChanged: earlierHidesMore || laterHidesMore,
                              wasListed: before.lists(path, kind: kind), isListed: now != nil || after.lists(path, kind: kind))
    }

    /// Whether each scan had folders here it couldn't read that the other could.
    private static func readabilityShift(_ path: String, old: DiskSizeEstimate, new: DiskSizeEstimate,
                                         before: SummaryIndex, after: SummaryIndex) -> (Bool, Bool) {
        if before.listsEveryUnreadable, after.listsEveryUnreadable {
            let earlier = before.unreadable(under: path)
            let later = after.unreadable(under: path)
            return (!earlier.isSubset(of: later), !later.isSubset(of: earlier))
        }
        guard let earlier = old.unreadableCount, let later = new.unreadableCount else { return (false, false) }
        return (earlier > later, later > earlier)
    }
}

/// A summary's folders and files by path, for looking sizes up.
private struct SummaryIndex: Sendable {
    let summary: DiskScanSummary
    let paths: [String]
    let folderIndex: [String: Int]
    let files: [String: DiskScanSummary.File]
    /// Unreadable folders by every folder holding them (and by themselves).
    let unreadableByFolder: [String: Set<String>]
    let listsEveryUnreadable: Bool

    init(_ summary: DiskScanSummary) {
        self.summary = summary
        paths = summary.folderPaths()
        folderIndex = Dictionary(paths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        files = Dictionary(summary.largestFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var byFolder: [String: Set<String>] = [:]
        for path in summary.unreadablePaths {
            var folder = path
            while true {
                byFolder[folder, default: []].insert(path)
                if folder.isEmpty { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        unreadableByFolder = byFolder
        listsEveryUnreadable = summary.unreadablePaths.count >= summary.unreadableFolders
    }

    func unreadable(under path: String) -> Set<String> {
        unreadableByFolder[path] ?? []
    }

    func lists(_ path: String, kind: DiskSizeChange.Kind) -> Bool {
        switch kind {
        case .folder: folderIndex[path] != nil
        case .package: folderIndex[path] != nil || files[path] != nil
        case .file: files[path] != nil
        }
    }

    /// For a folder or package.
    func folderEstimate(_ path: String) -> DiskSizeEstimate {
        if let index = folderIndex[path] {
            let folder = summary.folders[index]
            // Its own size says nothing when it couldn't even be opened.
            if folder.isUnreadable { return DiskSizeEstimate(low: folder.allocatedSize, high: .max, unreadableCount: folder.unreadableCount) }
            return .exact(folder.allocatedSize, unreadableCount: folder.unreadableCount)
        }
        // A package too small for the folders can still be among the largest files.
        if let file = files[path], file.isPackage { return .exact(file.allocatedSize) }
        return bound(path) { $0.unlistedLimit }
    }

    func fileEstimate(_ path: String) -> DiskSizeEstimate {
        if let file = files[path] { return .exact(file.allocatedSize) }
        // Left off the list, it was no bigger than the smallest file on it
        // (a package's files are never listed one by one), ...
        let listed = bound(path) { _ in summary.largestFilesCutoff }
        guard listed.isBounded else { return listed }
        // ... nor than the biggest file its folder had off the list, or if
        // the folder isn't listed, than the folder: nothing at all if it
        // wasn't there.
        let parent = (path as NSString).deletingLastPathComponent
        if let index = folderIndex[parent] { return .atMost(min(listed.high, summary.folders[index].fileLimit)) }
        return .atMost(min(listed.high, folderEstimate(parent).high))
    }

    /// The most something the summary leaves out could hold, from the
    /// nearest folder it lists around `path`.
    private func bound(_ path: String, limit: (DiskScanSummary.Folder) -> UInt64) -> DiskSizeEstimate {
        var folder = path
        while !folder.isEmpty {
            folder = (folder as NSString).deletingLastPathComponent
            guard let index = folderIndex[folder] else { continue }
            let holder = summary.folders[index]
            if holder.isUnreadable || isInsideUnreadable(path) { return .unknown }
            // An unreadable folder in here that isn't on the list could hold it.
            if holder.unreadableCount > unreadable(under: folder).count { return .unknown }
            if holder.isPackage { return .atMost(holder.allocatedSize) }
            return .atMost(limit(holder))
        }
        return .unknown
    }

    private func isInsideUnreadable(_ path: String) -> Bool {
        var folder = path
        while !folder.isEmpty {
            if unreadableByFolder[folder]?.contains(folder) == true { return true }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }
}
