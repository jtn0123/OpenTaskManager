import Foundation
import os

/// What to scan, and how much of it to keep.
public struct DiskScanRequest: Sendable {
    public var root: URL
    /// Other volumes the scan may enter. The startup disk keeps its data on a
    /// second volume that firmlinks join to `/` (`/Users`, `/Applications`).
    public var alsoEnters: [URL] = []
    /// Folders not to enter, by absolute path.
    public var excludedPaths: Set<String> = []
    /// Children kept per folder; the rest are added up in one "smaller items" row.
    public var childLimit = 200
    public var largestFileLimit = 50
    /// Most folders and files the result keeps. Past it, the smallest
    /// folders keep their totals but drop their contents, so memory stays
    /// bounded however many files the disk holds.
    public var nodeBudget = 200_000
    public var rules = DiskCategoryRules()
    /// How to classify the scanned folder's contents. Nil works it out from
    /// the folder's path, so scanning `~/Library/Caches` counts as caches.
    public var rootRegion: DiskRegion?

    public init(root: URL) {
        self.root = root
    }

    /// A whole volume. The startup volume (`/`) is the read-only system plus
    /// the Data volume behind its firmlinks; `/System/Volumes` holds the
    /// Data volume again (and swap, recovery and update volumes), so it's
    /// skipped to count everything once.
    public static func volume(mountPoint: String, isRoot: Bool) -> DiskScanRequest {
        var request = DiskScanRequest(root: URL(fileURLWithPath: mountPoint, isDirectory: true))
        if isRoot {
            request.alsoEnters = [URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)]
            request.excludedPaths = ["/System/Volumes"]
        }
        return request
    }
}

/// Adds up what's using the space under a folder.
///
/// It walks the tree once with `FileManager`'s enumerator and prefetched
/// resource values, never following symbolic links or entering other
/// volumes, and counts each hard-linked file once. Packages (apps, Photos
/// libraries) count towards the totals but are kept as one item. Each folder
/// keeps only its largest children and the scan keeps a fixed number of the
/// largest files, so memory stays bounded on a disk of millions of files.
public enum DiskUsageScanner {
    /// How often progress is reported.
    public static let progressInterval: TimeInterval = 0.25

    /// Scans on the calling thread. Returns nil if `isCancelled` turns true.
    public static func scan(_ request: DiskScanRequest, isCancelled: () -> Bool = { false },
                            progress: (DiskScanProgress) -> Void = { _ in }) -> DiskUsage? {
        DiskScan(request: request).run(isCancelled: isCancelled, progress: progress)
    }

    /// Scans on a thread of its own, so a long scan doesn't hold one of the
    /// concurrency pool's few threads. Cancelling the task stops it within a
    /// few hundred files and throws `CancellationError`.
    public static func scan(_ request: DiskScanRequest,
                            progress: @escaping @Sendable (DiskScanProgress) -> Void = { _ in }) async throws -> DiskUsage {
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DiskUsage, any Error>) in
                let thread = Thread {
                    if let usage = scan(request, isCancelled: { cancelled.withLock { $0 } }, progress: progress) {
                        continuation.resume(returning: usage)
                    } else {
                        continuation.resume(throwing: CancellationError())
                    }
                }
                thread.name = "OpenTaskManager disk scan"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}

/// Keeps the `limit` largest of whatever it's offered, as a min-heap.
struct LargestKept<Element> {
    let limit: Int
    private(set) var entries: [(key: UInt64, element: Element)] = []

    init(limit: Int) {
        self.limit = max(limit, 0)
    }

    var count: Int { entries.count }

    /// Whether an element this big would be kept.
    func accepts(_ key: UInt64) -> Bool {
        entries.count < limit || (limit > 0 && key > entries[0].key)
    }

    /// Offers an element. Returns whatever no longer fits: the smallest kept
    /// one it displaced, or the element itself if it's too small.
    mutating func insert(_ element: Element, key: UInt64) -> Element? {
        if entries.count < limit {
            entries.append((key, element))
            siftUp(entries.count - 1)
            return nil
        }
        guard limit > 0, key > entries[0].key else { return element }
        let evicted = entries[0].element
        entries[0] = (key, element)
        siftDown(0)
        return evicted
    }

