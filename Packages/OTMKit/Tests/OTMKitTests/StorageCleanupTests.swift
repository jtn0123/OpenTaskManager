import Foundation
@testable import OTMKit
import Testing

/// Fixtures are created under a unique temporary folder and never recycled or deleted by a test.
private struct CleanupFixture {
    let root: URL
    var home: String { root.appendingPathComponent("home").path }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otm-cleanup-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func file(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 8192).write(to: url)
        return url.path
    }

    func pick(_ path: String) throws -> StorageCleanupPick {
        let state = StorageCleanupReader.read(path, mounts: [], home: home)
        let identity = try #require(state.identity)
        return StorageCleanupPick(path: path, identity: identity, allocated: try #require(state.allocated),
                                  logical: try #require(state.logical), modified: state.modified, scannedAt: Date(), isFolder: state.isFolder)
    }
}

private let cleanupHome = "/fixture/home"

private func cleanupState() -> StorageCleanupState {
    var state = StorageCleanupState()
    state.exists = true
    state.identity = StorageFileIdentity(volume: "volume", file: "file")
    state.allocated = 8192
    state.logical = 4096
    state.modified = Date(timeIntervalSince1970: 100)
    state.readable = true
    state.owned = true
    state.local = true
    state.resolvedPath = cleanupHome + "/Downloads/test.bin"
    return state
}

private func cleanupPick(_ path: String = cleanupHome + "/Downloads/test.bin", folder: Bool = false,
                         identity: StorageFileIdentity? = StorageFileIdentity(volume: "volume", file: "file")) -> StorageCleanupPick {
    StorageCleanupPick(path: path, identity: identity, allocated: 8192, logical: 4096,
                       modified: Date(timeIntervalSince1970: 100), scannedAt: Date(timeIntervalSince1970: 200), isFolder: folder)
}

struct StorageCleanupRulesTests {
    @Test func standardFoldersAndTheirParentsAreNeverOffered() {
        for path in [cleanupHome, "/fixture"] + StorageCleanupRules.standardFolders.map({ cleanupHome + "/" + $0 }) {
            var state = cleanupState()
            state.resolvedPath = path
            #expect(StorageCleanupRules.refusal(path: path, state: state, home: cleanupHome) != nil)
        }
        #expect(StorageCleanupRules.refusal(path: cleanupHome + "/Downloads/test.bin", state: cleanupState(), home: cleanupHome) == nil)
    }

    @Test func protectionUsesPathComponentsAndKeepsTheHomeException() {
        for path in ["/System/a", "/usr/bin/a", "/bin/a", "/sbin/a", "/Library/Caches/a",
                     cleanupHome + "/Library/Containers/a", cleanupHome + "/Library/Group Containers/a",
                     "/Applications/Test.app/Contents/test"] {
            #expect(StorageCleanupRules.protectedLocation(path, home: cleanupHome))
        }
        for path in ["/Systematic/a", "/usr-local/a", cleanupHome + "/Library/Caches/a",
                     cleanupHome + "/Library/Containers-copy/a", "/Applications/Test.app"] {
            #expect(!StorageCleanupRules.protectedLocation(path, home: cleanupHome))
        }
        #expect(!StorageCleanupRules.protectedLocation("/Library/UserHome/Library/Caches/a", home: "/Library/UserHome"))
    }

    @Test func refusalsCannotBeSelectedEvenWhenTheCallerTicksThem() {
        let path = cleanupHome + "/Downloads/test.bin"
        let mutations: [(inout StorageCleanupState) -> Void] = [
            { $0.exists = false }, { $0.identity = nil }, { $0.mountPoint = true }, { $0.containsMount = true },
            { $0.readOnly = true }, { $0.symbolicLink = true }, { $0.resolvedPath = cleanupHome + "/Desktop" },
        ]
        for mutation in mutations {
            var state = cleanupState()
            mutation(&state)
            let item = StorageCleanupItem(pick: cleanupPick(), state: state, home: cleanupHome)
            #expect(item.refusal != nil)
            #expect(!item.preselected)
            #expect(StorageCleanupText.selected([item], selection: [path]).hasPrefix("Selected: 0 B allocated"))
        }
    }

    @Test func warningsStartUntickedButAnUnchangedFileStartsTicked() {
        #expect(StorageCleanupItem(pick: cleanupPick(), state: cleanupState(), home: cleanupHome).preselected)
        let mutations: [(inout StorageCleanupState) -> Void] = [
            { $0.owned = false }, { $0.readable = false }, { $0.local = false }, { $0.placeholder = true },
            { $0.resolvedPath = "/Library/Caches/test.bin" }, { $0.allocated = nil },
        ]
        for mutation in mutations {
            var state = cleanupState()
            mutation(&state)
            let item = StorageCleanupItem(pick: cleanupPick(), state: state, home: cleanupHome)
            #expect(!item.preselected)
            #expect(!item.warnings.isEmpty)
        }
    }

