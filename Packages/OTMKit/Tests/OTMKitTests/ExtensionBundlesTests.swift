import Foundation
@testable import OTMKit
import Testing

// MARK: - Fixtures

/// A throwaway /Library/Extensions, Applications folder and home under the
/// temporary directory, filled with fake bundles (an Info.plist in the
/// folder layout of a `.kext`, `.systemextension` or shallow `.dext`), so no
/// test reads the Mac's own folders.
private final class FakeExtensionFolders {
    let root: String
    var kexts: String { root + "/Library/Extensions" }
    var applications: String { root + "/Applications" }
    var homeApplications: String { root + "/home/Applications" }
    var folders: ExtensionFolders {
        ExtensionFolders(kernelExtensionFolders: [kexts], appFolders: [applications, homeApplications, root + "/missing"])
    }

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otm-extensions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath().path
        for folder in [kexts, applications, homeApplications] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    /// A bundle folder with `info` as its Info.plist (none when nil), at
    /// Contents/Info.plist or, for a shallow bundle, at the top.
    @discardableResult
    func bundle(_ path: String, info: [String: Any]?, shallow: Bool = false) throws -> String {
        let contents = shallow ? path : path + "/Contents"
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        if let info {
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: contents + "/Info.plist"))
        }
        return path
    }

    /// An app with an Info.plist of its own.
    @discardableResult
    func app(_ folder: String, _ name: String) throws -> String {
        try bundle(folder + "/" + name + ".app", info: ["CFBundleIdentifier": "com.example.\(name.lowercased())"])
    }

    func folder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}

private func info(_ identifier: String, version: String? = nil, build: String? = nil, extra: [String: Any] = [:]) -> [String: Any] {
    var info: [String: Any] = ["CFBundleIdentifier": identifier]
    if let version { info["CFBundleShortVersionString"] = version }
    if let build { info["CFBundleVersion"] = build }
    return info.merging(extra) { _, new in new }
}

/// A signature by path, so tests never depend on how the Security framework
/// treats an unsigned fake bundle.
private func fakeSignature(_ path: String) -> CodeSignature {
    path.contains("filter") ? CodeSignature(signer: .developerID, teamIdentifier: "ABCDE12345") : CodeSignature(signer: .unsigned)
}

private func bundle(_ path: String, _ identifier: String?, category: ExtensionCategory = .kernel, version: String? = "1.0",
                    build: String? = "1.0", app: String? = nil) -> ExtensionBundle {
    ExtensionBundle(path: path, appPath: app, category: category, bundleID: identifier,
                    name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                    version: version, build: build, teamID: nil, signer: .unsigned)
}

private func kext(_ identifier: String, version: String?, path: String?, tag: Int = 300) -> KernelExtension {
    KernelExtension(loadTag: tag, bundleID: identifier, version: version, references: 0, loadAddress: 0x1000, size: 4096,
                    wiredSize: 4096, uuid: nil, linkedAgainst: [], path: path, isInterface: false, isStarted: true)
}

private func systemExtension(_ identifier: String, version: String?, build: String?, origin: String? = nil) -> SystemExtension {
    SystemExtension(bundleID: identifier, name: "Filter", version: version, build: build, teamID: "ABCDE12345",
                    categoryIdentifier: "com.apple.system_extension.network_extension", settingsLocation: nil,
                    isEnabled: true, isActive: true, state: "activated enabled", appPath: "/Applications/Filter.app",
                    originPath: origin)
}

private func merge(system: [SystemExtension] = [], kexts: [KernelExtension] = [], bundles: [ExtensionBundle],
                   readSystem: Bool = true, readKernel: Bool = true) -> [ExtensionItem] {
    ExtensionMatching.merge(Extensions.items(systemExtensions: system, kernelExtensions: kexts), bundles: bundles,
                            readSystemExtensions: readSystem, readKernelExtensions: readKernel)
}

