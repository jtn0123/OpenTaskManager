import Foundation
@testable import OTMKit
import Testing

private let scope = DiskScanScope(rootPath: "/Users/test")

/// A summary from folder paths and sizes, the scanned folder ("") first and
/// every folder after the one holding it.
private func summary(_ folders: [(String, UInt64)], files: [(String, UInt64)] = [], unlisted: [String: UInt64] = [:],
                     fileLimits: [String: UInt64] = [:], unreadable: [String] = [], packages: Set<String> = [], cutoff: UInt64 = 0,
                     at time: TimeInterval = 0) -> DiskScanSummary {
    var index: [String: Int] = [:]
    let entries = folders.enumerated().map { offset, folder in
        let (path, size) = folder
        index[path] = offset
        let parent = path.isEmpty ? -1 : index[(path as NSString).deletingLastPathComponent]!
        let inside = unreadable.filter { path.isEmpty || $0 == path || $0.hasPrefix(path + "/") }.count
        return DiskScanSummary.Folder(name: (path as NSString).lastPathComponent, parent: parent, isPackage: packages.contains(path),
                                      allocatedSize: size, logicalSize: size, itemCount: 1, isUnreadable: unreadable.contains(path),
                                      unreadableCount: inside, unlistedLimit: unlisted[path] ?? 0, fileLimit: fileLimits[path])
    }
    let largest = files.map { DiskScanSummary.File(path: $0.0, isPackage: packages.contains($0.0), allocatedSize: $0.1, logicalSize: $0.1) }
    return DiskScanSummary(scope: scope, scannedAt: Date(timeIntervalSince1970: time), unreadableFolders: unreadable.count,
                           unreadablePaths: unreadable, folders: entries, largestFiles: largest, largestFilesCutoff: cutoff)
}

struct DiskScanComparisonTests {
    @Test func reportsWhatGrewAndShrank() {
        let earlier = summary([("", 1_000), ("Movies", 600), ("Downloads", 300), ("Documents", 100)])
        let later = summary([("", 1_150), ("Movies", 600), ("Downloads", 500), ("Documents", 50)])
        let comparison = DiskScanComparison(earlier: earlier, later: later)

        #expect(comparison.total.growth == 150)
        #expect(comparison.total.isExact)
        #expect(comparison.total.direction() == .grew)
        let report = comparison.report()
        #expect(report.grew.map(\.path) == ["Downloads"])
        #expect(report.grew.first?.growth == 200)
        #expect(report.shrank.map(\.path) == ["Documents"])
        #expect(report.shrank.first?.shrinkage == 50)
        // Movies didn't move.
        #expect(comparison.folders.first { $0.path == "Movies" }?.direction() == .same)
    }

    @Test func newAndRemovedFoldersCountFromZero() throws {
        // Every folder with any space is listed (no unlisted limit), so a
        // missing one wasn't there.
        let earlier = summary([("", 500), ("Old", 200), ("Keep", 300)])
        let later = summary([("", 700), ("Keep", 300), ("New", 400)])
        let report = DiskScanComparison(earlier: earlier, later: later).report()

        let new = try #require(report.grew.first)
        #expect(new.path == "New" && new.isNew && new.growth == 400)
        let old = try #require(report.shrank.first)
        #expect(old.path == "Old" && old.isGone && old.shrinkage == 200)
    }

    @Test func listsTheFolderThatExplainsTheGrowth() {
        // Projects grew only because Projects/app/build did: the report names build.
        let earlier = summary([("", 1_000), ("Projects", 600), ("Projects/app", 500), ("Projects/app/src", 100), ("Music", 400)])
        let later = summary([("", 1_500), ("Projects", 1_100), ("Projects/app", 1_000), ("Projects/app/src", 100),
                             ("Projects/app/build", 500), ("Music", 400)])
        let comparison = DiskScanComparison(earlier: earlier, later: later)
        #expect(comparison.report().grew.map(\.path) == ["Projects/app/build"])
        // A folder that grew on its own as well as through a child is listed too.
        let spread = summary([("", 1_700), ("Projects", 1_300), ("Projects/app", 1_000), ("Projects/app/src", 100),
                              ("Projects/app/build", 500), ("Music", 400)])
        let paths = DiskScanComparison(earlier: earlier, later: spread).report().grew.map(\.path)
        #expect(paths == ["Projects", "Projects/app/build"])
    }

