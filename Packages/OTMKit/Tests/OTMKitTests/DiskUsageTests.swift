import Foundation
@testable import OTMKit
import Testing

struct DiskCategoryTests {
    let rules = DiskCategoryRules(home: "/Users/test")

    @Test func typesMapToCategories() {
        let expected: [String: DiskCategory] = [
            "com.apple.quicktime-movie": .media,
            "public.heic": .media,
            "public.mp3": .audio,
            "com.apple.coreaudio-format": .audio,
            "com.adobe.pdf": .documents,
            "org.openxmlformats.wordprocessingml.document": .documents,
            "public.plain-text": .documents,
            "public.zip-archive": .archives,
            "com.apple.disk-image-udif": .archives,
            "com.apple.disk-image-sparse-bundle": .archives,
            "public.swift-source": .developer,
            "public.python-script": .developer,
            "public.object-code": .developer,
            "com.apple.xcode.project": .developer,
            "com.apple.application-bundle": .apps,
            "com.apple.log": .caches,
            "com.apple.photos.library": .media,
            "com.apple.property-list": .other,
            "public.folder": .other,
            "dyn.ah62d4rv4ge80k2py": .other,
        ]
        for (identifier, category) in expected {
            #expect(DiskCategoryRules.category(forType: identifier, size: 0) == category, "\(identifier)")
        }
        #expect(DiskCategoryRules.category(forType: nil) == .other)
    }

    @Test func smallTransportStreamsAreTypeScript() {
        #expect(DiskCategoryRules.category(forType: "public.mpeg-2-transport-stream", size: 4_000) == .developer)
        #expect(DiskCategoryRules.category(forType: "public.mpeg-2-transport-stream", size: 400_000_000) == .media)
    }

    @Test func foldersDecideForEverythingInside() {
        let expected: [String: DiskRegion] = [
            "/Users/test": .byType,
            "/Users/test/Documents/Taxes": .byType,
            "/Users/test/Library": .fallback(.system),
            "/Users/test/Library/Application Support/Foo": .fallback(.system),
            "/Users/test/Library/Caches/com.example.app": .fixed(.caches),
            "/Users/test/Library/Logs/DiagnosticReports": .fixed(.caches),
            "/Users/test/Library/Containers/com.example/Data/Library/Caches": .fixed(.caches),
            "/Users/test/Library/Developer/Xcode/DerivedData/App-abc": .fixed(.developer),
            "/Users/test/Library/Mobile Documents/com~apple~CloudDocs": .byType,
            "/Users/test/Projects/site/node_modules/react": .fixed(.developer),
            "/Users/test/Projects/site/.git/objects": .fixed(.developer),
            "/Users/other/Library": .fallback(.system),
            "/Applications": .fixed(.apps),
            "/System/Library/Frameworks": .fixed(.system),
            "/System/Library/Caches": .fixed(.caches),
            "/Library/Application Support": .fallback(.system),
            "/Library/Logs": .fixed(.caches),
            "/usr/lib": .fixed(.system),
            "/usr/local/Cellar": .fixed(.developer),
            "/opt/homebrew/bin": .fixed(.developer),
            "/private/var/log": .fixed(.caches),
            "/private/var/db": .fixed(.system),
        ]
        for (path, region) in expected {
            #expect(rules.region(at: path) == region, "\(path)")
        }
    }

    @Test func innermostFolderRuleWins() {
        // A cache inside a project inside the Library: the innermost folder decides.
        #expect(rules.region(at: "/Users/test/Library/Caches/tool/node_modules") == .fixed(.developer))
        #expect(rules.region(at: "/Users/test/Projects/site/node_modules/pkg/.cache") == .fixed(.caches))
    }

    @Test func regionsApplyToFileTypes() {
        // A support folder absorbs data and documents but not media, installers or apps.
        #expect(DiskCategoryRules.category(ofType: .media, in: .fallback(.system)) == .media)
        #expect(DiskCategoryRules.category(ofType: .archives, in: .fallback(.system)) == .archives)
        #expect(DiskCategoryRules.category(ofType: .documents, in: .fallback(.system)) == .system)
        #expect(DiskCategoryRules.category(ofType: .other, in: .fallback(.system)) == .system)
        #expect(DiskCategoryRules.category(ofType: .media, in: .fixed(.caches)) == .caches)
        #expect(DiskCategoryRules.category(ofType: .documents, in: .byType) == .documents)
    }