// MARK: - Finding and reading bundles

struct ExtensionBundleDiscoveryTests {
    @Test func findsKextsAndAppsExtensionsOneLevelDeep() throws {
        let mac = try FakeExtensionFolders()
        try mac.bundle(mac.kexts + "/Widget.kext", info: info("com.example.widget", version: "1.2", build: "1.2.3"))
        try mac.bundle(mac.kexts + "/.Hidden.kext", info: info("com.example.hidden"))
        try mac.folder(mac.kexts + "/Not a bundle")
        // A kext's own plug-ins are a level further in, so they're left alone.
        try mac.bundle(mac.kexts + "/Widget.kext/Contents/PlugIns/Inner.kext", info: info("com.example.inner"))
        let demo = try mac.app(mac.applications, "Demo")
        try mac.bundle(demo + "/Contents/Library/Extensions/Serial.kext", info: info("com.example.serial", version: "2", build: "20"))
        try mac.bundle(demo + "/Contents/Library/SystemExtensions/com.example.filter.systemextension",
                       info: info("com.example.filter", version: "3.1", build: "310", extra: [
                           "CFBundleDisplayName": "Example Filter", "NetworkExtension": ["NEMachServiceName": "x"],
                       ]))
        try mac.bundle(demo + "/Contents/Library/SystemExtensions/com.example.usb.dext",
                       info: info("com.example.usb", version: "1.0", extra: ["IOKitPersonalities": [:] as [String: Any]]),
                       shallow: true)
        // An app inside a plain folder isn't one level into Applications.
        let deep = try mac.app(mac.applications + "/Vendor", "Deep")
        try mac.bundle(deep + "/Contents/Library/Extensions/Deep.kext", info: info("com.example.deep"))
        let mine = try mac.app(mac.homeApplications, "Mine")
        try mac.bundle(mine + "/Contents/Library/SystemExtensions/com.example.guard.systemextension",
                       info: info("com.example.guard", version: "5", extra: [
                           "CFBundleName": "com.example.guard", "NSEndpointSecurityMachServiceName": "x",
                       ]))
        let broken = try mac.app(mac.applications, "Broken")
        try mac.bundle(broken + "/Contents/Library/SystemExtensions/broken.systemextension", info: nil)
        // A link to an app already found is the same copy.
        try FileManager.default.createSymbolicLink(atPath: mac.applications + "/Link.app", withDestinationPath: demo)

        let found = ExtensionBundles.find(in: mac.folders)
        #expect(found.map { $0.path.replacingOccurrences(of: mac.root, with: "") } == [
            "/Library/Extensions/Widget.kext",
            "/Applications/Broken.app/Contents/Library/SystemExtensions/broken.systemextension",
            "/Applications/Demo.app/Contents/Library/Extensions/Serial.kext",
            "/Applications/Demo.app/Contents/Library/SystemExtensions/com.example.filter.systemextension",
            "/Applications/Demo.app/Contents/Library/SystemExtensions/com.example.usb.dext",
            "/home/Applications/Mine.app/Contents/Library/SystemExtensions/com.example.guard.systemextension",
        ])
        #expect(found[0].appPath == nil)
        #expect(found[2].appPath == demo)

        let bundles = ExtensionBundles.scan(mac.folders, signature: fakeSignature)
        let widget = bundles[0]
        #expect(widget.category == .kernel)
        #expect(widget.name == "Widget", "a kext goes by its file name, as loaded ones do")
        #expect(widget.bundleID == "com.example.widget")
        #expect(widget.version == "1.2" && widget.build == "1.2.3")
        #expect(widget.reportedVersion == "1.2.3", "the kernel reports CFBundleVersion")
        #expect(widget.signer == .unsigned && widget.teamID == nil)

        let unreadable = bundles[1]
        #expect(unreadable.bundleID == nil)
        #expect(unreadable.name == "broken")
        #expect(unreadable.category == .otherSystem)
        #expect(unreadable.appName == "Broken")

        let filter = bundles[3]
        #expect(filter.category == .network)
        #expect(filter.name == "Example Filter")
        #expect(filter.reportedVersion == "3.1", "systemextensionsctl prints the short version")
        #expect(filter.teamID == "ABCDE12345")
        #expect(filter.appName == "Demo")

        let usb = bundles[4]
        #expect(usb.category == .driver)
        #expect(usb.bundleID == "com.example.usb", "a shallow DriverKit bundle's Info.plist is at its top")
        #expect(usb.name == "Example Usb")

        let guardian = bundles[5]
        #expect(guardian.category == .endpointSecurity)
        #expect(guardian.name == "Example Guard", "a bundle name that's just the identifier is made readable")
        #expect(guardian.appPath == mine)
    }

    @Test func skipsMissingAndUnreadableFoldersQuietly() throws {
        let mac = try FakeExtensionFolders()
        let locked = mac.applications + "/Locked.app/Contents/Library/Extensions"
        try mac.bundle(locked + "/Secret.kext", info: info("com.example.secret"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        // Unlocked while the fixture is still alive, so it can then be removed.
        defer {
            withExtendedLifetime(mac) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            }
        }
        #expect(ExtensionBundles.find(in: mac.folders).isEmpty)
        #expect(ExtensionBundles.find(in: .none).isEmpty)
        #expect(ExtensionBundles.find(in: ExtensionFolders(kernelExtensionFolders: [mac.root + "/nowhere"], appFolders: [])).isEmpty)
    }

    @Test func readsTheSignatureOfAnUnsignedFakeWithoutATeam() throws {
        let mac = try FakeExtensionFolders()
        try mac.bundle(mac.kexts + "/Plain.kext", info: info("com.example.plain", version: "1"))
        let plain = try #require(ExtensionBundles.scan(mac.folders).first)
        #expect(plain.teamID == nil)
        #expect(plain.signer != .developerID && plain.signer != .apple)
    }

    @Test func standardFoldersSkipAppleSealedKexts() {
        let folders = ExtensionFolders.standard(home: "/Users/someone")
        #expect(folders.kernelExtensionFolders == ["/Library/Extensions"])
        #expect(folders.appFolders == ["/Applications", "/Users/someone/Applications"])
        #expect(!(folders.kernelExtensionFolders + folders.appFolders).contains { $0.hasPrefix("/System") })
    }
}

