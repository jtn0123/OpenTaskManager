import Foundation
@testable import OTMKit
import Testing

struct TreemapReachTests {
    // Items below the open folder: Projects (1) › webapp (3) › build (4).
    private let toBuild = [1, 3, 4]

    @Test func aTileOfItsOwn() {
        #expect(TreemapReach.of(path: [1], drawn: 1, exists: true, isKept: true) == .drawn)
        #expect(TreemapReach.of(path: [1, 3], drawn: 3, exists: true, isKept: true) == .drawn)
        #expect(TreemapReach.drawn.holder == nil)
    }

    @Test func pastTheLevelsDrawnTheDeepestTileHoldsIt() {
        // build is three levels down; the map draws two.
        let reach = TreemapReach.of(path: toBuild, drawn: 3, exists: true, isKept: true)
        #expect(reach == .tooDeep(holder: 3))
        #expect(reach.holder == 3)
        // webapp too small to draw inside Projects' tile: Projects holds it.
        #expect(TreemapReach.of(path: toBuild, drawn: 1, exists: true, isKept: true) == .tooDeep(holder: 1))
    }

    @Test func onALevelDrawnButTooSmall() {
        // webapp is on the second level, but its folder's tile had no room for it.
        #expect(TreemapReach.of(path: [1, 3], drawn: 1, exists: true, isKept: true) == .tooSmall(holder: 1))
        // Not even a tile for its folder.
        #expect(TreemapReach.of(path: [1, 3], drawn: nil, exists: true, isKept: true) == .tooSmall(holder: nil))
        #expect(TreemapReach.of(path: toBuild, drawn: nil, exists: true, isKept: true) == .tooSmall(holder: nil))
    }

    @Test func notKeptOnItsOwnIsCountedInWhatHoldsIt() {
        // Path ends in webapp's "smaller items" (5), drawn as a tile of its own.
        let reach = TreemapReach.of(path: [1, 3, 5], drawn: 5, exists: true, isKept: false)
        #expect(reach == .notKept(holder: 5))
        #expect(TreemapReach.of(path: [1, 3, 5], drawn: 3, exists: true, isKept: false).holder == 3)
    }

    @Test func removedIsOutlinedWhereItWas() {
        #expect(TreemapReach.of(path: [1, 3], drawn: 3, exists: false, isKept: false) == .removed(holder: 3))
        // Gone straight from the open folder: nothing on the map stands for it.
        #expect(TreemapReach.of(path: [], drawn: nil, exists: false, isKept: false) == .removed(holder: nil))
    }
}

struct ChangedFolderTests {
    /// /demo › Projects › webapp › build › bundle.bin, with webapp's small
    /// files folded into "smaller items" and a folder whose contents weren't kept.
    private static let usage: DiskUsage = {
        func item(_ id: Int, _ parent: Int?, _ name: String, _ kind: DiskItemKind, _ children: Range<Int>,
                  omitted: Bool = false) -> DiskItem {
            DiskItem(id: id, parent: parent, name: name, kind: kind, allocatedSize: 100, logicalSize: 100, itemCount: 1,
                     category: .developer, modified: nil, children: children, contentsOmitted: omitted)
        }
        let items = [
            item(0, nil, "", .folder, 1..<3),
            item(1, 0, "Projects", .folder, 3..<4),
            item(2, 0, "Cache", .folder, 4..<4, omitted: true),
            item(3, 1, "webapp", .folder, 4..<6),
            item(4, 3, "build", .folder, 6..<7),
            item(5, 3, "", .smallerItems, 7..<7),
            item(6, 4, "bundle.bin", .file, 7..<7),
        ]
        return DiskUsage(rootPath: "/demo", items: items, largestFiles: [], categories: [], fileCount: 1, folderCount: 4,
                         unreadableFolders: 0, unreadablePaths: [], hardLinkDuplicates: 0, skippedVolumes: [], detailThreshold: 0,
                         duration: 0, finishedAt: Date(timeIntervalSince1970: 0))
    }()

    private func change(_ path: String, _ kind: DiskSizeChange.Kind) -> DiskSizeChange {
        DiskSizeChange(path: path, kind: kind, before: .exact(0), after: .exact(100))
    }

    @Test func aFolderThatChangedOpensItself() {
        #expect(Self.usage.folder(showing: change("Projects/webapp/build", .folder)).name == "build")
        #expect(Self.usage.folder(showing: change("Projects", .folder)).name == "Projects")
    }

    @Test func aFileOpensTheFolderHoldingIt() {
        #expect(Self.usage.folder(showing: change("Projects/webapp/build/bundle.bin", .file)).name == "build")
        #expect(Self.usage.folder(showing: change("Projects/webapp/app.zip", .package)).name == "webapp")
    }

    @Test func goesAsDeepAsTheScanKept() {
        // A folder too small to keep, inside webapp; and one inside a folder whose contents weren't kept.
        #expect(Self.usage.folder(showing: change("Projects/webapp/tmp", .folder)).name == "webapp")
        #expect(Self.usage.folder(showing: change("Cache/blobs", .folder)).name == "Cache")
        // Removed from the scanned folder itself.
        #expect(Self.usage.folder(showing: change("Old", .folder)).id == 0)
    }
}
