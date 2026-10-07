import Foundation
@testable import OTMKit
import Testing

// MARK: - Fixtures

/// A throwaway home folder, /Library and Applications folder under the
/// temporary directory, so no test reads or changes the real ones.
private final class FakeMac {
    let root: String
    var home: String { root + "/home" }
    var library: String { root + "/Library" }
    var applications: String { root + "/Applications" }

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otm-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolved, so /var/folders becomes /private/var/folders like the paths the code builds.
        root = base.resolvingSymlinksInPath().path
        for folder in [home + "/Library", library, applications] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    /// Creates an empty file, or a folder when the name ends in "/", relative to the fake home's Library.
    @discardableResult
    func homeItem(_ relative: String, bytes: Int = 0) throws -> String {
        try item(home + "/Library/" + relative, bytes: bytes)
    }

    @discardableResult
    func item(_ path: String, bytes: Int = 0) throws -> String {
        let manager = FileManager.default
        if path.hasSuffix("/") {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            return String(path.dropLast())
        }
        try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// A bundle with an Info.plist and an executable, like the VM's test app.
    func bundle(_ name: String, identifier: String, extraInfo: [String: Any] = [:]) throws -> String {
        let path = applications + "/" + name + ".app"
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "tool"]
        info.merge(extraInfo) { _, new in new }
        try item(path + "/Contents/MacOS/tool", bytes: 100)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return path
    }

    /// A launchd property list, read the way the Startup scan reads one.
    func launchAgent(_ label: String, program: String, folder: String? = nil, scope: LaunchItemScope = .userAgent) throws -> LaunchItem {
        let path = (folder ?? home + "/Library/LaunchAgents") + "/\(label).plist"
        let plist: [String: Any] = ["Label": label, "Program": program, "RunAtLoad": true]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try item(path)
        try data.write(to: URL(fileURLWithPath: path))
        return LaunchItems.item(plist: data, path: path, scope: scope)
    }
}

private func installed(_ path: String, id: String?, name: String? = nil, kind: AppKind = .thirdParty, team: String? = nil,
                       resolved: String? = nil) -> InstalledApp {
    let signature = team.map { CodeSignature(signer: .developerID, teamIdentifier: $0) } ?? .unknown
    return InstalledApp(path: path, resolvedPath: resolved ?? path,
                        name: name ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                        bundleIdentifier: id, version: "1.0", build: "1", minimumSystemVersion: nil,
                        executablePath: (resolved ?? path) + "/Contents/MacOS/tool", kind: kind, hasAppStoreReceipt: false,
                        isiOSApp: false, slices: nil, signature: signature, lastOpened: nil, added: nil)
}

private extension AppRemovalPlan {
    func item(_ suffix: String) -> LeftoverItem? { items.first { $0.path.hasSuffix(suffix) } }
    func protectedItem(_ suffix: String) -> ProtectedLeftover? { protected.first { $0.path.hasSuffix(suffix) } }
}

// MARK: - Who it's for

struct AppRemovalEligibilityTests {
    private let own = (identifier: "io.github.jtn0123.OpenTaskManager", path: "/Applications/OpenTaskManager.app")

    private func refusal(_ app: InstalledApp) -> String? {
        AppRemoval.refusal(for: app, ownBundleIdentifier: own.identifier, ownBundlePath: own.path)
    }

    @Test func offeredForThirdPartyAndAppStoreApps() {
        #expect(refusal(installed("/Applications/Tool.app", id: "com.example.tool")) == nil)
        #expect(refusal(installed("/Applications/Store.app", id: "com.example.store", kind: .appStore)) == nil)
        #expect(refusal(installed("/Users/me/Applications/NoID.app", id: nil)) == nil)
    }

    @Test func neverForAppleOrMacOS() {
        #expect(refusal(installed("/Applications/Pages.app", id: "com.apple.iWork.Pages", kind: .apple)) != nil)
        #expect(refusal(installed("/System/Applications/Chess.app", id: "com.apple.Chess", kind: .apple)) != nil)
        // Even when it doesn't look like Apple's, /System is macOS's.
        #expect(refusal(installed("/System/Library/CoreServices/Thing.app", id: "com.example.thing")) != nil)
        #expect(refusal(installed("/Applications/Safari.app", id: "com.example.safari",
                                  resolved: "/System/Cryptexes/App/System/Applications/Safari.app")) != nil)
        // An Apple bundle ID with someone else's signature is still left alone.
        #expect(refusal(installed("/Applications/Odd.app", id: "COM.APPLE.odd")) != nil)
    }

    @Test func neverForOpenTaskManager() {
        #expect(refusal(installed("/Users/me/Apps/OTM-copy.app", id: "io.github.jtn0123.opentaskmanager")) != nil)
        #expect(refusal(installed("/Applications/OpenTaskManager.app", id: nil)) != nil)
        #expect(refusal(installed("/System/Volumes/Data/Applications/OpenTaskManager.app", id: nil)) != nil)
    }
}