    /// Largest first; equal keys in no particular order.
    func sortedDescending() -> [Element] {
        entries.sorted { $0.key > $1.key }.map(\.element)
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard entries[child].key < entries[parent].key else { return }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < entries.count, entries[left].key < entries[smallest].key { smallest = left }
            if right < entries.count, entries[right].key < entries[smallest].key { smallest = right }
            guard smallest != parent else { return }
            entries.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

/// One walk. A class, because the walk mutates a lot of shared state from
/// small helpers.
private final class DiskScan {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .totalFileSizeKey, .fileSizeKey, .linkCountKey, .contentModificationDateKey, .typeIdentifierKey,
        .volumeIdentifierKey,
    ]
    private static let keySet = Set(keys)
    private static let checkEvery = 512

    /// A file waiting in its folder's list of largest children.
    private struct FileChild {
        let url: URL
        let allocated: UInt64
        let logical: UInt64
        let category: DiskCategory
        let modified: Date?
    }

    private enum Child {
        case file(FileChild)
        /// A finished folder or package, already in the arena.
        case node(Int32)
    }

    /// A folder still being walked.
    private struct Frame {
        let url: URL
        let name: String
        let region: DiskRegion
        let isPackage: Bool
        /// Strictly inside a package: merged into it, never listed.
        let withinPackage: Bool
        let modified: Date?
        var allocated: UInt64 = 0
        var logical: UInt64 = 0
        var items = 0
        var categoryBytes = [UInt64](repeating: 0, count: DiskCategory.allCases.count)
        var children: LargestKept<Child>
        var foldedCount = 0
        var foldedAllocated: UInt64 = 0
        var foldedLogical: UInt64 = 0
        var isUnreadable = false

        /// Files in here are part of a package and aren't listed on their own.
        var insidePackage: Bool { isPackage || withinPackage }

        var dominantCategory: DiskCategory {
            guard let top = categoryBytes.indices.max(by: { categoryBytes[$0] < categoryBytes[$1] }), categoryBytes[top] > 0 else {
                switch region {
                case let .fixed(category), let .fallback(category): return category
                case .byType: return .other
                }
            }
            return DiskCategory(rawValue: top) ?? .other
        }
    }

    /// A finished folder, package or kept file.
    private struct Node {
        var name: String
        var kind: DiskItemKind
        var allocated: UInt64
        var logical: UInt64
        var items: Int
        var category: DiskCategory
        var modified: Date?
        var children: [Int32] = []
        var omitted = false
        var unreadable = false

        static let free = Node(name: "", kind: .file, allocated: 0, logical: 0, items: 0, category: .other, modified: nil)
    }

    /// Folders the enumerator couldn't open, reported from its error handler.
    private final class ErrorLog {
        var pending: [URL] = []
    }

    private let request: DiskScanRequest
    private let rootPath: String
    private var stack: [Frame] = []
    private var arena: [Node] = []
    private var freeSlots: [Int32] = []
    private var liveNodes = 0
    private var threshold: UInt64 = 0
    private var largest: LargestKept<DiskFile>
    private var hardLinks = Set<UInt64>()
    private var typeCategories: [String: DiskCategory] = [:]
    private var allowedVolumes: [any NSObjectProtocol] = []
    private let excludedDepth: Int
    private let rootDepth: Int

    private var itemCount = 0
    private var fileCount = 0
    private var folderCount = 0
    private var allocatedSoFar: UInt64 = 0
    private var unreadableFolders = 0
    private var unreadableExamples: [String] = []
    private var hardLinkDuplicates = 0
    private var skippedVolumes: [String] = []

    init(request: DiskScanRequest) {
        self.request = request
        // The enumerator reports real paths (`/private/tmp`, not `/tmp`), so
        // start from the real path too.
        rootPath = Self.realPath(request.root)
        rootDepth = URL(fileURLWithPath: rootPath).pathComponents.count - 1
        excludedDepth = request.excludedPaths.map { $0.split(separator: "/").count }.max() ?? 0
        largest = LargestKept(limit: request.largestFileLimit)
    }

    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func run(isCancelled: () -> Bool, progress: (DiskScanProgress) -> Void) -> DiskUsage? {
        let started = Date()
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let rootValues = try? root.resourceValues(forKeys: [.volumeIdentifierKey, .contentModificationDateKey])
        allowedVolumes = ([root] + request.alsoEnters).compactMap { try? $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier }
        stack = [Frame(url: root, name: (rootPath as NSString).lastPathComponent, region: request.rootRegion ?? request.rules.region(at: rootPath),
                       isPackage: false, withinPackage: false, modified: rootValues?.contentModificationDate,
                       children: LargestKept(limit: request.childLimit))]

        let errors = ErrorLog()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Self.keys, options: []) { url, _ in
            errors.pending.append(url)
            return true
        }
        var sinceCheck = 0
        var lastReport = CFAbsoluteTimeGetCurrent()
        while let next = enumerator?.nextObject() {
            if !errors.pending.isEmpty { recordErrors(errors) }
            guard let url = next as? URL, let enumerator else { continue }
            sinceCheck += 1
            if sinceCheck >= Self.checkEvery {
                sinceCheck = 0
                if isCancelled() { return nil }
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastReport >= DiskUsageScanner.progressInterval {
                    lastReport = now
                    progress(currentProgress(elapsed: Date().timeIntervalSince(started)))
                }
            }
            let level = enumerator.level
            while stack.count > max(level, 1) { finishTop() }
            visit(url, level: level, enumerator: enumerator)
        }
        if enumerator == nil { errors.pending.append(root) }
        if !errors.pending.isEmpty { recordErrors(errors) }
        if isCancelled() { return nil }
        while stack.count > 1 { finishTop() }
        let rootFrame = stack[0]
        let rootIndex = finishTop()
        return result(rootIndex: rootIndex, rootFrame: rootFrame, duration: Date().timeIntervalSince(started))
    }

