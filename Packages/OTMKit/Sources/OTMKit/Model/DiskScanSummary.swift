import Foundation

/// What a scan covered: the folder, plus the other volumes it entered and
/// the folders it skipped. Only scans of the same scope are compared, since
/// a different scope would make skipped space look like a change.
public struct DiskScanScope: Sendable, Codable, Hashable {
    public let rootPath: String
    public let alsoEnters: [String]
    public let excludedPaths: [String]

    public init(rootPath: String, alsoEnters: [String] = [], excludedPaths: [String] = []) {
        self.rootPath = rootPath
        self.alsoEnters = alsoEnters.sorted()
        self.excludedPaths = excludedPaths.sorted()
    }

    /// The scope of a scan made from `request`. `rootPath` is the scan's
    /// own, which has symbolic links resolved.
    public init(_ usage: DiskUsage, request: DiskScanRequest) {
        self.init(rootPath: usage.rootPath, alsoEnters: request.alsoEnters.map(\.path), excludedPaths: Array(request.excludedPaths))
    }

    /// A file name for this scope's saved scans: the folder's name, then a
    /// hash of the whole scope so two folders of the same name never mix.
    public var key: String {
        let signature = ([rootPath] + alsoEnters.map { "+" + $0 } + excludedPaths.map { "-" + $0 }).joined(separator: "\n")
        // FNV-1a: stable from run to run, unlike `Hasher`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in signature.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let name = (rootPath as NSString).lastPathComponent
        let safe = String(name.unicodeScalars.prefix(40).map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
        let hex = String(hash, radix: 16)
        return (safe.isEmpty || rootPath == "/" ? "root" : safe) + "-" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// `path` below the root ("Library/Caches"), "" for the root itself, or
    /// nil if it isn't inside.
    public func relativePath(_ path: String) -> String? {
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}

/// A compact record of a finished scan, saved so a later scan of the same
/// scope can be compared with it.
///
/// It keeps the totals, the largest folders (a connected tree, since no
/// folder is bigger than the one holding it), the largest files and the
/// folders the scan couldn't read. Each folder also notes how big anything
/// left out of it could be, so a comparison can tell a folder that's gone
/// from one that was too small to keep.
public struct DiskScanSummary: Sendable, Codable, Equatable {
    /// The format this build writes. Files from a newer one aren't read.
    public static let currentVersion = 1
    /// Most folders kept, the scanned folder included.
    public static let folderLimit = 1_500

    public struct Folder: Sendable, Codable, Equatable {
        /// Empty for the scanned folder.
        public let name: String
        /// Index of the folder holding it, always lower than its own; -1 for the scanned folder.
        public let parent: Int
        /// A bundle kept as one item, with nothing listed inside.
        public let isPackage: Bool
        public let allocatedSize: UInt64
        public let logicalSize: UInt64
        public let itemCount: Int
        /// The scan couldn't open it.
        public let isUnreadable: Bool
        /// Folders the scan couldn't open, this one or any inside it.
        public let unreadableCount: Int
        /// The most a folder inside it that isn't listed here could hold:
        /// zero when every folder inside with any space is listed.
        public let unlistedLimit: UInt64
        /// The most a file right inside it that isn't among the largest
        /// files could hold: zero when every file in it is on that list.
        public let fileLimit: UInt64

        public init(name: String, parent: Int, isPackage: Bool = false, allocatedSize: UInt64, logicalSize: UInt64,
                    itemCount: Int, isUnreadable: Bool = false, unreadableCount: Int = 0, unlistedLimit: UInt64 = 0,
                    fileLimit: UInt64? = nil) {
            self.name = name
            self.parent = parent
            self.isPackage = isPackage
            self.allocatedSize = allocatedSize
            self.logicalSize = logicalSize
            self.itemCount = itemCount
            self.isUnreadable = isUnreadable
            self.unreadableCount = unreadableCount
            self.unlistedLimit = unlistedLimit
            // Unless told, any file in it could be missing from the list.
            self.fileLimit = fileLimit ?? allocatedSize
        }

        // Short keys, and defaults left out: a summary holds up to 1,500 of these.
        private enum CodingKeys: String, CodingKey {
            case name = "n", parent = "p", isPackage = "pk", allocatedSize = "a", logicalSize = "l", itemCount = "i"
            case isUnreadable = "x", unreadableCount = "u", unlistedLimit = "m", fileLimit = "f"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            parent = try container.decode(Int.self, forKey: .parent)
            isPackage = try container.decodeIfPresent(Bool.self, forKey: .isPackage) ?? false
            allocatedSize = try container.decode(UInt64.self, forKey: .allocatedSize)
            logicalSize = try container.decode(UInt64.self, forKey: .logicalSize)
            itemCount = try container.decode(Int.self, forKey: .itemCount)
            isUnreadable = try container.decodeIfPresent(Bool.self, forKey: .isUnreadable) ?? false
            unreadableCount = try container.decodeIfPresent(Int.self, forKey: .unreadableCount) ?? 0
            unlistedLimit = try container.decodeIfPresent(UInt64.self, forKey: .unlistedLimit) ?? 0
            fileLimit = try container.decodeIfPresent(UInt64.self, forKey: .fileLimit) ?? allocatedSize
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(parent, forKey: .parent)
            if isPackage { try container.encode(true, forKey: .isPackage) }
            try container.encode(allocatedSize, forKey: .allocatedSize)
            try container.encode(logicalSize, forKey: .logicalSize)
            try container.encode(itemCount, forKey: .itemCount)
            if isUnreadable { try container.encode(true, forKey: .isUnreadable) }
            if unreadableCount > 0 { try container.encode(unreadableCount, forKey: .unreadableCount) }
            if unlistedLimit > 0 { try container.encode(unlistedLimit, forKey: .unlistedLimit) }
            if fileLimit != allocatedSize { try container.encode(fileLimit, forKey: .fileLimit) }
        }
    }

    /// One of the largest files or packages.
    public struct File: Sendable, Codable, Equatable {
        /// Below the scanned folder.
        public let path: String
        public let isPackage: Bool
        public let allocatedSize: UInt64
        public let logicalSize: UInt64

        public init(path: String, isPackage: Bool = false, allocatedSize: UInt64, logicalSize: UInt64) {
            self.path = path
            self.isPackage = isPackage
            self.allocatedSize = allocatedSize
            self.logicalSize = logicalSize
        }
    }

    public let version: Int
    public let scope: DiskScanScope
    public let scannedAt: Date
    public let duration: TimeInterval
    public let fileCount: Int
    public let folderCount: Int
    public let hardLinkDuplicates: Int
    /// Every folder the scan couldn't open, counted.
    public let unreadableFolders: Int
    /// The first of them, below the scanned folder.
    public let unreadablePaths: [String]
    /// The scanned folder first; each folder after the one holding it.
    public let folders: [Folder]
    /// Largest first.
    public let largestFiles: [File]
    /// Files this size or smaller may be missing from `largestFiles`; zero
    /// when it lists every file.
    public let largestFilesCutoff: UInt64
    public let categories: [DiskCategoryTotal]

    public init(version: Int = currentVersion, scope: DiskScanScope, scannedAt: Date, duration: TimeInterval = 0,
                fileCount: Int = 0, folderCount: Int = 0, hardLinkDuplicates: Int = 0, unreadableFolders: Int = 0,
                unreadablePaths: [String] = [], folders: [Folder], largestFiles: [File] = [], largestFilesCutoff: UInt64 = 0,
                categories: [DiskCategoryTotal] = []) {
        self.version = version
        self.scope = scope
        self.scannedAt = scannedAt
        self.duration = duration
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.hardLinkDuplicates = hardLinkDuplicates
        self.unreadableFolders = unreadableFolders
        self.unreadablePaths = unreadablePaths
        self.folders = folders
        self.largestFiles = largestFiles
        self.largestFilesCutoff = largestFilesCutoff
        self.categories = categories
    }

    /// Sums up a scan, keeping its `folderLimit` largest folders.
    public init(_ usage: DiskUsage, scope: DiskScanScope, folderLimit: Int = folderLimit) {
        let items = usage.items
        // The largest folders and packages; on a tie the outer one first, so
        // every folder kept has the one holding it kept too.
        var depth = [Int](repeating: 0, count: items.count)
        for item in items.dropFirst() { depth[item.id] = depth[item.parent ?? 0] + 1 }
        let candidates = items.dropFirst()
            .filter { ($0.kind == .folder || $0.kind == .package) && $0.allocatedSize > 0 }
            .sorted { ($0.allocatedSize, depth[$1.id], $1.id) > ($1.allocatedSize, depth[$0.id], $0.id) }
            .prefix(max(folderLimit - 1, 0))
        var kept = Set(candidates.map(\.id))
        kept.insert(0)

        // Breadth-first order puts every folder after the one holding it.
        var index: [Int: Int] = [:]
        var folders: [Folder] = []
        folders.reserveCapacity(kept.count)
        let listedFiles = Set(usage.largestFiles.map(\.path))
        for item in items where kept.contains(item.id) {
            index[item.id] = folders.count
            folders.append(Folder(
                name: item.id == 0 ? "" : item.name, parent: item.parent.flatMap { index[$0] } ?? -1,
                isPackage: item.kind == .package, allocatedSize: item.allocatedSize, logicalSize: item.logicalSize,
                itemCount: item.itemCount, isUnreadable: item.isUnreadable, unreadableCount: item.unreadableCount,
                unlistedLimit: Self.unlistedLimit(of: item, in: usage, kept: kept),
                fileLimit: Self.fileLimit(of: item, in: usage, listed: listedFiles)
            ))
        }
        self.init(
            scope: scope, scannedAt: usage.finishedAt, duration: usage.duration, fileCount: usage.fileCount,
            folderCount: usage.folderCount, hardLinkDuplicates: usage.hardLinkDuplicates, unreadableFolders: usage.unreadableFolders,
            unreadablePaths: usage.unreadablePaths.compactMap(scope.relativePath), folders: folders,
            largestFiles: usage.largestFiles.compactMap { file in
                scope.relativePath(file.path).map {
                    File(path: $0, isPackage: file.isPackage, allocatedSize: file.allocatedSize, logicalSize: file.logicalSize)
                }
            },
            largestFilesCutoff: usage.largestFilesCutoff, categories: usage.categories
        )
    }

    /// How big a folder inside `item` that the summary leaves out could be.
    private static func unlistedLimit(of item: DiskItem, in usage: DiskUsage, kept: Set<Int>) -> UInt64 {
        guard item.kind == .folder else { return 0 }
        // The scan kept only the total: anything inside could be that big.
        if item.contentsOmitted || item.isUnreadable { return item.allocatedSize }
        let children = usage.children(of: item)
        var limit: UInt64 = 0
        for child in children {
            switch child.kind {
            case .folder, .package:
                if !kept.contains(child.id) { limit = max(limit, child.allocatedSize) }
            case .smallerItems:
                limit = max(limit, foldedLimit(child, among: children))
            case .file:
                break
            }
        }
        return limit
    }

    /// How big a file right inside `item` that isn't among the `listed`
    /// largest files could be.
    private static func fileLimit(of item: DiskItem, in usage: DiskUsage, listed: Set<String>) -> UInt64 {
        guard item.kind == .folder, !item.contentsOmitted, !item.isUnreadable else { return item.allocatedSize }
        let children = usage.children(of: item)
        let path = usage.path(of: item.id)
        var limit: UInt64 = 0
        for child in children {
            switch child.kind {
            case .file:
                if !listed.contains((path as NSString).appendingPathComponent(child.name)) { limit = max(limit, child.allocatedSize) }
            case .smallerItems:
                limit = max(limit, foldedLimit(child, among: children))
            case .folder, .package:
                break
            }
        }
        return limit
    }

    /// Each child folded into a "smaller items" row is no bigger than the
    /// smallest one listed, nor than the rest put together.
    private static func foldedLimit(_ row: DiskItem, among children: ArraySlice<DiskItem>) -> UInt64 {
        let smallestListed = children.filter { $0.kind != .smallerItems }.map(\.allocatedSize).min() ?? row.allocatedSize
        return min(row.allocatedSize, smallestListed)
    }

    public var root: Folder { folders[0] }
    public var allocatedSize: UInt64 { folders.first?.allocatedSize ?? 0 }
    public var logicalSize: UInt64 { folders.first?.logicalSize ?? 0 }

    /// Each folder's path below the scanned folder, by index.
    public func folderPaths() -> [String] {
        var paths: [String] = []
        paths.reserveCapacity(folders.count)
        for folder in folders {
            if folder.parent < 0 {
                paths.append("")
            } else {
                let parent = paths[folder.parent]
                paths.append(parent.isEmpty ? folder.name : parent + "/" + folder.name)
            }
        }
        return paths
    }

    /// Whether the folders hang together: the scanned folder first, every
    /// other one after the folder holding it. A file that isn't is corrupt.
    public var isWellFormed: Bool {
        guard let first = folders.first, first.parent == -1 else { return false }
        return folders.indices.dropFirst().allSatisfy { folders[$0].parent >= 0 && folders[$0].parent < $0 && !folders[$0].name.isEmpty }
    }
}