    @Test func theLargestChangeComesFirst() throws {
        let earlier = summary([("", 1_000), ("Movies", 600), ("Downloads", 300), ("Documents", 100)], files: [("Movies/a.mov", 500)])
        let later = summary([("", 950), ("Movies", 600), ("Downloads", 350), ("Documents", 0)], files: [("Movies/a.mov", 500)])
        let report = DiskScanComparison(earlier: earlier, later: later).report()
        // Documents lost 100, more than Downloads gained.
        let largest = try #require(report.largest)
        #expect(largest.path == "Documents" && largest.shrinkage == 100)
        #expect(report.lists(largest.id))
        #expect(report.lists(try #require(report.grew.first).id))
        #expect(!report.lists("folder:Movies"))
        // A folder beats the equal file inside it that explains it, as the list puts it first.
        let built = summary([("", 1_150), ("Movies", 600), ("Downloads", 300), ("Documents", 250), ("Documents/build", 150)],
                            files: [("Movies/a.mov", 500), ("Documents/build/app.bin", 150)])
        let added = DiskScanComparison(earlier: earlier, later: built).report()
        #expect(added.filesAdded.map(\.path) == ["Documents/build/app.bin"])
        #expect(added.largest?.path == "Documents/build")
        // Nothing moved: nothing to show.
        #expect(DiskScanComparison(earlier: earlier, later: earlier).report().largest == nil)
    }

    @Test func reportsCoverOnlyTheOpenFolder() {
        let earlier = summary([("", 1_000), ("A", 500), ("A/x", 200), ("B", 500), ("B/y", 300)])
        let later = summary([("", 1_400), ("A", 600), ("A/x", 300), ("B", 800), ("B/y", 600)])
        let comparison = DiskScanComparison(earlier: earlier, later: later)
        let report = comparison.report(under: "A")
        #expect(report.total.path == "A" && report.total.growth == 100)
        #expect(report.grew.map(\.path) == ["A/x"])
        #expect(comparison.report(under: "B").grew.map(\.path) == ["B/y"])
    }

    @Test func limitsAndThresholdsBoundTheLists() {
        var before: [(String, UInt64)] = [("", 0)]
        var after: [(String, UInt64)] = [("", 0)]
        for index in 1...20 {
            before.append(("f\(index)", 1_000))
            after.append(("f\(index)", 1_000 + UInt64(index) * 10))
        }
        let report = DiskScanComparison(earlier: summary(before), later: summary(after)).report(limit: 5, ignoringUnder: 100)
        // Largest first, five at most, none of 100 or less.
        #expect(report.grew.map(\.path) == ["f20", "f19", "f18", "f17", "f16"])
        let small = DiskScanComparison(earlier: summary(before), later: summary(after)).report(limit: 50, ignoringUnder: 150)
        #expect(small.grew.count == 5)
        // The noise floor: 64 KB, or a ten-thousandth of a big folder.
        #expect(DiskScanComparison.noiseFloor(for: 1_000) == 65_536)
        #expect(DiskScanComparison.noiseFloor(for: 500_000_000_000) == 50_000_000)
    }

    @Test func foldersTooSmallToKeepAreBoundedNotZero() throws {
        // The earlier summary left out folders in Downloads under 100.
        let earlier = summary([("", 1_000), ("Downloads", 1_000)], unlisted: ["Downloads": 100])
        let later = summary([("", 1_600), ("Downloads", 1_600), ("Downloads/big", 600), ("Downloads/small", 80)])
        let comparison = DiskScanComparison(earlier: earlier, later: later)

        let big = try #require(comparison.folders.first { $0.path == "Downloads/big" })
        #expect(big.before == .atMost(100))
        #expect(!big.isNew && !big.isExact)
        // It grew by at least 500, perhaps 600.
        #expect(big.growth == 500)
        #expect(big.direction() == .grew)
        // 80 now and at most 100 before: no telling which way it went.
        let small = try #require(comparison.folders.first { $0.path == "Downloads/small" })
        #expect(small.growth == 0 && small.shrinkage == 0)
        #expect(small.direction() == .unclear)
        #expect(small.direction(ignoringUnder: 100) == .same)
        // Deeper folders take the nearest listed folder's limit.
        let deep = comparison.change(ofFolder: "Downloads/big/inner", now: .exact(300))
        #expect(deep.before == .atMost(100))
        #expect(deep.growth == 200)
    }

