import Foundation
import UniformTypeIdentifiers

/// How the files inside a folder are classified.
public enum DiskRegion: Sendable, Equatable {
    /// Each file by its type.
    case byType
    /// By type, but files without a telling type (data, text, property
    /// lists) count as this category. `~/Library` is app support, so a JSON
    /// file there isn't one of your documents, while a video still is video.
    case fallback(DiskCategory)
    /// Everything inside is this category, whatever its type (`node_modules`,
    /// `~/Library/Caches`).
    case fixed(DiskCategory)
}

/// The rules that sort a scan's bytes into categories: a file's type
/// (UTType conformance) plus a few folders that decide for everything inside
/// them. Pure, so they're tested without touching the disk.
public struct DiskCategoryRules: Sendable {
    /// Home folder, for the rules written relative to it.
    public let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    // MARK: - Folders

    /// Developer tool output and package caches, wherever they sit.
    static let developerFolders: Set<String> = [
        "node_modules", "DerivedData", ".git", ".svn", ".hg", "Pods", "Carthage", "__pycache__", ".venv",
        ".gradle", ".m2", ".cargo", ".rustup", ".npm", ".pnpm-store", ".yarn", ".build", ".swiftpm", ".tox",
        ".terraform",
    ]

    /// Cache folders apps make inside their own support folders.
    static let cacheFolders: Set<String> = ["Caches", ".cache", "Cache", "Code Cache", "GPUCache", "CachedData", "ShaderCache"]

    /// Folders matched by absolute path.
    static let systemPaths: [String: DiskRegion] = [
        "/System": .fixed(.system),
        "/System/Applications": .fixed(.apps),
        "/Applications": .fixed(.apps),
        "/Library": .fallback(.system),
        "/Library/Developer": .fixed(.developer),
        "/usr": .fixed(.system),
        "/usr/local": .fixed(.developer),
        "/bin": .fixed(.system),
        "/sbin": .fixed(.system),
        "/opt/homebrew": .fixed(.developer),
        "/opt/local": .fixed(.developer),
        "/nix": .fixed(.developer),
        "/private": .fixed(.system),
        "/private/var/log": .fixed(.caches),
        "/private/var/folders": .fixed(.caches),
        "/private/var/db/diagnostics": .fixed(.caches),
        "/private/var/db/uuidtext": .fixed(.caches),
        "/cores": .fixed(.system),
    ]

    /// Folders matched relative to any user's home ("Library/Developer" is
    /// `~/Library/Developer`).
    static let homePaths: [String: DiskRegion] = [
        "Applications": .fixed(.apps),
        "Library": .fallback(.system),
        "Library/Developer": .fixed(.developer),
        "Library/Mobile Documents": .byType,
        "Library/CloudStorage": .byType,
        "Library/Group Containers/group.com.apple.CoreSimulator": .fixed(.developer),
    ]

    /// Deepest path any rule matches, so the scanner only builds paths for
    /// folders shallow enough to match.
    static let maximumRuleDepth = 5

    /// The region a folder starts, given the region of the folder it's in.
    /// The innermost rule wins: `node_modules` inside `~/Library` is
    /// Developer. `path` is only asked for when the folder is shallow enough
    /// for a path rule to match; `depth` counts components from `/`.
    public func region(forFolder name: String, parentName: String?, depth: Int, path: () -> String,
                       inside parent: DiskRegion) -> DiskRegion {
        if Self.developerFolders.contains(name) { return .fixed(.developer) }
        if Self.cacheFolders.contains(name) { return .fixed(.caches) }
        if name == "Logs", parentName == "Library" { return .fixed(.caches) }
        if depth <= Self.maximumRuleDepth, let region = pathRegion(path()) { return region }
        return parent
    }

    /// The region at an absolute path, applying the rules to each folder from `/` down.
    public func region(at path: String) -> DiskRegion {
        var region = DiskRegion.byType
        var current = ""
        var parentName: String?
        let components = path.split(separator: "/").map(String.init)
        for (index, name) in components.enumerated() {
            current += "/" + name
            let folder = current
            region = self.region(forFolder: name, parentName: parentName, depth: index + 1, path: { folder }, inside: region)
            parentName = name
        }
        return region
    }

    private func pathRegion(_ path: String) -> DiskRegion? {
        if let region = Self.systemPaths[path] { return region }
        // Any home: the current user's, or another under /Users when scanning the whole disk.
        let relative: Substring
        if path.hasPrefix(home + "/") {
            relative = path.dropFirst(home.count + 1)
        } else if path.hasPrefix("/Users/") {
            let rest = path.dropFirst("/Users/".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            relative = rest[rest.index(after: slash)...]
        } else {
            return nil
        }
        return Self.homePaths[String(relative)]
    }

    // MARK: - Files

    /// The category of a file, or of a package as a whole, in a region.
    public static func category(ofType typeCategory: DiskCategory, in region: DiskRegion) -> DiskCategory {
        switch region {
        case .byType:
            return typeCategory
        case let .fixed(category):
            return category
        case let .fallback(category):
            // Big media, installers and apps stand out wherever they are;
            // documents, code and data in a support folder belong to it.
            switch typeCategory {
            case .apps, .media, .audio, .archives, .caches: return typeCategory
            default: return category
            }
        }
    }

    /// The region inside a package: its own type decides for everything in
    /// it (an app is Apps, a Photos library is Photos & Video), unless the
    /// package sits in a fixed region already.
    public static func region(insidePackage typeCategory: DiskCategory, in parent: DiskRegion) -> DiskRegion {
        if case .fixed = parent { return parent }
        guard typeCategory != .other, category(ofType: typeCategory, in: parent) == typeCategory else { return parent }
        return .fixed(typeCategory)
    }

    /// The category a file's type suggests, from its uniform type identifier
    /// (`URLResourceValues.typeIdentifier`). `size` separates TypeScript
    /// source from MPEG transport streams, which share the `.ts` extension.
    public static func category(forType identifier: String?, size: UInt64 = 0) -> DiskCategory {
        guard let identifier else { return .other }
        if identifier == UTType.mpeg2TransportStream.identifier, size < 1 << 20 { return .developer }
        return category(forType: identifier)
    }

    static func category(forType identifier: String) -> DiskCategory {
        if let category = namedTypes[identifier] { return category }
        if identifier.hasPrefix("com.apple.xcode.") || identifier.hasPrefix("com.apple.dt.") { return .developer }
        if identifier.hasPrefix("com.apple.FinalCut") || identifier.hasPrefix("com.apple.iMovie") { return .media }
        if identifier.hasPrefix("com.apple.logic") || identifier.hasPrefix("com.apple.garageband") { return .audio }
        guard !identifier.hasPrefix("dyn."), let type = UTType(identifier) else { return .other }
        return category(for: type)
    }

    /// Package and library types that conform to nothing more telling than "package".
    static let namedTypes: [String: DiskCategory] = [
        "com.apple.photos.library": .media,
        "com.apple.music.library": .audio,
        "com.apple.itunes.library": .audio,
        "com.apple.tv.library": .media,
        "public.object-code": .developer,
        "com.apple.text-based-dylib": .developer,
    ]

    /// Classifies by conformance, most specific first: an app before an
    /// executable, a disk image before data, audio before audiovisual.
    public static func category(for type: UTType) -> DiskCategory {
        if type.conforms(to: .application) { return .apps }
        if type.conforms(to: .diskImage) || type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .log) { return .caches }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .media }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .developer }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .compositeContent) || type.conforms(to: .text) {
            return .documents
        }
        return .other
    }
}
