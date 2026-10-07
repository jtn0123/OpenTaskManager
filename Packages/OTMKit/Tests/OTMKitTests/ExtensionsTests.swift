import Foundation
@testable import OTMKit
import Testing

/// `systemextensionsctl list` from a Mac with Tailscale, plus rows made up
/// from the formats other categories and states print: an update replacing
/// an older copy, a driver waiting for approval, an unsigned extension with
/// no Team ID, an old-style category line without a settings hint, and a
/// category this version doesn't know.
private let listing = """
5 extension(s)
--- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' \
to modify these system extension(s))
enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
*\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.102.4/101.102.4)\tTailscale Network Extension\t[activated enabled]
*\t\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.100.0/101.100.0)\tTailscale Network Extension\t\
[terminated waiting to uninstall on reboot]
--- com.apple.system_extension.driver_extension (Go to 'System Settings > General > Login Items & Extensions > Driver Extensions' \
to modify these system extension(s))
enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
\t*\tABCDE12345\tcom.example.serial.driver (2.0/7)\tExample USB Serial\t[activated waiting for user]
--- com.apple.system_extension.endpoint_security_extension
enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
*\t*\t-\tcom.example.watchdog\t\t[activated disabled]
--- com.apple.system_extension.something_new (Go to 'System Settings' to modify these system extension(s))
enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
\t\tZZZZZ99999\tnet.example.future (0.1/1)\tFuture Thing\t[validating by category]
not a row at all
"""

/// `kmutil showloaded` with its stderr note and header, three real rows, and
/// a made-up third-party row with a spaced version and no UUID.
private let kmutilOutput = """
No variant specified, falling back to release
Index Refs Address            Size       Wired      Name (Version) UUID <Linked Against>
    3  220 0                  0          0          com.apple.kpi.bsd (27.2.0) DB9F0C5E-156E-3B68-9C42-1F8702FAD66B <>
   11    0 0xfffffe000714b0a0 0x7d45     0x7d45     com.apple.kec.pthread (1) 35C8582C-EC9D-3751-AF6F-8D9C66FE1A08 <9 8 7 6 5 3>
  277    0 0xfffffe0007d8ee50 0xaede1    0xaede1    com.apple.filesystems.smbfs (7.0) 249E27A4-C2AC-3500-9D45-D258EA73EF00 <216 20 14 12 9 8 7 6 5 3>
  280    1 0xfffffe000a000000 0x1000     0x800      com.example.driver.Widget (1.0 beta 2) <277 3>

"""

private func uuidData(_ text: String) -> Data {
    withUnsafeBytes(of: UUID(uuidString: text)!.uuid) { Data($0) }
}

/// What `KextManagerCopyLoadedKextInfo` returns, trimmed to a few entries
/// captured from a real Mac, plus a third-party kext and a broken entry.
private func loadedInfo() -> [String: Any] { [
    "__kernel__": [
        "CFBundleIdentifier": "__kernel__", "OSBundleLoadTag": NSNumber(value: 0), "OSKernelResource": true,
        "OSBundleIsInterface": false, "OSBundleLoadAddress": NSNumber(value: Int64(-2_198_905_765_888)),
    ] as [String: Any],
    "com.apple.sptm": [
        "CFBundleIdentifier": "com.apple.sptm", "OSBundleLoadTag": NSNumber(value: 1), "OSKernelResource": true,
        "OSBundleIsInterface": false, "OSBundlePath": "/usr/appleinternal/standalone/platform",
    ] as [String: Any],
    "com.apple.kpi.bsd": [
        "CFBundleIdentifier": "com.apple.kpi.bsd", "CFBundleVersion": "27.2.0", "OSBundleLoadTag": NSNumber(value: 3),
        "OSBundleRetainCount": NSNumber(value: 220), "OSBundleLoadAddress": NSNumber(value: 0),
        "OSBundleLoadSize": NSNumber(value: 0), "OSBundleWiredSize": NSNumber(value: 0),
        "OSBundleUUID": uuidData("DB9F0C5E-156E-3B68-9C42-1F8702FAD66B"), "OSKernelResource": true,
        "OSBundleIsInterface": true, "OSBundleStarted": true,
        "OSBundlePath": "/System/Library/Extensions/System.kext/PlugIns/BSDKernel.kext",
    ] as [String: Any],
    "com.apple.filesystems.smbfs": [
        "CFBundleIdentifier": "com.apple.filesystems.smbfs", "CFBundleVersion": "7.0", "OSBundleLoadTag": NSNumber(value: 277),
        "OSBundleRetainCount": NSNumber(value: 0), "OSBundleLoadAddress": NSNumber(value: Int64(-2_198_891_598_256)),
        "OSBundleLoadSize": NSNumber(value: 716_257), "OSBundleWiredSize": NSNumber(value: 716_257),
        "OSBundleUUID": uuidData("249E27A4-C2AC-3500-9D45-D258EA73EF00"), "OSKernelResource": false,
        "OSBundleIsInterface": false, "OSBundleStarted": true, "OSBundlePath": "/System/Library/Extensions/smbfs.kext",
        "OSBundleDependencies": [NSNumber(value: 3)],
    ] as [String: Any],
    "com.example.driver.Widget": [
        "CFBundleIdentifier": "com.example.driver.Widget", "OSBundleLoadTag": NSNumber(value: 280),
        "OSBundleRetainCount": NSNumber(value: 0), "OSBundleLoadAddress": NSNumber(value: Int64(-2_198_855_483_392)),
        "OSBundleLoadSize": NSNumber(value: 4096), "OSBundleWiredSize": NSNumber(value: 2048),
        "OSBundleStarted": false, "OSBundlePath": "/Library/Extensions/Widget Driver.kext",
        "OSBundleDependencies": [NSNumber(value: 277), NSNumber(value: 3)],
    ] as [String: Any],
    "com.example.broken": ["CFBundleIdentifier": "com.example.broken"] as [String: Any],
] }

