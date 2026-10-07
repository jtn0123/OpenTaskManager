import Foundation

/// What kind of thing takes up the space, for the Storage page's colours and
/// category totals.
public enum DiskCategory: Int, CaseIterable, Sendable, Codable, Identifiable, Comparable {
    case apps
    case developer
    case media
    case audio
    case documents
    case archives
    case caches
    case system
    case other

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .apps: "Apps"
        case .developer: "Developer"
        case .media: "Photos & Video"
        case .audio: "Music & Audio"
        case .documents: "Documents"
        case .archives: "Archives & Disk Images"
        case .caches: "Caches & Logs"
        case .system: "System & Library"
        case .other: "Other"
        }
    }

    public static func < (lhs: DiskCategory, rhs: DiskCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum DiskItemKind: String, Sendable, Codable {
    case folder
    /// A bundle Finder shows as one item (an app, a Photos library). Its
    /// contents count towards the totals but aren't listed.
    case package
    case file
    /// The children of a folder too small to list one by one, added up.
    case smallerItems
}

/// One row of a scan: a folder, package or file, or the "smaller items" rest
/// of a folder with more children than the scan keeps.
public struct DiskItem: Sendable, Codable, Hashable, Identifiable {
    /// Index in `DiskUsage.items`. The scanned folder itself is 0.
    public let id: Int
    public let parent: Int?
    /// Empty for the scanned folder and for `smallerItems`.
    public let name: String
    public let kind: DiskItemKind
    /// Space on disk: whole blocks, counting each hard-linked file once.
    public let allocatedSize: UInt64
    /// The files' own lengths, as Finder's "size" shows them.
    public let logicalSize: UInt64
    /// Files and folders inside, at any depth (zero for a file). For
    /// `smallerItems`, how many children it stands for.
    public let itemCount: Int
    /// For a folder, the category holding most of its bytes.
    public let category: DiskCategory
    public let modified: Date?
    /// Where the children sit in `DiskUsage.items`, largest first. A folder
    /// with more children than the scan keeps ends with a `smallerItems` row.
    public let children: Range<Int>
    /// A folder below the scan's detail threshold: its totals are exact, but
    /// its contents weren't kept, to bound memory on a large disk.
    public let contentsOmitted: Bool
    /// A folder the scan couldn't open, usually for want of Full Disk Access.
    public let isUnreadable: Bool

    public init(id: Int, parent: Int?, name: String, kind: DiskItemKind, allocatedSize: UInt64, logicalSize: UInt64,
                itemCount: Int, category: DiskCategory, modified: Date?, children: Range<Int>,
                contentsOmitted: Bool = false, isUnreadable: Bool = false) {
        self.id = id
        self.parent = parent
        self.name = name
        self.kind = kind
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.itemCount = itemCount
        self.category = category
        self.modified = modified
        self.children = children
        self.contentsOmitted = contentsOmitted
        self.isUnreadable = isUnreadable
    }

    /// Something that can be opened to show what's inside.
    public var isFolder: Bool { kind == .folder }
}

/// A file (or package) in the scan's list of the biggest.
public struct DiskFile: Sendable, Codable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let isPackage: Bool
    public let allocatedSize: UInt64
    public let logicalSize: UInt64
    public let category: DiskCategory
    public let modified: Date?

    public init(path: String, isPackage: Bool, allocatedSize: UInt64, logicalSize: UInt64, category: DiskCategory, modified: Date?) {
        self.path = path
        self.isPackage = isPackage
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.category = category
        self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
}

public struct DiskCategoryTotal: Sendable, Codable, Hashable, Identifiable {
    public var id: DiskCategory { category }
    public let category: DiskCategory
    public let allocatedSize: UInt64

    public init(category: DiskCategory, allocatedSize: UInt64) {
        self.category = category
        self.allocatedSize = allocatedSize
    }
}

/// The result of scanning a folder or volume: a tree of folders with their
/// totals (each keeping only its largest children), the largest files
/// anywhere, and the space by category.
public struct DiskUsage: Sendable, Codable {
    public let rootPath: String
    /// Breadth first, so each item's children are contiguous. `items[0]` is
    /// the scanned folder.
    public let items: [DiskItem]
    /// Largest first.
    public let largestFiles: [DiskFile]
    /// Every category, largest first.
    public let categories: [DiskCategoryTotal]
    public let fileCount: Int
    public let folderCount: Int
    /// Folders the scan couldn't open; their contents aren't counted.
    public let unreadableFolders: Int
    /// The first few of them, for the explanation.
    public let unreadableExamples: [String]
    /// Extra names for files already counted (hard links), counted once.
    public let hardLinkDuplicates: Int
    /// Other volumes mounted inside the scanned folder, which the scan doesn't enter.
    public let skippedVolumes: [String]
    /// Folders smaller than this keep their totals but not their contents.
    public let detailThreshold: UInt64
    public let duration: TimeInterval
    public let finishedAt: Date

    public init(rootPath: String, items: [DiskItem], largestFiles: [DiskFile], categories: [DiskCategoryTotal],
                fileCount: Int, folderCount: Int, unreadableFolders: Int, unreadableExamples: [String],
                hardLinkDuplicates: Int, skippedVolumes: [String], detailThreshold: UInt64,
                duration: TimeInterval, finishedAt: Date) {
        self.rootPath = rootPath
        self.items = items
        self.largestFiles = largestFiles
        self.categories = categories
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.unreadableFolders = unreadableFolders
        self.unreadableExamples = unreadableExamples
        self.hardLinkDuplicates = hardLinkDuplicates
        self.skippedVolumes = skippedVolumes
        self.detailThreshold = detailThreshold
        self.duration = duration
        self.finishedAt = finishedAt
    }

    public var root: DiskItem { items[0] }

    public func children(of item: DiskItem) -> ArraySlice<DiskItem> {
        items[item.children]
    }

    /// The scanned folder, then each folder down to `id`.
    public func ancestry(of id: Int) -> [DiskItem] {
        var chain: [DiskItem] = []
        var next: Int? = items.indices.contains(id) ? id : nil
        while let index = next {
            chain.append(items[index])
            next = items[index].parent
        }
        return chain.reversed()
    }

    /// Full path of an item. The "smaller items" row has its folder's path.
    public func path(of id: Int) -> String {
        let names = ancestry(of: id).dropFirst().map(\.name).filter { !$0.isEmpty }
        guard !names.isEmpty else { return rootPath }
        return names.reduce(rootPath) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// The item at a path below the scanned folder ("Library/Caches"), if
    /// the scan kept it. An absolute path inside the scan works too.
    public func item(atPath path: String) -> DiskItem? {
        var relative = path
        if relative.hasPrefix(rootPath) {
            relative = String(relative.dropFirst(rootPath.count))
        }
        var current = root
        for name in relative.split(separator: "/") where !name.isEmpty {
            guard let next = children(of: current).first(where: { $0.name == name }) else { return nil }
            current = next
        }
        return current
    }

    /// The deepest kept folder holding `path`, for jumping from a large file
    /// to its place in the tree.
    public func closestFolder(to path: String) -> DiskItem {
        guard path.hasPrefix(rootPath) else { return root }
        var current = root
        for name in path.dropFirst(rootPath.count).split(separator: "/") {
            guard let next = children(of: current).first(where: { $0.name == name && $0.isFolder }) else { break }
            current = next
        }
        return current
    }
}

/// Live figures while a scan runs.
public struct DiskScanProgress: Sendable, Equatable {
    public let itemCount: Int
    public let allocatedSize: UInt64
    public let currentFolder: String
    public let elapsed: TimeInterval
    public let unreadableFolders: Int

    public init(itemCount: Int, allocatedSize: UInt64, currentFolder: String, elapsed: TimeInterval, unreadableFolders: Int) {
        self.itemCount = itemCount
        self.allocatedSize = allocatedSize
        self.currentFolder = currentFolder
        self.elapsed = elapsed
        self.unreadableFolders = unreadableFolders
    }
}