    @Test func identitySizeAndDateChangesAreIndependent() {
        #expect(!StorageCleanupRules.changed(cleanupPick(), cleanupState()))
        let mutations: [(inout StorageCleanupState) -> Void] = [
            { $0.identity = StorageFileIdentity(volume: "other", file: "file") },
            { $0.identity = StorageFileIdentity(volume: "volume", file: "replacement") },
            { $0.allocated = 4096 }, { $0.logical = 2048 }, { $0.modified = Date(timeIntervalSince1970: 101) },
            { $0.modified = nil }, { $0.isFolder = true },
        ]
        for mutation in mutations {
            var state = cleanupState()
            mutation(&state)
            #expect(StorageCleanupRules.changed(cleanupPick(), state))
        }
        #expect(StorageCleanupRules.changed(cleanupPick(identity: nil), cleanupState()))
        let future = StorageCleanupPick(path: "future", identity: cleanupState().identity, allocated: 8192, logical: 4096,
                                        modified: cleanupState().modified, scannedAt: Date(timeIntervalSince1970: 90), isFolder: false)
        #expect(StorageCleanupRules.changed(future, cleanupState()))
    }

    @Test func collapseKeepsTheOuterFolderAndCountsEveryPickedDescendant() {
        let folder = cleanupPick("/fixture/work", folder: true)
        let nested = cleanupPick("/fixture/work/build", folder: true)
        let file = cleanupPick("/fixture/work/build/file")
        let sibling = cleanupPick("/fixture/work-other/file")
        let collapsed = StorageCleanupRules.collapse([file, nested, folder, sibling, file])
        #expect(collapsed.map(\.pick.path) == [folder.path, sibling.path])
        #expect(collapsed.first?.included == 2)
        let item = StorageCleanupItem(pick: folder, state: cleanupState(), includedPicks: 2, home: cleanupHome)
        #expect(item.includesText == "Includes 2 picked items inside it")
        #expect(StorageCleanupItem(pick: folder, state: cleanupState(), includedPicks: 1, home: cleanupHome).includesText
            == "Includes 1 picked item inside it")
    }

    @Test func totalsCountOnlyTickedItemsAndCountHardLinksOnce() {
        let first = StorageCleanupItem(pick: cleanupPick(), state: cleanupState(), home: cleanupHome)
        let second = StorageCleanupItem(pick: cleanupPick("/fixture/second"), state: cleanupState(), home: cleanupHome)
        let text = StorageCleanupText.selected([first, second], selection: [first.id, second.id])
        #expect(text == "Selected: \(Format.bytes(8192 as UInt64)) allocated · space you get back may be less "
            + "(clones, hard links and snapshots can keep blocks)")
        #expect(StorageCleanupText.selected([first], selection: []).hasPrefix("Selected: 0 B allocated"))
        var state = cleanupState()
        state.allocated = nil
        let unknown = StorageCleanupItem(pick: cleanupPick("/fixture/unknown"), state: state, home: cleanupHome)
        #expect(StorageCleanupText.selected([unknown], selection: [unknown.id]).hasPrefix("Selected: at least 0 B allocated"))
        #expect(StorageCleanupText.capacityChange(before: 1000, after: 1100) == "Volume available space changed by +100 B")
        #expect(StorageCleanupText.capacityChange(before: 1100, after: 1000) == "Volume available space changed by −100 B")
        #expect(StorageCleanupText.capacityChange(before: 1000, after: 1000) == "Volume available space changed by +0 B")
        #expect(StorageCleanupText.capacityChange(before: nil, after: 1000) == "Volume available space change couldn't be measured.")
    }

    @Test func commandAndShiftSelectionFollowTheListOrder() {
        let order = ["first", "second", "third", "last"]
        let initial = StorageCleanupRules.select("second", order: order, current: .init(paths: ["tile"]), command: false, shift: false)
        #expect(initial.paths == ["second"])
        #expect(initial.anchor == "second")
        let added = StorageCleanupRules.select("last", order: order, current: .init(paths: ["tile", "second"], anchor: "second"),
                                              command: true, shift: true)
        #expect(added.paths == ["tile", "second", "third", "last"])
        #expect(added.anchor == "second")
        let reverse = StorageCleanupRules.select("first", order: order, current: .init(paths: added.paths, anchor: "third"),
                                                command: false, shift: true)
        #expect(reverse.paths == ["first", "second", "third"])
        let toggled = StorageCleanupRules.select("second", order: order, current: initial, command: true, shift: false)
        #expect(toggled.paths.isEmpty)
        let invalid = StorageCleanupRules.select("absent", order: order, current: added, command: false, shift: false)
        #expect(invalid == added)
    }

    @Test func anotherChangeAfterReviewNeedsAnotherReview() {
        let item = StorageCleanupItem(pick: cleanupPick(), state: cleanupState(), home: cleanupHome)
        #expect(StorageCleanupRules.revalidationFailure(item, now: item.state, home: cleanupHome) == nil)
        var now = item.state
        now.owned = false
        #expect(StorageCleanupRules.revalidationFailure(item, now: now, home: cleanupHome) != nil)
        now = item.state
        now.resolvedPath = cleanupHome
        #expect(StorageCleanupRules.revalidationFailure(item, now: now, home: cleanupHome) != nil)
    }
}