struct SystemExtensionListTests {
    @Test func parsesEveryCategoryAndOddRows() throws {
        let rows = SystemExtensionList.parse(listing)
        #expect(rows.count == 5)

        let tailscale = rows[0]
        #expect(tailscale.bundleID == "io.tailscale.ipn.macsys.network-extension")
        #expect(tailscale.name == "Tailscale Network Extension")
        #expect(tailscale.version == "1.102.4")
        #expect(tailscale.build == "101.102.4")
        #expect(tailscale.teamID == "W5364U7YZB")
        #expect(tailscale.category == .network)
        #expect(tailscale.settingsLocation == "System Settings > General > Login Items & Extensions > Network Extensions")
        #expect(tailscale.isEnabled && tailscale.isActive)
        #expect(tailscale.state == "activated enabled")
        #expect(tailscale.status == .active)

        let old = rows[1]
        #expect(old.version == "1.100.0")
        #expect(old.isEnabled && !old.isActive)
        #expect(old.status == .uninstalling)

        let driver = rows[2]
        #expect(driver.category == .driver)
        #expect(!driver.isEnabled && driver.isActive)
        #expect(driver.status == .needsApproval)
        #expect(driver.status.needsAttention)
        #expect(driver.settingsLocation?.hasSuffix("Driver Extensions") == true)

        let watchdog = rows[3]
        #expect(watchdog.category == .endpointSecurity)
        #expect(watchdog.teamID == nil)
        #expect(watchdog.version == nil)
        #expect(watchdog.name.isEmpty)
        #expect(watchdog.settingsLocation == nil)
        #expect(watchdog.status == .disabled)

        let future = rows[4]
        #expect(future.category == .otherSystem)
        #expect(future.settingsLocation == "System Settings")
        #expect(future.status == .other("Being checked"))
    }

    @Test func tellsAnEmptyListFromAFailure() {
        #expect(SystemExtensionList.isListing("0 extension(s)\n"))
        #expect(SystemExtensionList.parse("0 extension(s)\n").isEmpty)
        #expect(SystemExtensionList.isListing(listing))
        #expect(!SystemExtensionList.isListing("systemextensionsctl: an error occurred\n"))
        #expect(!SystemExtensionList.isListing(""))
    }

    @Test(arguments: [
        ("activated enabled", true, ExtensionStatus.active),
        ("activated enabled", false, .enabled),
        ("activated disabled", true, .disabled),
        ("activated waiting for user", false, .needsApproval),
        ("waiting for user", false, .needsApproval),
        ("terminated waiting to uninstall on reboot", false, .uninstalling),
        ("uninstalling", false, .uninstalling),
        ("activated waiting to upgrade", false, .other("Update waiting")),
        ("validating", false, .other("Being checked")),
        ("terminated waiting to deactivate", false, .other("Stopped")),
        ("staged", false, .other("Staged")),
        ("", false, .other("Unknown")),
    ])
    func friendlyStatus(state: String, active: Bool, expected: ExtensionStatus) {
        let item = SystemExtension(bundleID: "x", name: "X", version: nil, build: nil, teamID: nil,
                                   categoryIdentifier: "", settingsLocation: nil, isEnabled: true, isActive: active,
                                   state: state, appPath: nil)
        #expect(item.status == expected)
        #expect(item.status.needsAttention == (expected == .needsApproval))
    }

    @Test func splitsBundleIDAndVersion() {
        #expect(SystemExtensionList.splitVersion("io.a.b (1.2/3)") == ("io.a.b", "1.2/3"))
        #expect(SystemExtensionList.splitVersion("io.a.b") == ("io.a.b", nil))
        #expect(SystemExtensionList.splitVersion("io.a.b (beta (2))") == ("io.a.b (beta", "2)"))
    }