// MARK: - Matching rules

struct AppRemovalMatchingTests {
    private func rules(id: String?, name: String = "Paint Pro", team: String? = nil,
                       others: [InstalledApp] = []) -> AppRemoval.MatchRules {
        AppRemoval.MatchRules(app: installed("/Applications/\(name).app", id: id, name: name, team: team), others: others)
    }

    private func match(_ name: String, _ location: LeftoverLocation, _ rules: AppRemoval.MatchRules,
                       byHost: Bool = false) -> (LeftoverEvidence, LeftoverConfidence)? {
        rules.match(name, in: location, byHost: byHost).map { ($0.evidence, $0.confidence) }
    }

    @Test func exactBundleIDMatchesUseEachFoldersExtension() {
        let rules = rules(id: "com.example.Paint")
        #expect(match("com.example.Paint.plist", .preferences, rules)! == (.bundleIdentifier("com.example.Paint"), .exact))
        // Case doesn't matter: the file system ignores it, and so do bundle IDs.
        #expect(match("COM.EXAMPLE.PAINT", .caches, rules)! == (.bundleIdentifier("com.example.Paint"), .exact))
        #expect(match("com.example.Paint.savedState", .savedState, rules)!.1 == .exact)
        #expect(match("com.example.Paint", .httpStorages, rules)!.1 == .exact)
        #expect(match("com.example.Paint.binarycookies", .httpStorages, rules)!.1 == .exact)
        #expect(match("com.example.Paint", .containers, rules)!.1 == .exact)
        // An extension that isn't the folder's usual one is only a prefix match.
        #expect(match("com.example.Paint.plist", .caches, rules)! == (.bundleIdentifierPrefix("com.example.Paint"), .uncertain))
        #expect(match("com.example.Paint.binarycookies", .caches, rules)!.1 == .uncertain)
    }

    @Test func byHostPreferencesCarryTheHardwareUUID() {
        let rules = rules(id: "com.example.Paint")
        let host = "com.example.Paint.0A1B2C3D-1111-2222-3333-444455556666.plist"
        #expect(match(host, .preferences, rules, byHost: true)!.1 == .exact)
        #expect(match("com.example.Paint.helper.plist", .preferences, rules, byHost: true)!.1 == .uncertain)
        #expect(match("com.example.Painter.0A1B2C3D-1111.plist", .preferences, rules, byHost: true) == nil)
    }