@MainActor
private final class FakeCleanupRecycler: StorageCleanupRecycler {
    var paths: [String] = []

    func recycle(_ path: String) async -> RemovalResult {
        paths.append(path)
        return path.hasSuffix("failed.bin") ? .failed("Fake failure") : .moved(to: "fake-trash")
    }
}

struct StorageCleanupReaderTests {
    @Test func scannerAndReviewAgreeOnIdentityAndFolderTotals() throws {
        let fixture = try CleanupFixture()
        let path = try fixture.file("work/file.bin")
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        let usage = try #require(DiskUsageScanner.scan(DiskScanRequest(root: folder), isCancelled: { false }))
        let file = try #require(usage.largestFiles.first)
        let current = StorageCleanupReader.read(path, mounts: [], home: fixture.home)
        #expect(file.identity != nil)
        #expect(file.identity == current.identity)
        #expect(usage.root.identity == StorageCleanupReader.read(folder.path, mounts: [], home: fixture.home).identity)
        let pick = try fixture.pick(folder.path)
        let child = try fixture.pick(path)
        let review = StorageCleanupReader.review([pick, child], home: fixture.home)
        #expect(review.count == 1)
        #expect(review.first?.includedPicks == 1)
        #expect(review.first?.state.itemCount == 1)
        #expect(review.first?.state.allocated == file.allocatedSize)
        #expect(review.first?.preselected == true)
    }

    @Test @MainActor func fakeRecyclerReportsEachItemWithoutMovingAnything() async throws {
        let fixture = try CleanupFixture()
        let paths = try [fixture.file("good.bin"), fixture.file("failed.bin")]
        let picks = try paths.map(fixture.pick)
        let review = StorageCleanupReader.review(picks, home: fixture.home)
        let recycler = FakeCleanupRecycler()
        let execution = await StorageCleanupExecution.run(review, selection: Set(paths), home: fixture.home, recycler: recycler)
        #expect(Set(recycler.paths) == Set(paths))
        #expect(execution.outcomes.filter(\.result.succeeded).count == 1)
        #expect(execution.outcomes.contains { $0.result == .failed("Fake failure") })
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(execution.measurements.count == 1)
    }

    @Test @MainActor func replacedFileAndRefusedFolderNeverReachTheRecycler() async throws {
        let fixture = try CleanupFixture()
        let path = try fixture.file("replaced.bin")
        let pick = try fixture.pick(path)
        let review = StorageCleanupReader.review([pick], home: fixture.home)
        try FileManager.default.moveItem(atPath: path, toPath: path + ".saved")
        try Data(repeating: 7, count: 8192).write(to: URL(fileURLWithPath: path))
        let recycler = FakeCleanupRecycler()
        let execution = await StorageCleanupExecution.run(review, selection: [path], home: fixture.home, recycler: recycler)
        #expect(recycler.paths.isEmpty)
        #expect(execution.outcomes.first?.result.succeeded == false)
        let folder = fixture.root.appendingPathComponent("home/Downloads").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let refusedPick = StorageCleanupPick(path: folder, identity: nil, allocated: 0, logical: 0,
                                             modified: nil, scannedAt: Date(), isFolder: true)
        let refused = StorageCleanupReader.review([refusedPick], home: fixture.home)
        let blocked = await StorageCleanupExecution.run(refused, selection: [folder], home: fixture.home, recycler: recycler)
        #expect(recycler.paths.isEmpty)
        #expect(blocked.outcomes.first?.result.succeeded == false)
    }

    @Test func anAliasToAStandardFolderIsRefused() throws {
        let fixture = try CleanupFixture()
        let standard = fixture.root.appendingPathComponent("home/Desktop")
        try FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: standard)
        let state = StorageCleanupReader.read(link.path, mounts: [], home: fixture.home)
        #expect(state.symbolicLink)
        #expect(StorageCleanupRules.refusal(path: link.path, state: state, home: fixture.home) != nil)
    }
}