    // MARK: - Walking

    private func visit(_ url: URL, level: Int, enumerator: FileManager.DirectoryEnumerator) {
        guard let values = try? url.resourceValues(forKeys: Self.keySet) else {
            itemCount += 1
            stack[stack.count - 1].items += 1
            return
        }
        if values.isDirectory == true, values.isSymbolicLink != true {
            let depth = rootDepth + level
            if let volume = values.volumeIdentifier, !allowedVolumes.contains(where: { $0.isEqual(volume) }) {
                enumerator.skipDescendants()
                if skippedVolumes.count < 20 { skippedVolumes.append(url.path) }
                return
            }
            if depth <= excludedDepth, request.excludedPaths.contains(url.path) {
                enumerator.skipDescendants()
                return
            }
            itemCount += 1
            folderCount += 1
            push(url, values: values, depth: depth)
        } else {
            itemCount += 1
            addFile(url, values: values)
        }
    }

    private func push(_ url: URL, values: URLResourceValues, depth: Int) {
        let parent = stack[stack.count - 1]
        let name = url.lastPathComponent
        let isPackage = values.isPackage == true && !parent.insidePackage
        var region = parent.region
        if !parent.insidePackage {
            region = request.rules.region(forFolder: name, parentName: parent.name, depth: depth, path: { url.path }, inside: parent.region)
            if isPackage {
                region = DiskCategoryRules.region(insidePackage: typeCategory(values.typeIdentifier, size: 0), in: region)
            }
        }
        stack.append(Frame(url: url, name: name, region: region, isPackage: isPackage, withinPackage: parent.insidePackage,
                           modified: values.contentModificationDate, children: LargestKept(limit: parent.insidePackage ? 0 : request.childLimit)))
    }