    @Test func packagesClassifyTheirContents() {
        #expect(DiskCategoryRules.region(insidePackage: .apps, in: .byType) == .fixed(.apps))
        #expect(DiskCategoryRules.region(insidePackage: .apps, in: .fallback(.system)) == .fixed(.apps))
        // Build products stay Developer; an unknown bundle keeps its folder's rule.
        #expect(DiskCategoryRules.region(insidePackage: .apps, in: .fixed(.developer)) == .fixed(.developer))
        #expect(DiskCategoryRules.region(insidePackage: .other, in: .fallback(.system)) == .fallback(.system))
    }
}

/// A folder of files with known sizes, removed when the test ends.
final class Fixture {
    let root: URL
    private let fileManager = FileManager.default

    init() throws {
        let folder = fileManager.temporaryDirectory.appendingPathComponent("otm-disk-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // The real path (/private/var, not /var), which is what scans report.
        root = URL(fileURLWithPath: try #require(realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }), isDirectory: true)
    }

    deinit {
        // Unlock anything a test locked, so it can be removed.
        if let paths = fileManager.enumerator(atPath: root.path) {
            for case let path as String in paths {
                try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
            }
        }
        try? fileManager.removeItem(at: root)
    }

    func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// Writes `size` non-zero bytes, so nothing is stored sparsely.
    @discardableResult
    func file(_ path: String, size: Int) throws -> URL {
        let url = url(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: size).write(to: url)
        return url
    }

    func folder(_ path: String) throws {
        try fileManager.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func allocated(_ path: String) throws -> UInt64 {
        let values = try url(path).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values.totalFileAllocatedSize ?? 0)
    }
}

struct DiskUsageScannerTests {
    private func scan(_ fixture: Fixture, configure: (inout DiskScanRequest) -> Void = { _ in }) throws -> DiskUsage {
        var request = DiskScanRequest(root: fixture.root)
        // The fixture sits in /private/var/folders, which is otherwise Caches & Logs.
        request.rootRegion = .byType
        configure(&request)
        return try #require(DiskUsageScanner.scan(request))
    }

    @Test func addsUpFilesAndFolders() throws {
        let fixture = try Fixture()
        try fixture.file("movie.mov", size: 300_000)
        try fixture.file("notes.txt", size: 10_000)
        try fixture.file("Projects/site/node_modules/pkg/index.js", size: 50_000)
        let usage = try scan(fixture)

        #expect(usage.rootPath == fixture.root.path)
        #expect(usage.root.logicalSize == 360_000)
        #expect(usage.root.allocatedSize >= usage.root.logicalSize)
        #expect(usage.fileCount == 3)
        #expect(usage.folderCount == 4)
        #expect(usage.root.itemCount == 7)
        #expect(usage.unreadableFolders == 0)
        // Largest first.
        #expect(usage.children(of: usage.root).map(\.name) == ["movie.mov", "Projects", "notes.txt"])

        let modules = try #require(usage.item(atPath: "Projects/site/node_modules"))
        #expect(modules.category == .developer)
        #expect(usage.path(of: modules.id) == fixture.url("Projects/site/node_modules").path)
        #expect(usage.ancestry(of: modules.id).map(\.name) == [fixture.root.lastPathComponent, "Projects", "site", "node_modules"])
        #expect(usage.item(atPath: fixture.url("Projects/site").path)?.name == "site")
        #expect(usage.closestFolder(to: fixture.url("Projects/site/node_modules/pkg/index.js").path).name == "pkg")
        #expect(usage.closestItem(to: fixture.url("Projects/site/node_modules/pkg/index.js").path).name == "index.js")
        // Gone: the folder it was in.
        #expect(usage.closestItem(to: fixture.url("Projects/site/old.js").path, exists: false).name == "site")
        #expect(usage.closestItem(to: fixture.root.path).id == usage.root.id)

        let byCategory = Dictionary(uniqueKeysWithValues: usage.categories.map { ($0.category, $0.allocatedSize) })
        #expect(byCategory[.media] == (try fixture.allocated("movie.mov")))
        #expect(byCategory[.documents] == (try fixture.allocated("notes.txt")))
        #expect(byCategory[.developer] == (try fixture.allocated("Projects/site/node_modules/pkg/index.js")))
        #expect(usage.categories.map(\.allocatedSize).reduce(0, +) == usage.root.allocatedSize)
    }

    @Test func neverFollowsSymbolicLinks() throws {
        let outside = try Fixture()
        try outside.file("huge.bin", size: 2_000_000)
        let fixture = try Fixture()
        try fixture.file("small.txt", size: 1_000)
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(at: fixture.url("file-link"), withDestinationURL: outside.url("huge.bin"))
        try fileManager.createSymbolicLink(at: fixture.url("folder-link"), withDestinationURL: outside.root)
        let usage = try scan(fixture)

        // The links count as themselves (a few bytes each), never what they point at.
        #expect(usage.root.logicalSize < 1_000 + 1_024)
        #expect(usage.largestFiles.allSatisfy { !$0.path.contains("huge.bin") })
        let link = try #require(usage.item(atPath: "folder-link"))
        #expect(link.kind == .file)
        #expect(link.children.isEmpty)
    }

    @Test func countsHardLinksOnce() throws {
        let fixture = try Fixture()
        let original = try fixture.file("a/original.bin", size: 200_000)
        try fixture.folder("b")
        try FileManager.default.linkItem(at: original, to: fixture.url("b/second-name.bin"))
        let usage = try scan(fixture)

        #expect(usage.root.logicalSize == 200_000)
        #expect(usage.root.allocatedSize == (try fixture.allocated("a/original.bin")))
        #expect(usage.hardLinkDuplicates == 1)
        #expect(usage.fileCount == 2)
        #expect(usage.largestFiles.count == 1)
    }

    @Test func keepsAPackageAsOneItem() throws {
        let fixture = try Fixture()
        try fixture.file("Tool.app/Contents/MacOS/Tool", size: 100_000)
        try fixture.file("Tool.app/Contents/Info.plist", size: 2_000)
        try fixture.file("loose.zip", size: 5_000)
        let usage = try scan(fixture)

        let app = try #require(usage.item(atPath: "Tool.app"))
        #expect(app.kind == .package)
        #expect(!app.isFolder)
        #expect(app.children.isEmpty)
        #expect(app.logicalSize == 102_000)
        #expect(app.itemCount == 4)
        #expect(app.category == .apps)
        // The package is listed among the largest files; its insides aren't.
        #expect(usage.largestFiles.first?.path == fixture.url("Tool.app").path)
        #expect(usage.largestFiles.first?.isPackage == true)
        #expect(usage.largestFiles.allSatisfy { !$0.path.contains("Contents") })
        #expect(usage.categories.first?.category == .apps)
    }

    @Test func foldsSmallChildrenIntoOneRow() throws {
        let fixture = try Fixture()
        for index in 1...8 {
            try fixture.file("many/file\(index).bin", size: index * 4_096)
        }
        let usage = try scan(fixture) { $0.childLimit = 5 }

        let many = try #require(usage.item(atPath: "many"))
        let children = usage.children(of: many)
        #expect(children.count == 6)
        #expect(children.prefix(5).map(\.name) == ["file8.bin", "file7.bin", "file6.bin", "file5.bin", "file4.bin"])
        let rest = try #require(children.last)
        #expect(rest.kind == .smallerItems)
        #expect(rest.itemCount == 3)
        #expect(rest.logicalSize == UInt64((1 + 2 + 3) * 4_096))
        // Nothing is lost: the rows add up to the folder.
        #expect(children.map(\.logicalSize).reduce(0, +) == many.logicalSize)
        #expect(children.map(\.allocatedSize).reduce(0, +) == many.allocatedSize)
    }

    @Test func keepsOnlyTheLargestFiles() throws {
        let fixture = try Fixture()
        for index in 1...6 {
            try fixture.file("folder\(index % 2)/file\(index).bin", size: index * 10_000)
        }
        let usage = try scan(fixture) { $0.largestFileLimit = 3 }
        #expect(usage.largestFiles.map(\.name) == ["file6.bin", "file5.bin", "file4.bin"])
        #expect(usage.largestFiles.first?.folder == fixture.url("folder0").path)
        // Anything missing is no bigger than the smallest kept.
        #expect(usage.largestFilesCutoff == (try fixture.allocated("folder0/file4.bin")))
        // With room for every file, nothing is missing.
        #expect(try scan(fixture) { $0.largestFileLimit = 10 }.largestFilesCutoff == 0)
    }

    @Test func dropsSmallFoldersContentsWhenOverBudget() throws {
        let fixture = try Fixture()
        try fixture.file("big/large.bin", size: 2_000_000)
        try fixture.file("big/inner/medium.bin", size: 1_500_000)
        for folder in 1...10 {
            for file in 1...3 {
                try fixture.file("small\(folder)/tiny\(file).txt", size: 100)
            }
        }
        let usage = try scan(fixture) { $0.nodeBudget = 30 }

        #expect(usage.detailThreshold == 1 << 20)
        #expect(usage.root.logicalSize == 3_500_000 + 3_000)
        for folder in 1...10 {
            let small = try #require(usage.item(atPath: "small\(folder)"))
            #expect(small.contentsOmitted)
            #expect(small.children.isEmpty)
            #expect(small.itemCount == 3)
        }
        // Folders above the threshold keep their contents.
        #expect(usage.item(atPath: "big/inner/medium.bin") != nil)
        #expect(usage.item(atPath: "big")?.contentsOmitted == false)
        #expect(usage.items.count <= 30)
    }

    @Test func countsFoldersItCannotRead() throws {
        let fixture = try Fixture()
        try fixture.file("open/readable.txt", size: 1_000)
        try fixture.file("locked/secret.txt", size: 1_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.url("locked").path)
        let usage = try scan(fixture)

        #expect(usage.unreadableFolders == 1)
        #expect(usage.unreadablePaths == [fixture.url("locked").path])
        #expect(usage.item(atPath: "locked")?.isUnreadable == true)
        #expect(usage.item(atPath: "open")?.isUnreadable == false)
        #expect(usage.root.logicalSize == 1_000)
        // Counted in the folder and every folder holding it.
        #expect(usage.item(atPath: "locked")?.unreadableCount == 1)
        #expect(usage.item(atPath: "open")?.unreadableCount == 0)
        #expect(usage.root.unreadableCount == 1)
    }

    @Test func stopsWhenCancelled() throws {
        let fixture = try Fixture()
        for index in 0..<1_200 {
            try fixture.file("bulk/\(index % 10)/\(index).txt", size: 1)
        }
        var checks = 0
        // The scan looks every few hundred files; give up at the second look.
        let usage = DiskUsageScanner.scan(DiskScanRequest(root: fixture.root), isCancelled: {
            checks += 1
            return checks > 1
        })
        #expect(usage == nil)
        #expect(checks == 2)
    }

    @Test func cancellingTheTaskThrows() async throws {
        let fixture = try Fixture()
        try fixture.file("a.txt", size: 10)
        let request = DiskScanRequest(root: fixture.root)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await DiskUsageScanner.scan(request)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // And left alone, the same request finishes.
        let usage = try await DiskUsageScanner.scan(request)
        #expect(usage.root.logicalSize == 10)
    }

    @Test func startupVolumeSkipsTheDataVolumeMountedInside() {
        let request = DiskScanRequest.volume(mountPoint: "/", isRoot: true)
        #expect(request.excludedPaths == ["/System/Volumes"])
        #expect(request.alsoEnters.map(\.path) == ["/System/Volumes/Data"])
        let external = DiskScanRequest.volume(mountPoint: "/Volumes/Backup", isRoot: false)
        #expect(external.excludedPaths.isEmpty && external.alsoEnters.isEmpty)
    }
}
