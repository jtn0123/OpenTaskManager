import Foundation
@testable import OTMKit
import Security
import Testing

// MARK: - Fixtures

/// Hand-built Mach-O headers.
private enum Header {
    static func littleEndian(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    static func bigEndian(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

    /// A complete mach_header (28 bytes) or mach_header_64 (32 bytes).
    static func thin(cpu: Int32, subtype: Int32 = 0, is64Bit: Bool = true, bigEndian big: Bool = false) -> Data {
        let word = big ? bigEndian : littleEndian
        var bytes = word(is64Bit ? 0xFEED_FACF : 0xFEED_FACE) + word(UInt32(bitPattern: cpu)) + word(UInt32(bitPattern: subtype))
        bytes += [UInt8](repeating: 0, count: (is64Bit ? 32 : 28) - bytes.count)
        return Data(bytes)
    }

    /// A fat header with one fat_arch (or fat_arch_64) per slice, then padding.
    static func fat(_ slices: [(cpu: Int32, subtype: Int32)], is64Bit: Bool = false) -> Data {
        var bytes = bigEndian(is64Bit ? 0xCAFE_BABF : 0xCAFE_BABE) + bigEndian(UInt32(slices.count))
        for (index, slice) in slices.enumerated() {
            bytes += bigEndian(UInt32(bitPattern: slice.cpu)) + bigEndian(UInt32(bitPattern: slice.subtype))
            let offset = UInt32(0x4000 * (index + 1))
            if is64Bit {
                bytes += [0, 0, 0, 0] + bigEndian(offset) + [0, 0, 0, 0] + bigEndian(0x1000) + bigEndian(14) + bigEndian(0)
            } else {
                bytes += bigEndian(offset) + bigEndian(0x1000) + bigEndian(14)
            }
        }
        return Data(bytes + [UInt8](repeating: 0, count: 64))
    }
}

/// A scratch folder that removes itself.
private final class Scratch {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otm-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolved, so /var/folders becomes /private/var/folders like the scanner's paths.
        url = base.resolvingSymlinksInPath()
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, _ data: Data = Data()) throws -> String {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file.path
    }

    func plist(_ relative: String, _ dictionary: [String: Any]) throws {
        try write(relative, PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
    }

    func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(relative), withIntermediateDirectories: true)
    }
}

private func app(_ path: String, resolved: String? = nil, id: String?, kind: AppKind = .thirdParty,
                 launchItems: [LaunchItem] = []) -> InstalledApp {
    InstalledApp(path: path, resolvedPath: resolved ?? path,
                 name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                 bundleIdentifier: id, version: "1.0", build: "1", minimumSystemVersion: nil, executablePath: nil,
                 kind: kind, hasAppStoreReceipt: false, isiOSApp: false, slices: nil, signature: .unknown,
                 lastOpened: nil, added: nil, launchItems: launchItems)
}