    private func addFile(_ url: URL, values: URLResourceValues) {
        let top = stack.count - 1
        if values.isSymbolicLink != true, (values.linkCount ?? 1) > 1,
           let identifier = try? url.resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier,
           !hardLinks.insert(identifier).inserted {
            // Another name for a file already counted.
            hardLinkDuplicates += 1
            fileCount += 1
            stack[top].items += 1
            return
        }
        fileCount += 1
        let allocated = UInt64(max(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0, 0))
        let logical = UInt64(max(values.totalFileSize ?? values.fileSize ?? 0, 0))
        allocatedSoFar += allocated
        let category: DiskCategory
        if case let .fixed(fixed) = stack[top].region {
            category = fixed
        } else {
            category = DiskCategoryRules.category(ofType: typeCategory(values.typeIdentifier, size: logical), in: stack[top].region)
        }
        stack[top].allocated += allocated
        stack[top].logical += logical
        stack[top].items += 1
        stack[top].categoryBytes[category.rawValue] += allocated
        guard !stack[top].insidePackage else { return }
        let modified = values.contentModificationDate
        offer(.file(FileChild(url: url, allocated: allocated, logical: logical, category: category, modified: modified)), size: allocated, to: top)
        if largest.accepts(allocated) {
            _ = largest.insert(DiskFile(path: url.path, isPackage: false, allocatedSize: allocated, logicalSize: logical,
                                        category: category, modified: modified), key: allocated)
        }
    }

    /// Closes the innermost open folder: turns it into a node (unless it's
    /// inside a package) and adds it to its parent.
    @discardableResult
    private func finishTop() -> Int32 {
        let frame = stack.removeLast()
        let isRoot = stack.isEmpty
        if !isRoot {
            let top = stack.count - 1
            stack[top].allocated += frame.allocated
            stack[top].logical += frame.logical
            stack[top].items += frame.items + 1
            for index in frame.categoryBytes.indices { stack[top].categoryBytes[index] += frame.categoryBytes[index] }
            if frame.withinPackage { return -1 }
        }

        var children: [Int32] = []
        var omitted = false
        if !frame.isPackage {
            if !isRoot, frame.allocated < threshold, frame.children.count + frame.foldedCount > 0 {
                omitted = true
                for entry in frame.children.entries { if case let .node(index) = entry.element { release(index) } }
            } else {
                children = frame.children.sortedDescending().map { child in
                    switch child {
                    case let .node(index):
                        return index
                    case let .file(file):
                        return allocate(Node(name: file.url.lastPathComponent, kind: .file, allocated: file.allocated,
                                             logical: file.logical, items: 0, category: file.category, modified: file.modified))
                    }
                }
                if frame.foldedCount > 0 {
                    children.append(allocate(Node(name: "", kind: .smallerItems, allocated: frame.foldedAllocated, logical: frame.foldedLogical,
                                                  items: frame.foldedCount, category: .other, modified: nil)))
                }
            }
        }
        let index = allocate(Node(name: frame.name, kind: frame.isPackage ? .package : .folder, allocated: frame.allocated,
                                  logical: frame.logical, items: frame.items, category: frame.dominantCategory, modified: frame.modified,
                                  children: children, omitted: omitted, unreadable: frame.isUnreadable))
        guard !isRoot else { return index }

        let top = stack.count - 1
        offer(.node(index), size: frame.allocated, to: top)
        if frame.isPackage, largest.accepts(frame.allocated) {
            _ = largest.insert(DiskFile(path: frame.url.path, isPackage: true, allocatedSize: frame.allocated, logicalSize: frame.logical,
                                        category: frame.dominantCategory, modified: frame.modified), key: frame.allocated)
        }
        if liveNodes > request.nodeBudget { tighten() }
        return index
    }

    /// Adds a child to a folder's list of largest children; whatever drops
    /// out of the list joins the "smaller items" row.
    private func offer(_ child: Child, size: UInt64, to frame: Int) {
        guard let evicted = stack[frame].children.insert(child, key: size) else { return }
        switch evicted {
        case let .file(file):
            fold(size: file.allocated, logical: file.logical, into: frame)
        case let .node(index):
            let node = arena[Int(index)]
            fold(size: node.allocated, logical: node.logical, into: frame)
            release(index)
        }
    }

    private func fold(size: UInt64, logical: UInt64, into frame: Int) {
        stack[frame].foldedCount += 1
        stack[frame].foldedAllocated += size
        stack[frame].foldedLogical += logical
    }