    @Test func helpersAndExtensionsAreUncertain() {
        let rules = rules(id: "com.example.Paint")
        #expect(match("com.example.Paint.ShareExtension", .containers, rules)!
            == (.bundleIdentifierPrefix("com.example.Paint.ShareExtension"), .uncertain))
        #expect(match("com.example.Paint.helper.plist", .preferences, rules)!
            == (.bundleIdentifierPrefix("com.example.Paint.helper"), .uncertain))
        // The ID has to end where a dot starts: Painter isn't Paint.
        #expect(match("com.example.Painter", .caches, rules) == nil)
        #expect(match("com.example", .caches, rules) == nil)
    }

    @Test func anotherAppsFilesAreLeftOut() {
        let pro = installed("/Applications/Paint Pro X.app", id: "com.example.Paint.Pro")
        let rules = rules(id: "com.example.Paint", others: [pro])
        #expect(match("com.example.Paint.Pro.plist", .preferences, rules) == nil)
        #expect(match("com.example.Paint.Pro.helper", .caches, rules) == nil)
        #expect(match("com.example.Paint.helper", .caches, rules) != nil)
        // A folder named after another app's bundle ID isn't a name match either.
        let named = self.rules(id: "com.example.Paint", name: "com.example.other", others: [installed("/A.app", id: "com.example.other")])
        #expect(match("com.example.other", .applicationSupport, named) == nil)
    }

    @Test func nameMatchesAreUncertainAndOnlyWhereAppsUseNames() {
        let rules = rules(id: "com.example.Paint", name: "Paint Pro")
        #expect(match("Paint Pro", .applicationSupport, rules)! == (.appName("Paint Pro"), .uncertain))
        #expect(match("paint pro", .caches, rules)!.1 == .uncertain)
        #expect(match("Paint Pro", .logs, rules) != nil)
        #expect(match("Paint Pro", .preferences, rules) == nil)
        #expect(match("Paint Pro", .containers, rules) == nil)
        // The executable's name counts too.
        #expect(match("tool", .applicationSupport, rules) != nil)
        // Generic or very short names don't.
        #expect(match("Helper", .applicationSupport, self.rules(id: nil, name: "Helper")) == nil)
        #expect(match("Go", .applicationSupport, self.rules(id: nil, name: "Go")) == nil)
    }

    @Test func groupContainersAreAlwaysUncertain() {
        let rules = rules(id: "com.example.Paint", team: "ABCDE12345")
        #expect(match("ABCDE12345.shared", .groupContainers, rules)! == (.teamIdentifier("ABCDE12345"), .uncertain))
        #expect(match("abcde12345.com.example.suite", .groupContainers, rules)!.1 == .uncertain)
        #expect(match("group.com.example.Paint", .groupContainers, rules)! == (.appGroup("com.example.Paint"), .uncertain))
        #expect(match("group.com.example.Paint.sync", .groupContainers, rules)!.1 == .uncertain)
        #expect(match("com.example.Paint", .groupContainers, rules) == nil)
        #expect(match("ZZZZZ99999.shared", .groupContainers, rules) == nil)
        #expect(match("ABCDE12345.shared", .groupContainers, self.rules(id: "com.example.Paint")) == nil)
    }

    @Test func anIDWithoutADotIsNeverExact() {
        let rules = rules(id: "Paint")
        #expect(match("Paint", .caches, rules)! == (.bundleIdentifier("Paint"), .uncertain))
        #expect(match("Paint.cache", .caches, rules) == nil)
    }
}

// MARK: - Finding what goes with an app