private func launchItem(label: String, program: String? = nil, arguments: [String] = [], extra: String = "",
                        scope: LaunchItemScope = .systemAgent) -> LaunchItem {
    var body = "<key>Label</key><string>\(label)</string>"
    if let program { body += "<key>Program</key><string>\(program)</string>" }
    if !arguments.isEmpty {
        body += "<key>ProgramArguments</key><array>" + arguments.map { "<string>\($0)</string>" }.joined() + "</array>"
    }
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>\(body)\(extra)</dict></plist>
    """
    return LaunchItems.item(plist: Data(xml.utf8), path: "/Library/LaunchAgents/\(label).plist", scope: scope)
}

// MARK: - Mach-O

struct MachOTests {
    @Test func thinArm64() {
        let slices = MachO.slices(in: Header.thin(cpu: MachO.cpuTypeARM64))
        #expect(slices?.map(\.name) == ["arm64"])
        #expect(AppArchitecture(slices: slices) == .appleSilicon)
    }

    @Test func thinIntel() {
        let slices = MachO.slices(in: Header.thin(cpu: MachO.cpuTypeIntel64, subtype: 3))
        #expect(slices?.map(\.name) == ["x86_64"])
        #expect(AppArchitecture(slices: slices) == .intel)
        #expect(AppArchitecture.intel.title == "Intel only")
    }

    @Test func fatWithBoth() {
        // arm64e with the capability bits set in the subtype's top byte, as Apple's binaries have.
        let slices = MachO.slices(in: Header.fat([(MachO.cpuTypeIntel64, 3), (MachO.cpuTypeARM64, Int32(bitPattern: 0x8000_0002))]))
        #expect(slices?.map(\.name) == ["x86_64", "arm64e"])
        #expect(AppArchitecture(slices: slices) == .universal)
    }

    @Test func fat64() {
        let slices = MachO.slices(in: Header.fat([(MachO.cpuTypeARM64, 0), (MachO.cpuTypeIntel64, 8)], is64Bit: true))
        #expect(slices?.map(\.name) == ["arm64", "x86_64h"])
        #expect(AppArchitecture(slices: slices) == .universal)
    }

    @Test func fatArm64Only() {
        let slices = MachO.slices(in: Header.fat([(MachO.cpuTypeARM64, 2), (MachO.cpuTypeARM64, 12)]))
        #expect(slices?.map(\.name) == ["arm64e", "arm64e.x1"])
        #expect(AppArchitecture(slices: slices) == .appleSilicon)
    }

    @Test func oldArchitecturesWontRun() {
        let powerPC = MachO.slices(in: Header.thin(cpu: MachO.cpuTypePowerPC, is64Bit: false, bigEndian: true))
        #expect(powerPC?.map(\.name) == ["ppc"])
        #expect(AppArchitecture(slices: powerPC) == .unsupported)
        let i386 = MachO.slices(in: Header.thin(cpu: MachO.cpuTypeIntel, is64Bit: false))
        #expect(i386?.map(\.name) == ["i386"])
        #expect(AppArchitecture(slices: i386) == .unsupported)
        // A 32- and 64-bit Intel app still runs, under Rosetta.
        #expect(AppArchitecture(slices: MachO.slices(in: Header.fat([(MachO.cpuTypeIntel, 3), (MachO.cpuTypeIntel64, 3)]))) == .intel)
    }

    @Test func rejectsWhatIsNotMachO() {
        #expect(MachO.slices(in: Data("#!/bin/sh\nexec \"$0.real\"\n".utf8)) == nil)
        #expect(MachO.slices(in: Data(repeating: 0xAB, count: 4096)) == nil)
        #expect(MachO.slices(in: Data()) == nil)
        // A Java class file shares the fat magic; its version (52) reads as a slice count.
        #expect(MachO.slices(in: Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34] + [UInt8](repeating: 0, count: 2000))) == nil)
        #expect(AppArchitecture(slices: nil) == .unknown)
        #expect(AppArchitecture(slices: []) == .unknown)
    }

    @Test func rejectsTruncatedHeaders() {
        #expect(MachO.slices(in: Data([0xCF, 0xFA, 0xED])) == nil)
        #expect(MachO.slices(in: Header.thin(cpu: MachO.cpuTypeARM64).prefix(20)) == nil)
        // Claims three slices but stops after the first.
        let fat = Header.fat([(MachO.cpuTypeARM64, 0)])
        var claimsThree = [UInt8](fat.prefix(8 + 20))
        claimsThree[7] = 3
        #expect(MachO.slices(in: Data(claimsThree)) == nil)
        var none = [UInt8](fat)
        none[7] = 0
        #expect(MachO.slices(in: Data(none)) == nil)
    }

    @Test func readsAFileAndEncodesNames() throws {
        let scratch = try Scratch()
        let path = try scratch.write("tool", Header.fat([(MachO.cpuTypeARM64, 0), (MachO.cpuTypeIntel64, 3)]))
        let slices = try #require(MachO.slices(atPath: path))
        #expect(slices.map(\.name) == ["arm64", "x86_64"])
        #expect(MachO.slices(atPath: scratch.path + "/missing") == nil)

        let json = try JSONEncoder().encode(slices[0])
        #expect(String(decoding: json, as: UTF8.self).contains("\"name\":\"arm64\""))
        #expect(try JSONDecoder().decode(MachOSlice.self, from: json) == slices[0])
    }
}

// MARK: - Signing and kind

struct CodeSigningTests {
    private func signature(_ authorities: [String], identifier: String? = "com.example.app", team: String? = nil,
                           flags: UInt32? = nil) -> CodeSignature {
        var info: [String: Any] = [:]
        if let identifier { info[kSecCodeInfoIdentifier as String] = identifier }
        if let team { info[kSecCodeInfoTeamIdentifier as String] = team }
        if let flags { info[kSecCodeInfoFlags as String] = NSNumber(value: flags) }
        return CodeSigning.signature(signingInformation: info, authorities: authorities)
    }

    @Test func apple() {
        let current = signature(["macOS Software Signing", "Apple Code Signing Certification Authority", "Apple Root CA"],
                                identifier: "com.apple.Safari", flags: 0x2000)
        #expect(current.signer == .apple)
        #expect(current.teamIdentifier == nil)
        #expect(current.developerName == nil)
        #expect(!current.hardenedRuntime)
        let older = signature(["Software Signing", "Apple Code Signing Certification Authority", "Apple Root CA"], team: "59GAB85EFG")
        #expect(older.signer == .apple)
        #expect(older.teamIdentifier == "59GAB85EFG")
    }

    @Test func appStore() {
        let mac = signature(["Apple Mac OS Application Signing", "Apple Worldwide Developer Relations Certification Authority",
                             "Apple Root CA"], team: "JCRTNEU7GK", flags: 0x12000)
        #expect(mac.signer == .appStore)
        #expect(mac.hardenedRuntime)
        #expect(mac.developerName == nil)
        let phone = signature(["Apple iPhone OS Application Signing", "Apple iPhone Certification Authority", "Apple Root CA"])
        #expect(phone.signer == .appStore)
    }

    @Test func developerID() {
        let chrome = signature(["Developer ID Application: Google LLC (EQHXZ8M8AV)", "Developer ID Certification Authority",
                                "Apple Root CA"], identifier: "com.google.Chrome", team: "EQHXZ8M8AV", flags: 0x12A00)
        #expect(chrome.signer == .developerID)
        #expect(chrome.developerName == "Google LLC")
        #expect(chrome.teamIdentifier == "EQHXZ8M8AV")
        #expect(chrome.identifier == "com.google.Chrome")
        #expect(chrome.hardenedRuntime)
    }

    @Test func developmentAndOtherCertificates() {
        let development = signature(["Apple Development: Jane Appleseed (ABCDE12345)",
                                     "Apple Worldwide Developer Relations Certification Authority", "Apple Root CA"])
        #expect(development.signer == .development)
        #expect(development.developerName == "Jane Appleseed")
        #expect(signature(["AudioWhisper Rebuild Local Development"]).signer == .otherCertificate)
        // Developer ID by name only, from a chain that doesn't end at Apple's root.
        let impostor = signature(["Developer ID Application: Evil (EVIL000000)", "Evil CA", "Evil Root"])
        #expect(impostor.signer == .otherCertificate)
        #expect(impostor.developerName == nil)
        #expect(signature(["Something Else", "Apple Root CA"]).signer == .otherCertificate)
    }

    @Test func adHocAndUnsigned() {
        #expect(signature([], identifier: "AudioWhisper", flags: 0x2_0002).signer == .adHoc)
        #expect(signature([], identifier: "a.out", flags: 0x2).signer == .adHoc)
        #expect(signature([], identifier: nil).signer == .unsigned)
        #expect(signature([], identifier: "x", flags: 0).signer == .unknown)
        #expect(signature([], team: "").teamIdentifier == nil)
    }

    @Test func readsRealSignatures() throws {
        #expect(CodeSigning.signature(atPath: "/System/Applications/Calculator.app").signer == .apple)
        #expect(CodeSigning.signature(atPath: "/nonexistent/Nothing.app").signer == .unknown)
        let scratch = try Scratch()
        let script = try scratch.write("Script.app/Contents/MacOS/Script", Data("#!/bin/sh\n".utf8))
        let signer = CodeSigning.signature(atPath: script).signer
        #expect(signer == .unsigned || signer == .unknown)
    }

    @Test func kinds() {
        func kind(_ path: String, resolved: String? = nil, id: String?, receipt: Bool = false, signer: AppSigner) -> AppKind {
            InstalledApps.kind(path: path, resolvedPath: resolved ?? path, bundleIdentifier: id,
                               hasAppStoreReceipt: receipt, signer: signer)
        }
        #expect(kind("/System/Applications/Calculator.app", id: "com.apple.calculator", signer: .apple) == .apple)
        #expect(kind("/Applications/Safari.app", resolved: "/System/Cryptexes/App/System/Applications/Safari.app",
                     id: "com.apple.Safari", signer: .unknown) == .apple)
        #expect(kind("/Applications/Xcode.app", id: "com.apple.dt.Xcode", signer: .apple) == .apple)
        #expect(kind("/Applications/Pages.app", id: "com.apple.Pages", receipt: true, signer: .appStore) == .apple)
        // Apple's bundle ID without Apple's signature is somebody else's app.
        #expect(kind("/Applications/Fake.app", id: "com.apple.fake", signer: .developerID) == .thirdParty)
        #expect(kind("/Applications/Things.app", id: "com.culturedcode.ThingsMac", receipt: true, signer: .appStore) == .appStore)
        #expect(kind("/Applications/Old.app", id: "com.example.old", receipt: true, signer: .unknown) == .appStore)
        #expect(kind("/Applications/Test.app", id: "com.example.test", signer: .appStore) == .appStore)
        #expect(kind("/Applications/Chrome.app", id: "com.google.Chrome", signer: .developerID) == .thirdParty)
        #expect(kind("/Applications/Tool.app", id: nil, signer: .adHoc) == .thirdParty)
    }
}

// MARK: - Finding and reading bundles

struct InstalledAppDiscoveryTests {
    @Test func deduplicatesByResolvedPath() {
        let links = [
            "/Applications/Safari.app": "/System/Cryptexes/App/System/Applications/Safari.app",
            "/Applications/Utilities/Feedback Assistant.app": "/System/Library/CoreServices/Applications/Feedback Assistant.app",
        ]
        let locations = InstalledApps.deduplicate([
            "/Applications/Safari.app",
            "/System/Volumes/Data/Applications/Safari.app",
            "/Applications/Ghostty.app/",
            "/Applications/Utilities/Feedback Assistant.app",
            "/System/Library/CoreServices/Applications/Feedback Assistant.app",
            "/Applications/Xcode.app",
            "/Applications/Xcode-beta.app",
            "/Applications/Ghostty.app",
        ], resolve: { links[$0] ?? $0 })
        #expect(locations == [
            BundleLocation(path: "/Applications/Safari.app", resolved: "/System/Cryptexes/App/System/Applications/Safari.app"),
            BundleLocation(path: "/Applications/Ghostty.app", resolved: "/Applications/Ghostty.app"),
            BundleLocation(path: "/Applications/Utilities/Feedback Assistant.app",
                           resolved: "/System/Library/CoreServices/Applications/Feedback Assistant.app"),
            BundleLocation(path: "/Applications/Xcode.app", resolved: "/Applications/Xcode.app"),
            BundleLocation(path: "/Applications/Xcode-beta.app", resolved: "/Applications/Xcode-beta.app"),
        ])
        #expect(InstalledApps.normalized("/System/Volumes/Data/Users/me/Applications/A.app") == "/Users/me/Applications/A.app")
    }

    @Test func filtersSpotlightResults() {
        let listed = [
            "/Applications/Foo.app",
            "/Users/me/Downloads/Tool.app",
            "/Users/me/Applications/Chrome Apps.localized/Google Photos.app",
            "/Volumes/External/Applications/KiCad/KiCad.app",
            "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app",
            "/System/Volumes/Data/Applications/Bar.app",
        ]
        for path in listed {
            #expect(InstalledApps.isListable(spotlightPath: path, home: "/Users/me"), "\(path)")
        }
        let left = [
            "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app",
            "/Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/Steam Helper.app",
            "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app",
            "/Users/me/.Trash/Old.app",
            "/Users/me/project/.build/Debug/Thing.app",
            "/Users/me/project/node_modules/electron/dist/Electron.app",
            "/Users/me/Library/Developer/Xcode/DerivedData/X/Build/Products/Debug/X.app",
            "/System/Library/CoreServices/Dock.app",
            "/Library/Apple/System/Library/CoreServices/XProtect.app",
            "/private/var/folders/ab/xyz/T/AppTranslocation/1234/d/Foo.app",
            "/Volumes/Installer/Foo.app",
            "/Volumes/Backup/Projects/Thing.app",
            "/Library/Application Support/Script Editor/Templates/Droplets/Droplet.app",
            "/Applications/readme.txt",
        ]
        for path in left {
            #expect(!InstalledApps.isListable(spotlightPath: path, home: "/Users/me"), "\(path)")
        }
    }

    @Test func walksFoldersButNotBundles() throws {
        let scratch = try Scratch()
        try scratch.write("A.app/Contents/Info.plist")
        try scratch.folder("A.app/Contents/Helpers/Inner.app/Contents")
        try scratch.folder("Vendor/B.app/Contents")
        try scratch.folder("Utilities/C.app")
        try scratch.folder("Deep/1/2/3/4/Far.app")
        try scratch.folder("Deep/1/2/3/Near.app")
        try scratch.folder(".hidden/D.app")
        try scratch.write("notes.txt")
        // The walker may drop the /private in front of /var, so compare the part below the scratch folder.
        let marker = scratch.url.lastPathComponent + "/"
        let found = Set(InstalledApps.bundles(inFolder: scratch.path, depth: 5).map { $0.components(separatedBy: marker).last ?? $0 })
        #expect(found == ["A.app", "Vendor/B.app", "Utilities/C.app", "Deep/1/2/3/Near.app"])
        #expect(InstalledApps.bundles(inFolder: scratch.path + "/missing", depth: 5).isEmpty)
    }

    @Test func readsAMacBundle() throws {
        let scratch = try Scratch()
        try scratch.plist("Tool.app/Contents/Info.plist", [
            "CFBundleIdentifier": "com.example.tool", "CFBundleExecutable": "Tool",
            "CFBundleShortVersionString": "2.1", "CFBundleVersion": "210", "LSMinimumSystemVersion": "13.0",
        ])
        try scratch.write("Tool.app/Contents/MacOS/Tool", Header.fat([(MachO.cpuTypeIntel64, 3)]))
        try scratch.write("Tool.app/Contents/_MASReceipt/receipt", Data("receipt".utf8))
        let path = scratch.path + "/Tool.app"
        let app = try #require(InstalledApps.read(bundleAt: path, resolvedPath: path))
        #expect(app.name == "Tool")
        #expect(app.id == path)
        #expect(app.bundleIdentifier == "com.example.tool")
        #expect(app.versionText == "2.1 (210)")
        #expect(app.minimumSystemVersion == "13.0")
        #expect(app.executablePath == path + "/Contents/MacOS/Tool")
        #expect(app.architecture == .intel)
        #expect(app.sliceNames == "x86_64")
        #expect(app.hasAppStoreReceipt)
        #expect(app.kind == .appStore)
        #expect(!app.isiOSApp)
        #expect(app.launchItems.isEmpty)
        #expect(app.matches("example.tool") && app.matches("TOOL") && !app.matches("chrome"))
    }

    @Test func readsAWrappedIPhoneApp() throws {
        let scratch = try Scratch()
        try scratch.plist("Wrapped.app/Wrapper/Inner.app/Info.plist", [
            "CFBundleIdentifier": "com.example.ios", "CFBundleExecutable": "Inner", "MinimumOSVersion": "17.0",
        ])
        try scratch.write("Wrapped.app/Wrapper/Inner.app/Inner", Header.thin(cpu: MachO.cpuTypeARM64))
        try scratch.plist("Wrapped.app/Wrapper/iTunesMetadata.plist", ["itemId": 1])
        try FileManager.default.createSymbolicLink(atPath: scratch.path + "/Wrapped.app/WrappedBundle",
                                                   withDestinationPath: "Wrapper/Inner.app")
        let path = scratch.path + "/Wrapped.app"
        let app = try #require(InstalledApps.read(bundleAt: path, resolvedPath: path))
        #expect(app.isiOSApp)
        #expect(app.bundleIdentifier == "com.example.ios")
        #expect(app.executablePath == path + "/Wrapper/Inner.app/Inner")
        #expect(app.architecture == .appleSilicon)
        #expect(app.hasAppStoreReceipt)
        #expect(app.kind == .appStore)
        #expect(app.minimumSystemVersion == "17.0")
        #expect(app.versionText == "—")
    }

    @Test func skipsWhatIsNotABundleFolder() throws {
        let scratch = try Scratch()
        let file = try scratch.write("Fake.app", Data("not a folder".utf8))
        #expect(InstalledApps.read(bundleAt: file, resolvedPath: file) == nil)
        #expect(InstalledApps.read(bundleAt: scratch.path + "/Gone.app", resolvedPath: scratch.path + "/Gone.app") == nil)
    }

    @Test func spotsFacelessHelpers() throws {
        let scratch = try Scratch()
        try scratch.plist("Helper.app/Contents/Info.plist", ["LSBackgroundOnly": true])
        try scratch.plist("Old.app/Contents/Info.plist", ["LSBackgroundOnly": "1"])
        try scratch.plist("MenuBar.app/Contents/Info.plist", ["LSUIElement": true])
        try scratch.plist("Off.app/Contents/Info.plist", ["LSBackgroundOnly": false])
        #expect(InstalledApps.isBackgroundOnly(bundleAt: scratch.path + "/Helper.app"))
        #expect(InstalledApps.isBackgroundOnly(bundleAt: scratch.path + "/Old.app"))
        // A menu bar app has no Dock icon but does show windows, so it stays.
        #expect(!InstalledApps.isBackgroundOnly(bundleAt: scratch.path + "/MenuBar.app"))
        #expect(!InstalledApps.isBackgroundOnly(bundleAt: scratch.path + "/Off.app"))
        #expect(!InstalledApps.isBackgroundOnly(bundleAt: scratch.path + "/Missing.app"))
    }

    @Test func measuresAllocatedSize() throws {
        let scratch = try Scratch()
        try scratch.write("Big.app/Contents/Resources/data", Data(repeating: 7, count: 10_000))
        try scratch.write("Big.app/Contents/Info.plist", Data(repeating: 1, count: 100))
        let size = try #require(InstalledApps.allocatedSize(ofBundleAt: scratch.path + "/Big.app"))
        #expect(size >= 10_100)
        for index in 0..<600 { try scratch.write("Many.app/f\(index)") }
        #expect(InstalledApps.allocatedSize(ofBundleAt: scratch.path + "/Many.app", isCancelled: { true }) == nil)
        #expect(InstalledApps.allocatedSize(ofBundleAt: scratch.path + "/Many.app") != nil)
    }

    @Test func versionTextAndFolder() {
        #expect(app("/Applications/A.app", id: nil).versionText == "1.0 (1)")
        let same = InstalledApp(path: "/Users/me/Applications/Tools/B.app", resolvedPath: "/Users/me/Applications/Tools/B.app",
                                name: "B", bundleIdentifier: nil, version: "3.0", build: "3.0", minimumSystemVersion: nil,
                                executablePath: nil, kind: .thirdParty, hasAppStoreReceipt: false, isiOSApp: false,
                                slices: nil, signature: .unknown, lastOpened: nil, added: nil)
        #expect(same.versionText == "3.0")
        #expect(same.folder(home: "/Users/me") == "~/Applications/Tools")
        #expect(same.folder(home: "/Users/m") == "/Users/me/Applications/Tools")
        #expect(app("/Applications/A.app", id: nil).folder(home: "/Users/me") == "/Applications")
    }
}

// MARK: - Matching

struct InstalledAppMatchingTests {
    @Test func launchItemsBelongingToAnApp() {
        let oneDrive = app("/Applications/OneDrive.app", id: "com.microsoft.OneDrive")
        let updater = launchItem(label: "com.microsoft.OneDriveStandaloneUpdaterDaemon",
                                 program: "/Applications/OneDrive.app/Contents/StandaloneUpdaterDaemon.xpc/Contents/MacOS/Updater")
        let finderSync = launchItem(label: "com.microsoft.onedrive.FinderSync", program: "/usr/libexec/helper")
        let opener = launchItem(label: "local.open-onedrive", arguments: ["/usr/bin/open", "-a", "/Applications/OneDrive.app"])
        let lookalikeLabel = launchItem(label: "com.microsoft.OneDriveUpdater", program: "/Library/OneDriveUpdater")
        let lookalikePath = launchItem(label: "x.y", program: "/Applications/OneDrive.app.old/Contents/MacOS/OneDrive")
        let items = [updater, finderSync, opener, lookalikeLabel, lookalikePath]
        #expect(InstalledApps.launchItems(for: oneDrive, in: items) == [updater, finderSync, opener])

        let noIdentifier = app("/Applications/Thing.app", id: nil)
        #expect(InstalledApps.launchItems(for: noIdentifier, in: items).isEmpty)

        // A program inside the resolved bundle belongs to the app found through a link.
        let safari = app("/Applications/Safari.app", resolved: "/System/Cryptexes/App/System/Applications/Safari.app",
                         id: "com.apple.Safari")
        let history = launchItem(label: "com.apple.Safari.History", program: "/usr/libexec/SafariHistory")
        let bookmarks = launchItem(label: "com.example.bookmarks",
                                   program: "/System/Cryptexes/App/System/Applications/Safari.app/Contents/XPCServices/B.xpc/B")
        #expect(InstalledApps.attach([history, bookmarks, updater], to: [safari, oneDrive]).map(\.launchItems)
            == [[history, bookmarks], [updater]])
    }

    @Test func startsItselfOnlyForItemsLaunchdStarts() {
        let atLogin = launchItem(label: "com.example.agent", extra: "<key>RunAtLoad</key><true/>")
        let hourly = launchItem(label: "com.example.hourly", extra: "<key>StartInterval</key><integer>3600</integer>")
        let onDemand = launchItem(label: "com.example.xpc", extra: "<key>MachServices</key><dict><key>com.example.xpc</key><true/></dict>")
        let disabled = launchItem(label: "com.example.off", extra: "<key>RunAtLoad</key><true/><key>Disabled</key><true/>")
        #expect(atLogin.startsOnItsOwn && hourly.startsOnItsOwn)
        #expect(!onDemand.startsOnItsOwn && !disabled.startsOnItsOwn)

        let quiet = app("/Applications/Example.app", id: "com.example", launchItems: [onDemand, disabled])
        #expect(!quiet.startsItself)
        let busy = app("/Applications/Example.app", id: "com.example", launchItems: [onDemand, atLogin, hourly])
        #expect(busy.startsItself)
        #expect(busy.selfStartingItems == [atLogin, hourly])
    }

    @Test func startupSearchFindsTheAppsItems() {
        let byLabel = launchItem(label: "com.microsoft.OneDriveStandaloneUpdaterDaemon", program: "/Library/Updater")
        let byHelper = launchItem(label: "com.microsoft.onedrive.FinderSync", program: "/usr/libexec/helper")
        let oneDrive = app("/Applications/OneDrive.app", id: "com.microsoft.OneDrive", launchItems: [byLabel, byHelper])
        #expect(oneDrive.startupSearchText == "com.microsoft.OneDrive")

        // Labels that don't carry the bundle ID: the programs' shared path finds them.
        let first = launchItem(label: "net.example.agent", program: "/Applications/Tool.app/Contents/MacOS/agent")
        let second = launchItem(label: "net.example.daemon", program: "/Applications/Tool.app/Contents/Library/daemon")
        let tool = app("/Applications/Tool.app", id: "com.example.tool", launchItems: [first, second])
        #expect(tool.startupSearchText == "/Applications/Tool.app")
        #expect(app("/Applications/Quiet.app", id: "com.example.quiet").startupSearchText == nil)
    }

    @Test func findsTheAppANameOrBundleIDMeans() {
        let safari = app("/Applications/Safari.app", id: "com.apple.Safari")
        let preview = app("/Applications/Safari Technology Preview.app", id: "com.apple.SafariTechnologyPreview")
        let xcode = app("/Applications/Xcode.app", id: "com.apple.dt.Xcode")
        let scanner = app("/Library/Image Capture/AirScanLegacyDiscovery.app", id: "com.apple.AirScanLegacyDiscovery")
        let legacy = app("/Applications/Legacy Tool.app", id: "com.example.legacytool")
        // Sorted by name, as the scan returns them, with the longer name first to show exact names win.
        let apps = [scanner, legacy, preview, safari, xcode]
        #expect(InstalledApps.find("safari", in: apps) == safari)
        #expect(InstalledApps.find(" com.apple.SafariTechnologyPreview ", in: apps) == preview)
        // A name that starts with it beats one that merely contains it.
        #expect(InstalledApps.find("legacy", in: apps) == legacy)
        #expect(InstalledApps.find("Technology", in: apps) == preview)
        #expect(InstalledApps.find("dt.xcode", in: apps) == xcode)
        #expect(InstalledApps.find("Chrome", in: apps) == nil)
        #expect(InstalledApps.find("  ", in: apps) == nil)
    }

    @Test func runningAppsMatchByPathThenUniqueBundleID() {
        let safari = app("/Applications/Safari.app", resolved: "/System/Cryptexes/App/System/Applications/Safari.app",
                         id: "com.apple.Safari")
        let xcode = app("/Applications/Xcode.app", id: "com.apple.dt.Xcode")
        let beta = app("/Applications/Xcode-beta.app", id: "com.apple.dt.Xcode")
        let ghostty = app("/Applications/Ghostty.app", id: "com.mitchellh.ghostty")
        let running = [
            RunningAppReference(pid: 10, bundlePath: "/System/Cryptexes/App/System/Applications/Safari.app",
                                bundleIdentifier: "com.apple.Safari"),
            RunningAppReference(pid: 11, bundlePath: "/Applications/Xcode-beta.app", bundleIdentifier: "com.apple.dt.Xcode"),
            // Two installed apps share this ID, so without a path it matches neither.
            RunningAppReference(pid: 12, bundlePath: nil, bundleIdentifier: "com.apple.dt.Xcode"),
            RunningAppReference(pid: 14, bundlePath: "/private/var/folders/x/AppTranslocation/1/d/Ghostty.app",
                                bundleIdentifier: "com.mitchellh.Ghostty"),
            RunningAppReference(pid: 13, bundlePath: "/Applications/Ghostty.app", bundleIdentifier: "com.mitchellh.ghostty"),
            RunningAppReference(pid: 15, bundlePath: "/Applications/Other.app", bundleIdentifier: "com.example.other"),
            RunningAppReference(pid: 16, bundlePath: "/Applications/Link.app", bundleIdentifier: nil),
        ]
        let links = ["/Applications/Link.app": "/Applications/Xcode.app"]
        let pids = InstalledApps.runningPIDs(of: [safari, xcode, beta, ghostty], running: running, resolve: { links[$0] ?? $0 })
        #expect(pids == [safari.id: [10], beta.id: [11], ghostty.id: [13, 14], xcode.id: [16]])
    }
}

// MARK: - Bounded work

struct BoundedWorkTests {
    @Test func mapKeepsOrder() {
        let squares = BoundedWork.map(Array(0..<200), width: 4) { $0 * $0 }
        #expect(squares == (0..<200).map { $0 * $0 })
        #expect(BoundedWork.map([Int](), width: 4) { $0 }.isEmpty)
    }

    @Test func stopsWhenCancelled() {
        let flag = CancellationFlag()
        let seen = Counter()
        let work: @Sendable (Int) -> Void = { _ in
            if seen.increment() >= 10 { flag.set() }
        }
        BoundedWork.forEach(Array(0..<1000), width: 2, isCancelled: { flag.isSet }, work)
        #expect(flag.isSet)
        #expect(seen.value < 1000)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

// MARK: - This Mac

struct InstalledAppsLiveTests {
    @Test func findsAppleAppsInSystemApplications() throws {
        let paths = InstalledApps.bundles(inFolder: "/System/Applications", depth: 2)
        #expect(paths.contains("/System/Applications/Utilities/Terminal.app"))
        let apps = BoundedWork.map(paths, width: 4) { InstalledApps.read(bundleAt: $0, resolvedPath: InstalledApps.resolved($0)) }
            .compactMap { $0 }
        #expect(apps.count == paths.count)
        let native = apps.filter { $0.kind == .apple && $0.signature.signer == .apple && $0.slices?.contains(where: \.isARM64) == true }
        #expect(!native.isEmpty)
        let calculator = try #require(apps.first { $0.bundleIdentifier == "com.apple.calculator" })
        #expect(calculator.name == "Calculator")
        #expect(calculator.signature.authorities.last == "Apple Root CA")
    }

    @Test func scanListsEachBundleOnce() {
        let apps = InstalledApps.scan(useSpotlight: false, launchItems: [])
        #expect(!apps.isEmpty)
        #expect(Set(apps.map(\.id)).count == apps.count)
        #expect(apps.contains { $0.path == "/System/Library/CoreServices/Finder.app" })
    }
}