// MARK: - Matching copies to what macOS reports

struct ExtensionMatchingTests {
    @Test func attachesTheCopyOfARegisteredSystemExtension() throws {
        let path = "/Applications/Filter.app/Contents/Library/SystemExtensions/com.example.filter.systemextension"
        let copy = bundle(path, "com.example.filter", category: .network, version: "3.1", build: "310", app: "/Applications/Filter.app")
        let items = merge(system: [systemExtension("com.example.filter", version: "3.1", build: "310")], bundles: [copy])
        #expect(items.count == 1, "no second row for the copy in use")
        #expect(items[0].bundle == copy)
        #expect(items[0].status == .active)
        #expect(items[0].diskPath == path)
        #expect(items[0].appPath == "/Applications/Filter.app")
    }

    @Test func aDifferentVersionOnDiskIsARowOfItsOwn() throws {
        let newer = bundle("/Applications/Filter.app/Contents/Library/SystemExtensions/f.systemextension", "com.example.filter",
                           category: .network, version: "3.2", build: "320", app: "/Applications/Filter.app")
        let sameShortOtherBuild = bundle("/Users/a/Applications/Filter.app/Contents/Library/SystemExtensions/f.systemextension",
                                         "com.example.filter", category: .network, version: "3.1", build: "311")
        let items = merge(system: [systemExtension("com.example.filter", version: "3.1", build: "310")],
                          bundles: [newer, sameShortOtherBuild])
        #expect(items.count == 3)
        #expect(items[0].bundle == nil)
        let copy = items[1]
        #expect(copy.status == .notInUse)
        #expect(copy.systemExtension == nil && copy.kernelExtension == nil)
        #expect(copy.version == "3.2")
        #expect(copy.registeredVersions == ["3.1"])
        #expect(copy.id == "disk:" + newer.path)
        #expect(copy.appPath == "/Applications/Filter.app")
        #expect(copy.statusExplanation.hasSuffix("macOS has version 3.1 registered, not this copy's 3.2."))
        #expect(items[2].status == .notInUse, "the build tells two copies of 3.1 apart")
    }