    @Test func aFolderThatBecameUnreadableIsNotSpaceFreed() throws {
        let earlier = summary([("", 1_000), ("Library", 800), ("Library/Mail", 500), ("Library/Caches", 300), ("Music", 200)])
        // Mail couldn't be read the second time, so it adds nothing; Caches really shrank.
        let later = summary([("", 400), ("Library", 200), ("Library/Caches", 200), ("Music", 200)], unreadable: ["Library/Mail"])
        let comparison = DiskScanComparison(earlier: earlier, later: later)

        let mail = try #require(comparison.folders.first { $0.path == "Library/Mail" })
        #expect(mail.after == .unknown)
        #expect(mail.shrinkage == 0)
        #expect(mail.direction() == .unclear)
        let library = try #require(comparison.folders.first { $0.path == "Library" })
        #expect(library.readabilityChanged)
        #expect(library.shrinkage == 0)
        #expect(comparison.total.direction() == .unclear)
        #expect(comparison.total.measuredDelta == -600)

        let report = comparison.report()
        #expect(report.shrank.map(\.path) == ["Library/Caches"])
        #expect(report.becameUnreadable.map(\.path) == ["Library/Mail"])
        #expect(report.becameReadable.isEmpty)
    }

    @Test func aFolderThatBecameReadableIsNotGrowth() throws {
        let earlier = summary([("", 300), ("Library", 100), ("Music", 200)], unreadable: ["Library/Mail"])
        let later = summary([("", 800), ("Library", 600), ("Library/Mail", 500), ("Music", 200)])
        let comparison = DiskScanComparison(earlier: earlier, later: later)

        let mail = try #require(comparison.folders.first { $0.path == "Library/Mail" })
        #expect(mail.before == .unknown)
        #expect(mail.growth == 0)
        #expect(comparison.total.growth == 0)
        #expect(comparison.total.readabilityChanged)
        let report = comparison.report()
        #expect(report.grew.isEmpty)
        #expect(report.becameReadable.map(\.path) == ["Library/Mail"])
    }

    @Test func theSameUnreadableFolderInBothScansStillCompares() {
        let earlier = summary([("", 300), ("Library", 100), ("Music", 200)], unreadable: ["Library/Mail"])
        let later = summary([("", 500), ("Library", 300), ("Music", 200)], unreadable: ["Library/Mail"])
        let comparison = DiskScanComparison(earlier: earlier, later: later)
        #expect(comparison.total.growth == 200)
        #expect(!comparison.total.readabilityChanged)
    }

    @Test func largeFilesAddedAndRemoved() {
        // Both lists held every file.
        let earlier = summary([("", 900), ("Downloads", 900)], files: [("Downloads/old.zip", 600), ("Downloads/keep.dmg", 300)])
        let later = summary([("", 1_100), ("Downloads", 1_100)], files: [("Downloads/new.mov", 800), ("Downloads/keep.dmg", 300)])
        let report = DiskScanComparison(earlier: earlier, later: later).report()

        #expect(report.filesAdded.map(\.path) == ["Downloads/new.mov"])
        #expect(report.filesAdded.first?.isNew == true)
        #expect(report.filesAdded.first?.growth == 800)
        #expect(report.filesRemoved.map(\.path) == ["Downloads/old.zip"])
        #expect(report.filesRemoved.first?.isGone == true)
    }

    @Test func aFullFileListOnlyBoundsWhatItLeftOut() throws {
        // The earlier list had no room for files of 250 or less.
        let earlier = summary([("", 1_000), ("A", 1_000)], files: [("A/a", 500), ("A/b", 250)], cutoff: 250)
        let later = summary([("", 1_400), ("A", 1_400)], files: [("A/c", 400), ("A/a", 500)], cutoff: 0)
        let report = DiskScanComparison(earlier: earlier, later: later).report()

        let added = try #require(report.filesAdded.first)
        #expect(added.path == "A/c")
        // It may have been there at up to 250.
        #expect(!added.isNew && added.growth == 150)
        // The later list holds every file, so b is gone.
        #expect(report.filesRemoved.map(\.path) == ["A/b"])
        #expect(report.filesRemoved.first?.isGone == true)
    }

