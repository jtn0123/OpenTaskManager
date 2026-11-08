import Foundation

public extension DiskScanSummary {
    /// A saved summary can reopen its bounded folder tree without touching the disk.
    /// Missing children stay one remainder, never invented file names or cleanup targets.
    func boundedUsage() -> DiskUsage {
        var children: [Int: [Int]] = [:]
        for index in folders.indices.dropFirst() { children[folders[index].parent, default: []].append(index) }
        var sources = [0]
        var parents: [Int?] = [nil]
        var items: [DiskItem] = []
        var cursor = 0
        while cursor < sources.count {
            let source = sources[cursor]
            if source < 0 {
                let entry = folders[-source - 1]
                let listed = children[-source - 1] ?? []
                let allocated = listed.reduce(entry.allocatedSize) { $0 - min($0, folders[$1].allocatedSize) }
                let logical = listed.reduce(entry.logicalSize) { $0 - min($0, folders[$1].logicalSize) }
                items.append(DiskItem(id: cursor, parent: parents[cursor], name: "", kind: .smallerItems,
                                      allocatedSize: allocated, logicalSize: logical, itemCount: 0, category: .other,
                                      modified: nil, children: 0..<0, contentsOmitted: true))
                cursor += 1
                continue
            }
            let entry = folders[source]
            let start = sources.count
            let listed = (children[source] ?? []).sorted { folders[$0].allocatedSize > folders[$1].allocatedSize }
            sources.append(contentsOf: listed)
            parents.append(contentsOf: listed.map { _ in cursor })
            let remainder = listed.reduce(entry.allocatedSize) { $0 - min($0, folders[$1].allocatedSize) }
            if remainder > 0 && !entry.isPackage {
                sources.append(-source - 1)
                parents.append(cursor)
            }
            items.append(DiskItem(id: cursor, parent: parents[cursor], name: entry.name,
                                  kind: entry.isPackage ? .package : .folder, allocatedSize: entry.allocatedSize,
                                  logicalSize: entry.logicalSize, itemCount: entry.itemCount, category: .other, modified: nil,
                                  children: start..<sources.count, contentsOmitted: listed.isEmpty && remainder > 0,
                                  isUnreadable: entry.isUnreadable, unreadableCount: entry.unreadableCount))
            cursor += 1
        }
        return DiskUsage(rootPath: scope.rootPath, items: items, largestFiles: largestFiles.map { file in
            DiskFile(path: (scope.rootPath as NSString).appendingPathComponent(file.path), isPackage: file.isPackage,
                     allocatedSize: file.allocatedSize, logicalSize: file.logicalSize, category: .other, modified: nil)
        }, largestFilesCutoff: largestFilesCutoff, categories: categories, fileCount: fileCount, folderCount: folderCount,
                         unreadableFolders: unreadableFolders,
                         unreadablePaths: unreadablePaths.map { (scope.rootPath as NSString).appendingPathComponent($0) },
                         hardLinkDuplicates: hardLinkDuplicates, skippedVolumes: [], detailThreshold: 0,
                         duration: duration, finishedAt: scannedAt)
    }
}