struct AppRemovalPlanTests {
    @Test func findsTheBundleAndWhatsNamedAfterIt() throws {
        let mac = try FakeMac()
        let bundle = try mac.bundle("OTM Trash Test", identifier: "com.example.otmtrash")
        let app = installed(bundle, id: "com.example.otmtrash", name: "OTM Trash Test")
        try mac.homeItem("Preferences/com.example.otmtrash.plist", bytes: 10)
        try mac.homeItem("Preferences/ByHost/com.example.otmtrash.0A1B2C3D-1111-2222-3333-444455556666.plist")
        try mac.homeItem("Preferences/com.example.otmtrash.helper.plist")
        try mac.homeItem("Caches/com.example.otmtrash/")
        try mac.homeItem("Caches/com.example.otmtrash/Cache.db", bytes: 5000)
        try mac.homeItem("Caches/OTM Trash Test/")
        try mac.homeItem("Application Support/com.example.otmtrash/")
        try mac.homeItem("Containers/com.example.otmtrash/")
        try mac.homeItem("Saved Application State/com.example.otmtrash.savedState/")
        try mac.homeItem("HTTPStorages/com.example.otmtrash/")
        try mac.homeItem("HTTPStorages/com.example.otmtrash.binarycookies")
        try mac.homeItem("WebKit/com.example.otmtrash/")
        try mac.homeItem("Logs/com.example.otmtrash/")
        try mac.homeItem("Application Scripts/com.example.otmtrash/")
        // Not the app's.
        try mac.homeItem("Caches/com.example.otmtrashier/")
        try mac.homeItem("Caches/com.other.app/")
        try mac.homeItem("Caches/.com.example.otmtrash")
        try mac.homeItem("Application Support/Unrelated/")

        let plan = AppRemoval.plan(for: app, otherApps: [], launchItems: [], home: mac.home, systemLibrary: mac.library)
        #expect(plan.blocker == nil)
        #expect(plan.items.first?.path == bundle)
        #expect(plan.items.first?.confidence == .required)
        let library = mac.home + "/Library/"
        let exact = [
            "Preferences/com.example.otmtrash.plist",
            "Preferences/ByHost/com.example.otmtrash.0A1B2C3D-1111-2222-3333-444455556666.plist",
            "Application Support/com.example.otmtrash", "Caches/com.example.otmtrash", "Containers/com.example.otmtrash",
            "Application Scripts/com.example.otmtrash", "Saved Application State/com.example.otmtrash.savedState",
            "HTTPStorages/com.example.otmtrash", "HTTPStorages/com.example.otmtrash.binarycookies",
            "WebKit/com.example.otmtrash", "Logs/com.example.otmtrash",
        ].map { library + $0 }
        #expect(plan.items.filter { $0.confidence == .exact }.map(\.path) == exact)
        #expect(plan.items.filter(\.isUncertain).map(\.path)
            == [library + "Preferences/com.example.otmtrash.helper.plist", library + "Caches/OTM Trash Test"])
        #expect(plan.item("Caches/OTM Trash Test")?.evidence == .appName("OTM Trash Test"))
        #expect(plan.items.count == 1 + exact.count + 2)
        #expect(plan.preselected == Set([bundle] + exact))
        #expect(plan.protected.isEmpty)
        #expect(!plan.foundOnlyTheApp)
    }

    @Test func anAppWithNothingElseFindsOnlyItself() throws {
        let mac = try FakeMac()
        let bundle = try mac.bundle("Lonely", identifier: "com.example.lonely")
        try mac.homeItem("Caches/com.other.app/")
        let plan = AppRemoval.plan(for: installed(bundle, id: "com.example.lonely"), otherApps: [], launchItems: [],
                                   home: mac.home, systemLibrary: mac.library)
        #expect(plan.items.map(\.path) == [bundle])
        #expect(plan.foundOnlyTheApp)
        // Something in /Library counts, though it's only listed.
        try mac.item(mac.library + "/Preferences/com.example.lonely.plist")
        let shared = AppRemoval.plan(for: installed(bundle, id: "com.example.lonely"), otherApps: [], launchItems: [],
                                     home: mac.home, systemLibrary: mac.library)
        #expect(!shared.foundOnlyTheApp)
    }

    @Test func anotherCopyMakesExactMatchesUncertain() throws {
        let mac = try FakeMac()
        let bundle = try mac.bundle("Tool", identifier: "com.example.tool")
        let copy = installed(mac.home + "/Applications/Tool.app", id: "com.example.tool")
        try mac.homeItem("Preferences/com.example.tool.plist")
        let plan = AppRemoval.plan(for: installed(bundle, id: "com.example.tool"), otherApps: [copy],
                                   launchItems: [], home: mac.home, systemLibrary: mac.library)
        let preferences = try #require(plan.item("com.example.tool.plist"))
        #expect(preferences.confidence == .uncertain)
        #expect(preferences.caveat?.contains(copy.path) == true)
        // The same bundle listed twice (say, found through a link) isn't another copy.
        let same = AppRemoval.plan(for: installed(bundle, id: "com.example.tool"), otherApps: [installed(bundle, id: "com.example.tool")],
                                   launchItems: [], home: mac.home, systemLibrary: mac.library)
        #expect(same.item("com.example.tool.plist")?.confidence == .exact)
    }

    @Test func launchAgentsGoWithTheApp() throws {
        let mac = try FakeMac()
        let bundle = try mac.bundle("Sync", identifier: "com.example.sync")
        let helper = try mac.launchAgent("com.example.sync.helper", program: bundle + "/Contents/Library/LoginItems/Helper")
        let labelled = try mac.launchAgent("com.example.sync", program: "/usr/local/bin/sync-agent")
        let updater = try mac.launchAgent("com.example.sync.updater", program: "/usr/local/bin/updater")
        let daemon = try mac.launchAgent("com.example.sync.daemon", program: bundle + "/Contents/MacOS/daemon",
                                         folder: mac.library + "/LaunchDaemons", scope: .daemon)
        let unrelated = try mac.launchAgent("com.other.agent", program: "/usr/bin/true")
        let plan = AppRemoval.plan(for: installed(bundle, id: "com.example.sync"), otherApps: [],
                                   launchItems: [helper, labelled, updater, daemon, unrelated], home: mac.home, systemLibrary: mac.library)

        let agents = plan.items.filter { $0.location == .launchAgents }
        #expect(agents.map(\.launchItem) == [helper, labelled, updater])
        #expect(agents.map(\.confidence) == [.required, .exact, .uncertain])
        #expect(agents[0].evidence == .runsFromApp(program: bundle + "/Contents/Library/LoginItems/Helper"))
        #expect(agents[0].evidence.description(bundlePath: bundle) == "Runs Contents/Library/LoginItems/Helper from inside the app")
        #expect(agents[1].evidence == .launchLabel("com.example.sync"))
        // A daemon needs an administrator, even though it runs from the app.
        let protected = try #require(plan.protectedItem("com.example.sync.daemon.plist"))
        #expect(protected.reason.contains("daemon"))
        #expect(plan.items.allSatisfy { !$0.path.contains("LaunchDaemons") })
    }

    @Test func systemFilesAndHelpersAreOnlyListed() throws {
        let mac = try FakeMac()
        let bundle = try mac.bundle("Vault", identifier: "com.example.vault",
                                    extraInfo: ["SMPrivilegedExecutables": ["com.example.blessed": "anchor apple generic"]])
        try mac.item(mac.library + "/Application Support/com.example.vault/")
        try mac.item(mac.library + "/Application Support/Vault/")
        try mac.item(mac.library + "/Preferences/com.example.vault.plist")
        try mac.item(mac.library + "/PrivilegedHelperTools/com.example.blessed")
        try mac.item(mac.library + "/PrivilegedHelperTools/com.example.vault.helper")
        try mac.item(mac.library + "/PrivilegedHelperTools/com.other.helper")
        try mac.item(bundle + "/Contents/Library/SystemExtensions/com.example.vault.filter.systemextension/")

        let plan = AppRemoval.plan(for: installed(bundle, id: "com.example.vault"), otherApps: [], launchItems: [],
                                   home: mac.home, systemLibrary: mac.library)
        #expect(plan.items.map(\.path) == [bundle])
        let paths = plan.protected.map(\.path)
        #expect(paths.contains(mac.library + "/Application Support/com.example.vault"))
        #expect(paths.contains(mac.library + "/Application Support/Vault"))
        #expect(paths.contains(mac.library + "/Preferences/com.example.vault.plist"))
        #expect(plan.protectedItem("com.example.blessed")?.evidence == .privilegedHelper("com.example.blessed"))
        #expect(plan.protectedItem("com.example.vault.helper")?.reason.contains("Privileged helper") == true)
        #expect(plan.protectedItem("com.other.helper") == nil)
        #expect(plan.protectedItem(".systemextension")?.evidence == .insideApp)
    }

    @Test func whatThisAccountCantMoveIsProtected() throws {
        let mac = try FakeMac()
        let bundle = try mac.bundle("Locked", identifier: "com.example.locked")
        let caches = try mac.homeItem("Caches/com.example.locked/")
        let plan = AppRemoval.plan(for: installed(bundle, id: "com.example.locked"), otherApps: [], launchItems: [],
                                   home: mac.home, systemLibrary: mac.library, canRemove: { $0 != bundle && $0 != caches })
        #expect(plan.blocker != nil)
        #expect(plan.items.isEmpty)
        #expect(plan.protected.map(\.path) == [bundle, caches])
        #expect(plan.protected.first?.evidence == .theApp)
        #expect(!plan.foundOnlyTheApp)
    }

    @Test func aLinkToTheAppGoesToo() throws {
        let mac = try FakeMac()
        let bundle = try mac.bundle("Linked", identifier: "com.example.linked")
        let link = mac.home + "/Linked.app"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: bundle)
        let plan = AppRemoval.plan(for: installed(link, id: "com.example.linked", resolved: bundle), otherApps: [],
                                   launchItems: [], home: mac.home, systemLibrary: mac.library)
        #expect(plan.items.map(\.path) == [bundle, link])
        #expect(plan.items.map(\.evidence) == [.theApp, .linkToApp])
        #expect(plan.items.allSatisfy { $0.confidence == .required })
        #expect(plan.foundOnlyTheApp)
    }

    @Test func trashOrderUnloadsFirstThenTheBundle() throws {
        let mac = try FakeMac()
        let bundle = try mac.bundle("Order", identifier: "com.example.order")
        let agent = try mac.launchAgent("com.example.order.agent", program: bundle + "/Contents/MacOS/tool")
        try mac.homeItem("Caches/com.example.order/")
        let plan = AppRemoval.plan(for: installed(bundle, id: "com.example.order"), otherApps: [], launchItems: [agent],
                                   home: mac.home, systemLibrary: mac.library)
        // Reversed, to show the order doesn't depend on the selection's.
        let order = AppRemoval.trashOrder(plan.items.reversed())
        #expect(order.unload == [agent])
        #expect(order.app.map(\.path) == [bundle])
        #expect(order.rest.map(\.location) == [.caches, .launchAgents])
    }
}