    @Test func aFileNoBiggerThanItsFolder() throws {
        // The earlier list stopped at 250, but A/new wasn't there at all and
        // A/small only held 40.
        let earlier = summary([("", 1_000), ("A", 1_000), ("A/small", 40)], files: [("A/a", 500)], cutoff: 250)
        let later = summary([("", 1_600), ("A", 1_600), ("A/small", 100), ("A/new", 500)],
                            files: [("A/new/big.bin", 500), ("A/a", 500), ("A/small/log", 100)], cutoff: 0)
        let comparison = DiskScanComparison(earlier: earlier, later: later)

        let new = try #require(comparison.files.first { $0.path == "A/new/big.bin" })
        #expect(new.before == .absent && new.isNew && new.isExact && new.growth == 500)
        let log = try #require(comparison.files.first { $0.path == "A/small/log" })
        #expect(log.before == .atMost(40) && log.growth == 60)
        // A file off a full list is still gone for sure when its folder had
        // every file on the list; with another file left off, only bounded.
        let full = summary([("", 900), ("D", 900)], files: [("D/old.zip", 600), ("D/disk.iso", 300)], cutoff: 300)
        let complete = summary([("", 300), ("D", 300)], files: [("D/disk.iso", 300)], fileLimits: ["D": 0], cutoff: 300)
        let removed = try #require(DiskScanComparison(earlier: full, later: complete).files.first { $0.path == "D/old.zip" })
        #expect(removed.after == .absent && removed.isGone && removed.isExact && removed.shrinkage == 600)
        let partial = summary([("", 310), ("D", 310)], files: [("D/disk.iso", 300)], fileLimits: ["D": 10], cutoff: 300)
        let bounded = try #require(DiskScanComparison(earlier: full, later: partial).files.first { $0.path == "D/old.zip" })
        #expect(bounded.after == .atMost(10) && bounded.shrinkage == 590 && !bounded.isExact)
        // Still unknown inside a folder the earlier scan couldn't read.
        let locked = summary([("", 1_000), ("A", 1_000), ("A/locked", 10)], unreadable: ["A/locked"], cutoff: 250)
        let opened = summary([("", 1_100), ("A", 1_100), ("A/locked", 110)], files: [("A/locked/x", 100)])
        let inside = try #require(DiskScanComparison(earlier: locked, later: opened).files.first)
        #expect(!inside.before.isBounded && inside.direction() == .unclear)
    }

    @Test func packagesComeAndGoWithTheFiles() {
        let earlier = summary([("", 100), ("Applications", 100)])
        let later = summary([("", 600), ("Applications", 600), ("Applications/Tool.app", 500)], files: [("Applications/Tool.app", 500)],
                            packages: ["Applications/Tool.app"])
        let report = DiskScanComparison(earlier: earlier, later: later).report()
        #expect(report.filesAdded.map(\.path) == ["Applications/Tool.app"])
        #expect(report.filesAdded.first?.kind == .package)
        // Not listed twice: the folder holding it grew instead.
        #expect(report.grew.map(\.path) == ["Applications"])
        // A package that was there before and grew is a folder like any other.
        let grown = summary([("", 900), ("Applications", 900), ("Applications/Tool.app", 800)], files: [("Applications/Tool.app", 800)],
                            packages: ["Applications/Tool.app"])
        let update = DiskScanComparison(earlier: later, later: grown).report()
        #expect(update.grew.map(\.path) == ["Applications/Tool.app"])
        #expect(update.filesAdded.isEmpty)
    }
}

struct DiskScanSummaryTests {
    private func scan(_ fixture: Fixture, childLimit: Int = 200, largestFileLimit: Int = 50) throws -> (DiskUsage, DiskScanSummary) {
        var request = DiskScanRequest(root: fixture.root)
        request.rootRegion = .byType
        request.childLimit = childLimit
        request.largestFileLimit = largestFileLimit
        let usage = try #require(DiskUsageScanner.scan(request))
        return (usage, DiskScanSummary(usage, scope: DiskScanScope(usage, request: request)))
    }