    private func recordErrors(_ errors: ErrorLog) {
        for url in errors.pending {
            unreadableFolders += 1
            // Not `standardizedFileURL`, which turns the enumerator's real
            // `/private/var` paths back into `/var`.
            let path = url.path
            if unreadableExamples.count < 5 { unreadableExamples.append(path) }
            if let index = stack.lastIndex(where: { $0.url.path == path }) {
                stack[index].isUnreadable = true
            }
        }
        errors.pending.removeAll()
    }

    private func typeCategory(_ identifier: String?, size: UInt64) -> DiskCategory {
        guard let identifier else { return .other }
        if identifier == "public.mpeg-2-transport-stream" { return DiskCategoryRules.category(forType: identifier, size: size) }
        if let known = typeCategories[identifier] { return known }
        let category = DiskCategoryRules.category(forType: identifier, size: size)
        typeCategories[identifier] = category
        return category
    }

    private func currentProgress(elapsed: TimeInterval) -> DiskScanProgress {
        DiskScanProgress(itemCount: itemCount, allocatedSize: allocatedSoFar, currentFolder: stack.last?.url.path ?? rootPath,
                         elapsed: elapsed, unreadableFolders: unreadableFolders)
    }

    // MARK: - Memory

    private func allocate(_ node: Node) -> Int32 {
        liveNodes += 1
        if let slot = freeSlots.popLast() {
            arena[Int(slot)] = node
            return slot
        }
        arena.append(node)
        return Int32(arena.count - 1)
    }

    /// Frees a node and everything under it.
    private func release(_ index: Int32) {
        for child in arena[Int(index)].children { release(child) }
        arena[Int(index)] = .free
        freeSlots.append(index)
        liveNodes -= 1
    }

    /// Over budget: raise the detail threshold and drop the contents of
    /// every finished folder below it, until well under budget.
    private func tighten() {
        repeat {
            threshold = max(threshold.multipliedReportingOverflow(by: 4).partialValue, 1 << 20)
            for frame in stack.indices {
                for entry in stack[frame].children.entries { if case let .node(index) = entry.element { collapse(index) } }
            }
        } while liveNodes > request.nodeBudget / 2 && threshold < UInt64.max / 8
    }

    private func collapse(_ index: Int32) {
        let node = arena[Int(index)]
        guard node.kind == .folder, !node.children.isEmpty else { return }
        if node.allocated < threshold {
            for child in node.children { release(child) }
            arena[Int(index)].children = []
            arena[Int(index)].omitted = true
        } else {
            for child in node.children { collapse(child) }
        }
    }

    // MARK: - Result

    private func result(rootIndex: Int32, rootFrame: Frame, duration: TimeInterval) -> DiskUsage {
        // Breadth first, so every node's children are contiguous.
        var order: [Int32] = [rootIndex]
        var parents: [Int?] = [nil]
        var ranges: [Range<Int>] = []
        var position = 0
        while position < order.count {
            let children = arena[Int(order[position])].children
            let start = order.count
            order.append(contentsOf: children)
            parents.append(contentsOf: repeatElement(position, count: children.count))
            ranges.append(start..<order.count)
            position += 1
        }
        let items = order.enumerated().map { offset, index in
            let node = arena[Int(index)]
            let isRoot = offset == 0
            return DiskItem(id: offset, parent: parents[offset], name: isRoot ? rootFrame.name : node.name, kind: isRoot ? .folder : node.kind,
                            allocatedSize: node.allocated, logicalSize: node.logical, itemCount: node.items, category: node.category,
                            modified: node.modified, children: ranges[offset], contentsOmitted: node.omitted, isUnreadable: node.unreadable)
        }
        let categories = DiskCategory.allCases
            .map { DiskCategoryTotal(category: $0, allocatedSize: rootFrame.categoryBytes[$0.rawValue]) }
            .sorted { $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.category < $1.category }
        return DiskUsage(
            rootPath: rootPath, items: items, largestFiles: largest.sortedDescending(), categories: categories,
            fileCount: fileCount, folderCount: folderCount, unreadableFolders: unreadableFolders,
            unreadableExamples: unreadableExamples, hardLinkDuplicates: hardLinkDuplicates, skippedVolumes: skippedVolumes,
            detailThreshold: threshold, duration: duration, finishedAt: Date()
        )
    }
}