    @Test func matchesLoadedKextsByVersionAndKeepsTheRest() throws {
        let loaded = bundle("/Library/Extensions/Widget.kext", "com.example.widget", version: "1.2", build: "1.2.3")
        let older = bundle("/Applications/Old.app/Contents/Library/Extensions/Widget.kext", "com.example.widget",
                           version: "1.1", build: "1.1.0", app: "/Applications/Old.app")
        let unloaded = bundle("/Library/Extensions/Idle.kext", "com.example.idle")
        let items = merge(kexts: [kext("com.example.widget", version: "1.2.3", path: "/Library/Extensions/Widget.kext")],
                          bundles: [loaded, older, unloaded])
        #expect(items.map(\.status) == [.loaded, .notInUse, .notInUse])
        #expect(items[0].bundle == loaded)
        #expect(items[1].bundle == older)
        #expect(items[1].registeredVersions == ["1.2.3"])
        #expect(items[1].statusExplanation.hasSuffix("The kernel has version 1.2.3 loaded, not this copy's 1.1.0."))
        #expect(items[2].registeredVersions == nil)
        #expect(items[2].statusExplanation.contains("the kernel hasn't loaded it"))
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func twoCopiesOfTheVersionInUse() throws {
        let first = bundle("/Library/Extensions/Widget.kext", "com.example.widget")
        let second = bundle("/Applications/W.app/Contents/Library/Extensions/Widget.kext", "com.example.widget", app: "/Applications/W.app")
        // The kernel names where it loaded from, so the other copy isn't in use.
        let hinted = merge(kexts: [kext("com.example.widget", version: "1.0", path: second.path)], bundles: [first, second])
        #expect(hinted.count == 2)
        #expect(hinted[0].bundle == second)
        #expect(hinted[1].bundle == first && hinted[1].status == .notInUse)
        #expect(hinted[1].statusExplanation.hasSuffix("Another copy of version 1.0 is the one in use."))
        // Without a path, which one it took is unknown, rather than guessed.
        let unhinted = merge(kexts: [kext("com.example.widget", version: "1.0", path: nil)], bundles: [first, second])
        #expect(unhinted[0].bundle == nil)
        #expect(unhinted.dropFirst().map(\.status) == [.useUnknown, .useUnknown])
        #expect(unhinted.dropFirst().allSatisfy { $0.unknownReason == .severalCopies })
        // A system extension's database origin settles it the same way.
        let path = "/Applications/Filter.app/Contents/Library/SystemExtensions/f.systemextension"
        let copies = [bundle("/Users/a" + path, "com.example.filter", category: .network, version: "3.1", build: "310"),
                      bundle(path, "com.example.filter", category: .network, version: "3.1", build: "310")]
        let byOrigin = merge(system: [systemExtension("com.example.filter", version: "3.1", build: "310", origin: path)], bundles: copies)
        #expect(byOrigin[0].bundle?.path == path)
        #expect(byOrigin[1].status == .notInUse)
    }

    @Test func staysUnknownRatherThanGuessing() throws {
        let unreadable = bundle("/Applications/B.app/Contents/Library/SystemExtensions/b.systemextension", nil,
                                category: .otherSystem, version: nil, build: nil)
        let noVersionLoaded = bundle("/Library/Extensions/Bare.kext", "com.example.bare")
        let items = merge(kexts: [kext("com.example.bare", version: nil, path: nil)], bundles: [unreadable, noVersionLoaded])
        let byPath = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.bundle.map { ($0.path, item) } })
        #expect(byPath[unreadable.path]?.unknownReason == .unreadable)
        #expect(byPath[unreadable.path]?.bundleID == "")
        #expect(byPath[noVersionLoaded.path]?.unknownReason == .versionMissing)
        #expect(byPath[noVersionLoaded.path]?.statusExplanation.contains("no version") == true)
        #expect(items[0].bundle == nil, "the loaded kext isn't given a copy it might not be")

