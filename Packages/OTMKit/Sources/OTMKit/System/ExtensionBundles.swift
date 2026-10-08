import Foundation

/// An extension bundle found on disk, whether or not macOS uses it: a kext in
/// /Library/Extensions or inside an app, or a system extension an app carries.
public struct ExtensionBundle: Sendable, Codable, Hashable {
    public let path: String
    /// The app it's inside; nil for a kext in /Library/Extensions.
    public let appPath: String?
    /// `.kernel` for a kext; for a system extension, what its Info.plist says
    /// it is (a network or endpoint security extension, a DriverKit driver).
    public let category: ExtensionCategory
    /// Nil when its Info.plist couldn't be read.
    public let bundleID: String?
    public let name: String
    /// `CFBundleShortVersionString`.
    public let version: String?
    /// `CFBundleVersion`.
    public let build: String?
    /// The developer's Team ID from its signature; nil when it has none
    /// (Apple's own, ad hoc, unsigned) or the signature couldn't be read.
    public let teamID: String?
    public let signer: AppSigner

    public init(path: String, appPath: String?, category: ExtensionCategory, bundleID: String?, name: String,
                version: String?, build: String?, teamID: String?, signer: AppSigner) {
        self.path = path
        self.appPath = appPath
        self.category = category
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.build = build
        self.teamID = teamID
        self.signer = signer
    }

    /// The version macOS reports for one in use: the kernel gives a kext's
    /// `CFBundleVersion`, systemextensionsctl a system extension's short version.
    public var reportedVersion: String? {
        category == .kernel ? build ?? version : version ?? build
    }

    /// The app's name as Finder shows it without ".app".
    public var appName: String? { appPath.map(Extensions.appName) }
}

/// Where to look for extension bundles. Only these folders and one level
/// into each app are read: never a deep walk, and never a protected folder.
public struct ExtensionFolders: Sendable, Hashable {
    /// Folders whose `*.kext` bundles are listed.
    public var kernelExtensionFolders: [String]
    /// Folders whose `*.app` bundles are looked into, at
    /// Contents/Library/Extensions and Contents/Library/SystemExtensions.
    public var appFolders: [String]

    public init(kernelExtensionFolders: [String], appFolders: [String]) {
        self.kernelExtensionFolders = kernelExtensionFolders
        self.appFolders = appFolders
    }

    /// /Library/Extensions and the two Applications folders. Apple's sealed
    /// /System/Library/Extensions is left out: hundreds of unloaded Apple
    /// kexts would bury the few that matter.
    public static func standard(home: String = NSHomeDirectory()) -> Self {
        Self(kernelExtensionFolders: ["/Library/Extensions"], appFolders: ["/Applications", home + "/Applications"])
    }

    public static let none = Self(kernelExtensionFolders: [], appFolders: [])
}

/// Finds extension bundles on disk and reads each one's Info.plist and signature.
public enum ExtensionBundles {
    /// A bundle as found, before it's read.
    public struct Location: Sendable, Hashable {
        public let path: String
        public let appPath: String?
    }

    /// Network and endpoint security extensions are `.systemextension`;
    /// DriverKit drivers are `.dext`.
    static let systemExtensionSuffixes: Set<String> = ["systemextension", "dext"]

    /// Finds and reads every bundle in `folders`. A few dozen at most on a
    /// busy Mac, each a property list and a signature, so a few milliseconds;
    /// still, call it off the main actor.
    public static func scan(_ folders: ExtensionFolders,
                            signature: (String) -> CodeSignature = CodeSigning.signature(atPath:)) -> [ExtensionBundle] {
        find(in: folders).map { read($0, signature: signature) }
    }

    /// The kexts in each kernel extension folder, then each app's kexts and
    /// system extensions, by path. A copy reached twice through a link is
    /// kept once. Unreadable or missing folders are skipped quietly.
    public static func find(in folders: ExtensionFolders) -> [Location] {
        var found = folders.kernelExtensionFolders.flatMap { folder in
            entries(of: folder) { $0 == "kext" }.map { Location(path: $0, appPath: nil) }
        }
        for folder in folders.appFolders {
            for app in entries(of: folder, where: { $0 == "app" }) {
                let library = app + "/Contents/Library"
                found += entries(of: library + "/Extensions") { $0 == "kext" }.map { Location(path: $0, appPath: app) }
                found += entries(of: library + "/SystemExtensions", where: systemExtensionSuffixes.contains)
                    .map { Location(path: $0, appPath: app) }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path).inserted }
    }

    /// The visible entries of `folder` whose extension passes `matches`, by
    /// name, as full paths. Empty when the folder can't be listed.
    static func entries(of folder: String, where matches: (String) -> Bool) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { !$0.hasPrefix(".") && matches(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    /// Reads one bundle's Info.plist (Contents/Info.plist, or Info.plist at
    /// the top of a shallow DriverKit bundle) and its signature.
    public static func read(_ location: Location, signature: (String) -> CodeSignature) -> ExtensionBundle {
        let path = location.path
        let fileExtension = (path as NSString).pathExtension.lowercased()
        let info = propertyList(path + "/Contents/Info.plist") ?? propertyList(path + "/Info.plist")
        let bundleID = text(info?["CFBundleIdentifier"])
        let category: ExtensionCategory = fileExtension == "kext" ? .kernel : systemCategory(info: info ?? [:], fileExtension: fileExtension)
        let signed = signature(path)
        return ExtensionBundle(
            path: path, appPath: location.appPath, category: category, bundleID: bundleID,
            name: name(info: info ?? [:], bundleID: bundleID, path: path, isKernel: category == .kernel),
            version: text(info?["CFBundleShortVersionString"]), build: text(info?["CFBundleVersion"]),
            teamID: signed.teamIdentifier, signer: signed.signer
        )
    }

    /// What a system extension is for, from the keys its Info.plist must have:
    /// `NetworkExtension` for a network extension, the endpoint security Mach
    /// service for a security tool, and IOKit personalities (or a `.dext`)
    /// for a DriverKit driver.
    static func systemCategory(info: [String: Any], fileExtension: String) -> ExtensionCategory {
        if fileExtension == "dext" || info["IOKitPersonalities"] != nil { return .driver }
        if info["NetworkExtension"] != nil { return .network }
        if info["NSEndpointSecurityMachServiceName"] != nil || info["NSEndpointSecurityEarlyBoot"] != nil { return .endpointSecurity }
        return .otherSystem
    }

    /// A kext goes by its file name, as loaded ones do; a system extension by
    /// its display name, as systemextensionsctl prints it, else its bundle
    /// name unless that's just the identifier, else words from the identifier.
    static func name(info: [String: Any], bundleID: String?, path: String, isKernel: Bool) -> String {
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if isKernel { return file }
        if let display = text(info["CFBundleDisplayName"]) { return display }
        if let name = text(info["CFBundleName"]), name != bundleID { return name }
        return bundleID.map(LaunchItems.displayName(forLabel:)) ?? file
    }

    private static func propertyList(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}