    @Test func findsTheInstallingAppInTheDatabase() throws {
        let database: [String: Any] = [
            "extensions": [
                [
                    "identifier": "io.tailscale.ipn.macsys.network-extension", "teamID": "W5364U7YZB",
                    "container": ["bundlePath": "/Applications/Tailscale.app"],
                    "state": "activated_enabled",
                ],
                ["identifier": "com.example.serial.driver", "container": [:] as [String: Any]],
                ["no identifier": true],
            ] as [[String: Any]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: database, format: .binary, options: 0)
        let rows = SystemExtensionList.attachApps(SystemExtensionList.parse(listing), database: data)
        #expect(rows[0].appPath == "/Applications/Tailscale.app")
        #expect(rows[1].appPath == "/Applications/Tailscale.app", "the old copy came from the same app")
        #expect(rows[2].appPath == nil)
        #expect(SystemExtensionList.attachApps(rows, database: Data("not a plist".utf8)) == rows)
    }

    @Test func categoriesHaveFriendlyNames() {
        #expect(ExtensionCategory(systemCategory: "com.apple.system_extension.network_extension").title == "Network extension")
        #expect(ExtensionCategory(systemCategory: "com.apple.system_extension.driver_extension").title == "Driver (DriverKit)")
        #expect(ExtensionCategory(systemCategory: "com.apple.system_extension.endpoint_security_extension").title == "Endpoint security")
        #expect(ExtensionCategory.kernel.title == "Kernel extension")
        #expect(ExtensionCategory(systemCategory: "").title == "System extension")
        #expect(ExtensionCategory.allCases.sorted() == ExtensionCategory.allCases)
        #expect(ExtensionCategory.network < .kernel)
    }
}

struct KernelExtensionListTests {
    @Test func parsesKmutilRows() throws {
        let kexts = KernelExtensionList.parse(kmutil: kmutilOutput)
        #expect(kexts.map(\.loadTag) == [3, 11, 277, 280])

        let bsd = kexts[0]
        #expect(bsd.bundleID == "com.apple.kpi.bsd")
        #expect(bsd.version == "27.2.0")
        #expect(bsd.references == 220)
        #expect(bsd.loadAddress == nil)
        #expect(bsd.isInterface)
        #expect(bsd.uuid == "DB9F0C5E-156E-3B68-9C42-1F8702FAD66B")
        #expect(bsd.linkedAgainst.isEmpty)
        #expect(bsd.name == "bsd")

        let smbfs = kexts[2]
        #expect(smbfs.loadAddress == 0xFFFF_FE00_07D8_EE50)
        #expect(smbfs.size == 0xAEDE1)
        #expect(smbfs.linkedAgainst == [216, 20, 14, 12, 9, 8, 7, 6, 5, 3])
        #expect(!smbfs.isInterface)
        #expect(smbfs.path == nil)

        let widget = kexts[3]
        #expect(widget.version == "1.0 beta 2")
        #expect(widget.uuid == nil)
        #expect(widget.wiredSize == 0x800)
        #expect(widget.linkedAgainst == [277, 3])
        #expect(widget.name == "Widget")
    }

    @Test func readsTheKernelsOwnList() throws {
        let kexts = KernelExtensionList.parse(loadedInfo: loadedInfo())
        // The kernel, sptm and the entry without a load tag are left out.
        #expect(kexts.map(\.bundleID) == ["com.apple.kpi.bsd", "com.apple.filesystems.smbfs", "com.example.driver.Widget"])

        let bsd = kexts[0]
        #expect(bsd.isInterface)
        #expect(bsd.loadAddress == nil)
        #expect(bsd.references == 220)
        #expect(bsd.uuid == "DB9F0C5E-156E-3B68-9C42-1F8702FAD66B")
        #expect(bsd.name == "BSDKernel")

        let smbfs = kexts[1]
        #expect(smbfs.loadAddress == 0xFFFF_FE00_07D8_EE50, "negative numbers are addresses in the kernel's half")
        #expect(smbfs.wiredSize == 716_257)
        #expect(smbfs.name == "smbfs")
        #expect(smbfs.version == "7.0")

        let widget = kexts[2]
        #expect(widget.version == nil)
        #expect(!widget.isStarted)
        #expect(widget.name == "Widget Driver")
        #expect(widget.uuid == nil)
    }
}

struct ExtensionItemTests {
    private var scan: ExtensionScan {
        ExtensionScan(items: Extensions.items(systemExtensions: SystemExtensionList.parse(listing),
                                              kernelExtensions: KernelExtensionList.parse(loadedInfo: loadedInfo())),
                      readSystemExtensions: true, readKernelExtensions: true)
    }