        // A list that couldn't be read leaves its own kind unknown, not the other.
        let kextCopy = bundle("/Library/Extensions/Idle.kext", "com.example.idle")
        let systemCopy = bundle("/Applications/F.app/Contents/Library/SystemExtensions/f.systemextension", "com.example.f",
                                category: .network)
        let blind = merge(bundles: [kextCopy, systemCopy], readSystem: false, readKernel: true)
        #expect(blind.map(\.status) == [.notInUse, .useUnknown])
        #expect(blind[1].unknownReason == .listUnavailable)
        #expect(blind[1].statusExplanation.contains("systemextensionsctl didn't answer"))
        let noKernel = merge(bundles: [kextCopy], readKernel: false)
        #expect(noKernel[0].unknownReason == .listUnavailable)
        #expect(noKernel[0].statusExplanation.contains("loaded kexts couldn't be read"))
    }

    @Test func aRowWithAVersionIsMatchedBeforeOneWithout() throws {
        let copy = bundle("/Library/Extensions/Widget.kext", "com.example.widget")
        let items = merge(kexts: [kext("com.example.widget", version: nil, path: nil, tag: 1),
                                  kext("com.example.widget", version: "1.0", path: nil, tag: 2)], bundles: [copy])
        #expect(items.count == 2)
        #expect(items[1].bundle == copy)
    }

    @Test func summaryCountsCopiesApartFromWhatsLoaded() throws {
        let items = merge(system: [systemExtension("com.example.filter", version: "3.1", build: "310")],
                          kexts: [kext("com.example.widget", version: "1.0", path: nil)],
                          bundles: [bundle("/Library/Extensions/Idle.kext", "com.example.idle"),
                                    bundle("/Library/Extensions/Apple.kext", "com.apple.driver.Idle"),
                                    bundle("/Applications/F.app/Contents/Library/SystemExtensions/x.systemextension", "com.example.x",
                                           category: .driver),
                                    bundle("/Applications/F.app/Contents/Library/SystemExtensions/y.systemextension", nil,
                                           category: .otherSystem)])
        let summary = ExtensionSummary(items)
        #expect(summary.systemExtensions == 1, "registered ones only")
        #expect(summary.loadedKernelExtensions == 1)
        #expect(summary.thirdPartyKernelExtensions == 1)
        #expect(summary.notInUse == 3)
        #expect(summary.useUnknown == 1)
        #expect(summary.needsAttention == 0)
        let apple = try #require(items.first { $0.bundleID == "com.apple.driver.Idle" })
        #expect(apple.publisher == .apple)
    }

    @Test func searchFindsCopiesByAppPathAndTeam() throws {
        let copy = ExtensionBundle(path: "/Applications/Demo App.app/Contents/Library/Extensions/Serial.kext",
                                   appPath: "/Applications/Demo App.app", category: .kernel, bundleID: "com.example.serial",
                                   name: "Serial", version: "1", build: "1", teamID: "ZZZ9999999", signer: .developerID)
        let item = ExtensionItem(copy)
        #expect(item.matches("demo app"))
        #expect(item.matches("Contents/Library/Extensions"))
        #expect(item.matches("ZZZ999"))
        #expect(!item.matches("tailscale"))
    }

    @Test func newStatusesCodeAndSortLast() throws {
        let statuses: [ExtensionStatus] = [.notInUse, .useUnknown]
        let data = try JSONEncoder().encode(statuses)
        #expect(String(decoding: data, as: UTF8.self) == #"["notInUse","useUnknown"]"#)
        #expect(try JSONDecoder().decode([ExtensionStatus].self, from: data) == statuses)
        let sorted: [ExtensionStatus] = [.notInUse, .loaded, .useUnknown, .needsApproval, .other("Stopped"), .active]
        #expect(sorted.sorted() == [.needsApproval, .active, .loaded, .other("Stopped"), .useUnknown, .notInUse])
        #expect(ExtensionStatus.notInUse.title == "Installed, not in use")
        #expect(ExtensionStatus.notInUse.shortTitle == "Not in use")
        #expect(ExtensionStatus.active.shortTitle == "Active")
        #expect(ExtensionStatus.notInUse.isDiskCopy && ExtensionStatus.useUnknown.isDiskCopy && !ExtensionStatus.loaded.isDiskCopy)
        #expect(!ExtensionStatus.notInUse.needsAttention)
    }

    @Test func aCopyEncodesWithItsPathAndStatusCode() throws {
        let item = ExtensionItem(bundle("/Library/Extensions/Idle.kext", "com.example.idle"))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(json["status"] as? String == "notInUse")
        #expect((json["bundle"] as? [String: Any])?["path"] as? String == "/Library/Extensions/Idle.kext")
        #expect(json["systemExtension"] == nil && json["kernelExtension"] == nil)
        #expect(try JSONDecoder().decode(ExtensionItem.self, from: JSONEncoder().encode(item)) == item)
    }

    @Test func appNamesDropTheirSuffix() {
        #expect(Extensions.appName("/Applications/Tailscale.app") == "Tailscale")
        #expect(Extensions.appName("/Applications/OTM Ext Demo.APP") == "OTM Ext Demo")
        #expect(Extensions.appName("/Library/Extensions") == "Extensions")
    }
}