    @Test func keepsTheLargestFoldersAsATree() throws {
        let fixture = try Fixture()
        try fixture.file("big/a/one.bin", size: 400_000)
        try fixture.file("big/b/two.bin", size: 300_000)
        try fixture.file("mid/three.bin", size: 200_000)
        try fixture.file("small/four.bin", size: 10_000)
        try fixture.file("loose.bin", size: 5_000)
        let (usage, all) = try scan(fixture)

        #expect(all.folders.count == 6)
        #expect(all.allocatedSize == usage.root.allocatedSize)
        #expect(all.isWellFormed)
        #expect(Set(all.folderPaths()) == ["", "big", "big/a", "big/b", "mid", "small"])
        #expect(all.largestFiles.first?.path == "big/a/one.bin")
        #expect(all.largestFilesCutoff == 0)

        // Room for three: the two biggest folders and the scanned one.
        let kept = DiskScanSummary(usage, scope: all.scope, folderLimit: 3)
        #expect(kept.folderPaths() == ["", "big", "big/a"])
        #expect(kept.isWellFormed)
        // Whatever the scanned folder lost is no bigger than mid, and big's no bigger than b.
        #expect(kept.root.unlistedLimit == (try fixture.allocated("mid/three.bin")))
        #expect(kept.folders[1].unlistedLimit == (try fixture.allocated("big/b/two.bin")))
        #expect(kept.folders[2].unlistedLimit == 0)
        #expect(all.root.unlistedLimit == 0)
    }

    @Test func boundsChildrenFoldedIntoSmallerItems() throws {
        let fixture = try Fixture()
        for index in 1...6 {
            try fixture.file("many/sub\(index)/file.bin", size: index * 8_192)
        }
        let (usage, summary) = try scan(fixture, childLimit: 3)
        let many = try #require(usage.item(atPath: "many"))
        #expect(usage.children(of: many).last?.kind == .smallerItems)
        // The three folded folders are each no bigger than the smallest kept (sub4).
        let index = try #require(summary.folderPaths().firstIndex(of: "many"))
        #expect(summary.folders[index].unlistedLimit == (try fixture.allocated("many/sub4/file.bin")))
    }

    @Test func comparesTwoRealScans() throws {
        let fixture = try Fixture()
        try fixture.file("Downloads/old.zip", size: 300_000)
        try fixture.file("Movies/clip.mov", size: 500_000)
        let (_, earlier) = try scan(fixture)

        try FileManager.default.removeItem(at: fixture.url("Downloads/old.zip"))
        try fixture.file("Projects/build/bundle.bin", size: 700_000)
        let (_, later) = try scan(fixture)
        let comparison = DiskScanComparison(earlier: earlier, later: later)
        let report = comparison.report()

        let added = try fixture.allocated("Projects/build/bundle.bin")
        let removed = earlier.largestFiles.first { $0.path == "Downloads/old.zip" }?.allocatedSize ?? 0
        #expect(comparison.total.isExact)
        #expect(comparison.total.measuredDelta == Int64(added) - Int64(removed))
        #expect(report.grew.map(\.path) == ["Projects/build"])
        #expect(report.grew.first?.isNew == true)
        #expect(report.shrank.map(\.path) == ["Downloads"])
        #expect(report.filesAdded.map(\.path) == ["Projects/build/bundle.bin"])
        #expect(report.filesRemoved.map(\.path) == ["Downloads/old.zip"])
        #expect(comparison.folders.first { $0.path == "Movies" }?.direction() == .same)
    }

    @Test func notesTheLargestFileEachFolderLeftOffTheList() throws {
        let fixture = try Fixture()
        try fixture.file("Downloads/old.zip", size: 600_000)
        try fixture.file("Downloads/disk.iso", size: 450_000)
        try fixture.file("Movies/clip.mov", size: 500_000)
        try fixture.file("Movies/short.mov", size: 100_000)
        // Room for the two largest files only.
        let (_, earlier) = try scan(fixture, largestFileLimit: 2)
        #expect(earlier.largestFiles.map(\.path) == ["Downloads/old.zip", "Movies/clip.mov"])
        let paths = earlier.folderPaths()
        let movies = try #require(paths.firstIndex(of: "Movies"))
        #expect(earlier.folders[movies].fileLimit == (try fixture.allocated("Movies/short.mov")))
        // The decoded summary keeps it.
        #expect(try DiskScanHistory.decode(DiskScanHistory.encode(earlier)) == earlier)

        try FileManager.default.removeItem(at: fixture.url("Downloads/old.zip"))
        let (_, later) = try scan(fixture, largestFileLimit: 2)
        let downloads = try #require(later.folderPaths().firstIndex(of: "Downloads"))
        // Its one file is on the list now, so old.zip is gone for certain.
        #expect(later.folders[downloads].fileLimit == 0)
        let removed = try #require(DiskScanComparison(earlier: earlier, later: later).report().filesRemoved.first)
        #expect(removed.path == "Downloads/old.zip" && removed.isGone && removed.isExact)
    }