    @Test func classifiesPublishers() {
        #expect(Extensions.publisher(bundleID: "com.apple.kpi.bsd", path: nil) == .apple)
        #expect(Extensions.publisher(bundleID: "com.Apple.driver.X", path: nil) == .apple)
        #expect(Extensions.publisher(bundleID: "foo", path: "/System/Library/Extensions/foo.kext") == .apple)
        #expect(Extensions.publisher(bundleID: "com.applesauce.kext", path: "/Library/Extensions/a.kext") == .thirdParty)
        #expect(Extensions.publisher(bundleID: "io.tailscale.ipn.macsys.network-extension", path: nil) == .thirdParty)
    }

    @Test func buildsRowsWithUniqueIDs() throws {
        let items = scan.items
        #expect(items.count == 8)
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items.prefix(5).allSatisfy { $0.category.isSystemExtension })
        #expect(items.dropFirst(5).allSatisfy { $0.category == .kernel })

        let watchdog = try #require(items.first { $0.bundleID == "com.example.watchdog" })
        #expect(watchdog.name == "Example Watchdog", "a missing name comes from the bundle ID")
        #expect(watchdog.version.isEmpty)

        let widget = try #require(items.first { $0.bundleID == "com.example.driver.Widget" })
        #expect(widget.publisher == .thirdParty)
        #expect(widget.status == .notStarted)
        #expect(widget.kind == "Kernel extension")
        let bsd = try #require(items.first { $0.bundleID == "com.apple.kpi.bsd" })
        #expect(bsd.isKernelInterface)
        #expect(bsd.kind == "Kernel interface")

        // The same extension listed twice with the same identity still gets two IDs.
        let row = SystemExtensionList.parse(listing)[0]
        let twice = Extensions.items(systemExtensions: [row, row], kernelExtensions: [])
        #expect(Set(twice.map(\.id)).count == 2)
    }

    @Test func summarizes() {
        let summary = scan.summary
        #expect(summary.systemExtensions == 5)
        #expect(summary.loadedKernelExtensions == 3)
        #expect(summary.thirdPartyKernelExtensions == 1)
        #expect(summary.needsAttention == 1)
    }

    @Test func resolvesLinks() throws {
        let scan = scan
        let widget = try #require(scan.items.first { $0.bundleID == "com.example.driver.Widget" }?.kernelExtension)
        let bsd = try #require(scan.items.first { $0.bundleID == "com.apple.kpi.bsd" }?.kernelExtension)
        #expect(scan.linkedAgainst(widget) == ["com.apple.filesystems.smbfs", "com.apple.kpi.bsd"], "interfaces last")
        #expect(scan.linkedBy(bsd) == ["com.apple.filesystems.smbfs", "com.example.driver.Widget"])
        #expect(scan.linkedBy(widget).isEmpty)
    }

    @Test func searchMatchesNamesIDsAndTeams() throws {
        let tailscale = try #require(scan.items.first)
        #expect(tailscale.matches("tailscale"))
        #expect(tailscale.matches("W5364"))
        #expect(tailscale.matches("network ext"))
        #expect(tailscale.matches("  "))
        #expect(!tailscale.matches("smbfs"))
        let smbfs = try #require(scan.items.first { $0.bundleID.hasSuffix("smbfs") })
        #expect(smbfs.matches("/System/Library/Extensions"))
    }

    @Test func statusCodesAsOneString() throws {
        let statuses: [ExtensionStatus] = [.active, .needsApproval, .uninstalling, .other("Being checked")]
        let data = try JSONEncoder().encode(statuses)
        #expect(String(decoding: data, as: UTF8.self) == #"["active","needsApproval","uninstalling","Being checked"]"#)
        #expect(try JSONDecoder().decode([ExtensionStatus].self, from: data) == statuses)
    }

    @Test func statusesSortWithWhatNeedsYouFirst() {
        let sorted: [ExtensionStatus] = [.other("Stopped"), .loaded, .uninstalling, .needsApproval, .active]
        #expect(sorted.sorted() == [.needsApproval, .active, .loaded, .uninstalling, .other("Stopped")])
    }
}

/// Reads this Mac. Every Mac has kexts loaded, the kernel interfaces at least;
/// system extensions vary, so only their shape is checked.
struct LiveExtensionTests {
    @Test func scansThisMac() {
        let scan = Extensions.scan()
        #expect(scan.readKernelExtensions)
        #expect(scan.items.contains { $0.bundleID == "com.apple.kpi.bsd" && $0.isKernelInterface })
        #expect(Set(scan.items.map(\.id)).count == scan.items.count)
        #expect(scan.summary.loadedKernelExtensions > 10)
        if scan.readSystemExtensions {
            #expect(scan.items.filter(\.category.isSystemExtension).allSatisfy { $0.systemExtension != nil })
        }
    }
}