// MARK: - Files, processes and launchd

struct AppRemovalSystemTests {
    @Test func canRemoveNeedsAWritableFolder() throws {
        let mac = try FakeMac()
        let file = try mac.homeItem("Caches/file", bytes: 1)
        let folder = try mac.homeItem("Caches/folder/")
        #expect(AppRemoval.canRemove(file))
        #expect(AppRemoval.canRemove(folder))
        #expect(!AppRemoval.canRemove(mac.home + "/Library/Caches/missing"))
        // A folder that isn't writable itself can't move, as with a root-owned bundle.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        #expect(!AppRemoval.canRemove(folder))
        // Nor can anything in a folder that isn't writable.
        let locked = try mac.homeItem("Caches/locked/")
        let inside = try mac.homeItem("Caches/locked/file")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        #expect(!AppRemoval.canRemove(inside))
    }

    @Test func measuresFilesFoldersAndLinks() throws {
        let mac = try FakeMac()
        let file = try mac.homeItem("Caches/a/big", bytes: 100_000)
        try mac.homeItem("Caches/a/small", bytes: 10)
        let fileSize = try #require(AppRemoval.allocatedSize(atPath: file))
        #expect(fileSize >= 100_000)
        let folderSize = try #require(AppRemoval.allocatedSize(atPath: mac.home + "/Library/Caches/a"))
        #expect(folderSize > fileSize)
        let link = mac.home + "/Library/Caches/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        #expect(try #require(AppRemoval.allocatedSize(atPath: link)) < fileSize)
        #expect(AppRemoval.allocatedSize(atPath: mac.home + "/missing") == nil)
    }