    @Test func aLockedFolderIsNotReclaimedSpace() throws {
        let fixture = try Fixture()
        try fixture.file("open/a.bin", size: 100_000)
        try fixture.file("private/secret.bin", size: 400_000)
        let (_, earlier) = try scan(fixture)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.url("private").path)
        let (_, later) = try scan(fixture)
        let comparison = DiskScanComparison(earlier: earlier, later: later)

        #expect(later.unreadablePaths == ["private"])
        #expect(comparison.total.measuredDelta < 0)
        #expect(comparison.total.shrinkage == 0)
        #expect(comparison.total.direction() == .unclear)
        let report = comparison.report()
        #expect(report.shrank.isEmpty)
        #expect(report.filesRemoved.isEmpty)
        #expect(report.becameUnreadable.map(\.path) == ["private"])
    }

    @Test func scopesNameTheirFolderAndStayApart() {
        let first = DiskScanScope(rootPath: "/Users/test/Downloads")
        let second = DiskScanScope(rootPath: "/Volumes/Backup/Downloads")
        #expect(first.key.hasPrefix("Downloads-"))
        #expect(first.key != second.key)
        #expect(first.key == DiskScanScope(rootPath: "/Users/test/Downloads").key)
        #expect(DiskScanScope(rootPath: "/").key.hasPrefix("root-"))
        let volume = DiskScanScope(rootPath: "/", alsoEnters: ["/System/Volumes/Data"], excludedPaths: ["/System/Volumes"])
        #expect(volume.key != DiskScanScope(rootPath: "/").key)
        #expect(volume.relativePath("/Users/test") == "Users/test")
        #expect(first.relativePath("/Users/test/Downloads/a/b") == "a/b")
        #expect(first.relativePath("/Users/test/Downloads") == "")
        #expect(first.relativePath("/Users/test/DownloadsOld/a") == nil)
    }
}