// MARK: - The whole scan, on fake folders

struct ExtensionScanFolderTests {
    /// Reads this Mac's lists (systemextensionsctl and the kernel's), but
    /// only the fake folders on disk.
    @Test func scanAddsCopiesFromTheGivenFoldersOnly() throws {
        let mac = try FakeExtensionFolders()
        try mac.bundle(mac.kexts + "/OTMTestOnly.kext", info: info("org.opentaskmanager.test.unloaded", version: "1", build: "1.0.0"))
        let app = try mac.app(mac.applications, "Carrier")
        try mac.bundle(app + "/Contents/Library/SystemExtensions/org.opentaskmanager.test.filter.systemextension",
                       info: info("org.opentaskmanager.test.filter", version: "1", build: "1",
                                  extra: ["CFBundleDisplayName": "Filter", "NetworkExtension": [:] as [String: Any]]))
        let scan = Extensions.scan(folders: mac.folders)
        let copies = scan.items.filter { $0.bundleID.hasPrefix("org.opentaskmanager.test.") }
        #expect(copies.map(\.name) == ["OTMTestOnly", "Filter"])
        for copy in copies {
            // Not in use, unless the list it would be in couldn't be read.
            let listed = copy.category == .kernel ? scan.readKernelExtensions : scan.readSystemExtensions
            #expect(copy.status == (listed ? .notInUse : .useUnknown))
            #expect(copy.bundle?.path.hasPrefix(mac.root) == true)
        }
        #expect(copies.last?.appPath == app)
        #expect(Set(scan.items.map(\.id)).count == scan.items.count)
        // Every other copy on disk is one of these two: no real folder was read.
        #expect(scan.items.filter { $0.systemExtension == nil && $0.kernelExtension == nil }.count == 2)
    }
}