    @Test func processesInsideTheBundle() {
        let processes = [
            BundleProcess(pid: 10, uid: 501, path: "/Applications/Tool.app/Contents/MacOS/Tool"),
            BundleProcess(pid: 11, uid: 501, path: "/Applications/Tool.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper"),
            BundleProcess(pid: 12, uid: 501, path: "/Applications/Tool.app.old/Contents/MacOS/Tool"),
            BundleProcess(pid: 13, uid: 501, path: "/System/Volumes/Data/Applications/Tool.app/Contents/MacOS/xpc"),
            BundleProcess(pid: 14, uid: 501, path: "/usr/bin/true"),
        ]
        #expect(AppRemoval.processes(inside: ["/Applications/Tool.app"], among: processes).map(\.pid) == [10, 11, 13])
    }

    @Test func sortsRunningProcessesByWhoStopsThem() throws {
        let mac = try FakeMac()
        let agent = try mac.launchAgent("com.example.agent", program: "/Applications/Tool.app/Contents/MacOS/agent")
        let processes = [
            BundleProcess(pid: 30, uid: 0, path: "/Applications/Tool.app/Contents/MacOS/root-helper"),
            BundleProcess(pid: 20, uid: 501, path: "/Applications/Tool.app/Contents/MacOS/agent"),
            BundleProcess(pid: 10, uid: 501, path: "/Applications/Tool.app/Contents/MacOS/Tool"),
        ]
        let check = AppRemoval.classify(processes, unloading: [agent], uid: 501)
        #expect(check.needQuitting.map(\.pid) == [10])
        #expect(check.stopWithAgent.map(\.pid) == [20])
        #expect(check.otherUsers.map(\.pid) == [30])
        #expect(!check.isClear)
        // Without the agent being unloaded, its process needs quitting too.
        #expect(AppRemoval.classify(processes, unloading: [], uid: 501).needQuitting.map(\.pid) == [10, 20])
        #expect(AppRemoval.classify([], unloading: [], uid: 501).isEmpty)
        let agentOnly = AppRemoval.classify([processes[1]], unloading: [agent], uid: 501)
        #expect(agentOnly.isClear && !agentOnly.isEmpty)
    }

    @Test func findsThisProcessRunningFromItsFolder() throws {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let found = AppRemoval.runningProcesses(inside: [(path as NSString).deletingLastPathComponent])
        #expect(found.contains { $0.pid == getpid() && $0.uid == getuid() })
        #expect(AppRemoval.runningProcesses(inside: ["/nonexistent/Nothing.app"]).isEmpty)
    }

    @Test func unloadsFromYourSession() throws {
        let mac = try FakeMac()
        let agent = try mac.launchAgent("com.example.agent", program: "/usr/bin/true")
        #expect(AppRemoval.unloadArguments(for: agent, uid: 501) == ["bootout", "gui/501/com.example.agent"])
    }
}