struct DiskScanHistoryTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("otm-scans-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func savesAndReadsBackNewestFirst() throws {
        let history = DiskScanHistory(folder: folder())
        defer { try? FileManager.default.removeItem(at: history.folder) }
        let first = summary([("", 100), ("A", 100)], at: 1_000)
        let second = summary([("", 300), ("A", 300)], unlisted: ["A": 20], unreadable: ["A/locked"], at: 2_000)
        try history.save(first)
        try history.save(second)
        #expect(history.summaries(of: scope) == [second, first])
        #expect(history.summaries(of: DiskScanScope(rootPath: "/elsewhere")).isEmpty)
    }

    @Test func keepsOnlyTheLastScansOfEachScope() throws {
        let history = DiskScanHistory(folder: folder())
        defer { try? FileManager.default.removeItem(at: history.folder) }
        for index in 1...(DiskScanHistory.keptPerScope + 3) {
            try history.save(summary([("", UInt64(index))], at: TimeInterval(index * 60)))
        }
        let kept = history.summaries(of: scope)
        #expect(kept.count == DiskScanHistory.keptPerScope)
        #expect(kept.first?.allocatedSize == UInt64(DiskScanHistory.keptPerScope + 3))
        #expect(kept.last?.allocatedSize == 4)
    }

    @Test func forgettingAScopeLeavesTheOthers() throws {
        let history = DiskScanHistory(folder: folder())
        defer { try? FileManager.default.removeItem(at: history.folder) }
        let elsewhere = DiskScanScope(rootPath: "/elsewhere")
        let root = DiskScanSummary.Folder(name: "", parent: -1, allocatedSize: 9, logicalSize: 9, itemCount: 1)
        let other = DiskScanSummary(scope: elsewhere, scannedAt: Date(timeIntervalSince1970: 500), folders: [root])
        try history.save(summary([("", 100)], at: 1_000))
        try history.save(summary([("", 200)], at: 2_000))
        try history.save(other)
        try history.forget(scope)
        #expect(history.summaries(of: scope).isEmpty)
        #expect(history.summaries(of: elsewhere) == [other])
        // Nothing saved is nothing to do.
        try history.forget(scope)
    }

    @Test func skipsCorruptAndNewerFiles() throws {
        let history = DiskScanHistory(folder: folder())
        defer { try? FileManager.default.removeItem(at: history.folder) }
        let good = summary([("", 100)], at: 1_000)
        let url = try history.save(good)
        let scopeFolder = url.deletingLastPathComponent()
        try Data("not json".utf8).write(to: scopeFolder.appendingPathComponent("000000000002000.json"))
        var future = String(decoding: try DiskScanHistory.encode(good), as: UTF8.self)
        future = future.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        try Data(future.utf8).write(to: scopeFolder.appendingPathComponent("000000000003000.json"))
        #expect(history.summaries(of: scope) == [good])
    }

    @Test func decodingTellsCorruptFromNewer() throws {
        #expect(throws: DiskScanHistoryError.corrupt) { try DiskScanHistory.decode(Data("{}".utf8)) }
        #expect(throws: DiskScanHistoryError.corrupt) { try DiskScanHistory.decode(Data([0xFF, 0x00])) }
        #expect(throws: DiskScanHistoryError.newerVersion(7)) { try DiskScanHistory.decode(Data("{\"version\":7}".utf8)) }
        // The right version, but a folder pointing at one after it.
        let broken = DiskScanSummary(scope: scope, scannedAt: Date(), folders: [
            DiskScanSummary.Folder(name: "", parent: -1, allocatedSize: 10, logicalSize: 10, itemCount: 1),
            DiskScanSummary.Folder(name: "a", parent: 2, allocatedSize: 5, logicalSize: 5, itemCount: 1),
        ])
        #expect(throws: DiskScanHistoryError.corrupt) { try DiskScanHistory.decode(try DiskScanHistory.encode(broken)) }
        // And a good one survives the trip unchanged.
        let good = summary([("", 300), ("A", 300), ("A/b", 200)], files: [("A/b/c.bin", 150)], unlisted: ["A": 20],
                           unreadable: ["A/locked"], packages: ["A/b"], cutoff: 9, at: 1_234.5)
        #expect(try DiskScanHistory.decode(try DiskScanHistory.encode(good)) == good)
    }

    @Test func changesReadWithTheirSign() {
        #expect(Format.byteChange(200 * 1_048_576) == "+200 MB")
        #expect(Format.byteChange(-1_536 * 1_048_576) == "\u{2212}1.50 GB")
        #expect(Format.byteChange(0) == "0 B")
        #expect(Format.byteChange(500 * 1_048_576, grew: true, exact: false) == "+500 MB or more")
        #expect(Format.byteChange(2_048, grew: false, exact: true) == "\u{2212}2.00 KB")
        // Estimates from a saved scan.
        #expect(Format.bytes(DiskSizeEstimate.exact(735 * 1_048_576)) == "735 MB")
        #expect(Format.bytes(DiskSizeEstimate.atMost(6 * 1_048_576)) == "at most 6.00 MB")
        #expect(Format.bytes(DiskSizeEstimate(low: 10 * 1_048_576, high: 20 * 1_048_576)) == "10.0 MB\u{2013}20.0 MB")
        #expect(Format.bytes(DiskSizeEstimate(low: 40 * 1_048_576, high: .max)) == "40.0 MB or more")
        #expect(Format.bytes(DiskSizeEstimate.unknown) == "unknown")
    }

    @Test func fileNamesSortByTime() {
        #expect(DiskScanHistory.fileName(for: Date(timeIntervalSince1970: 1)) == "000000000001000.json")
        #expect(DiskScanHistory.fileName(for: Date(timeIntervalSince1970: 9)) < DiskScanHistory.fileName(for: Date(timeIntervalSince1970: 10)))
    }
}
