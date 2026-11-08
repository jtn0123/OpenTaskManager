import Foundation

extension Format {
    /// Between the folders of a trail, as the Storage page writes them.
    public static let trailSeparator = " › "

    /// Where `path` is below `folder`, folder by folder: "Projects › webapp
    /// › build" for "/demo/Projects/webapp/build" below "/demo". Both may be
    /// absolute or below a scanned folder ("Projects/webapp"). Empty for
    /// `folder` itself; a path outside `folder` gives its whole trail.
    public static func trail(_ path: String, under folder: String = "") -> String {
        trailNames(path, under: folder).joined(separator: trailSeparator)
    }

    /// The names `trail` joins, for drawing them one by one.
    public static func trailNames(_ path: String, under folder: String = "") -> [String] {
        let names = path.split(separator: "/")
        let base = folder.split(separator: "/")
        let inside = names.count >= base.count && names.starts(with: base)
        return (inside ? names.dropFirst(base.count) : names[...]).map(String.init)
    }
}

/// A path as a details pane shows it: the name it ends in, which tells one
/// file from another, over the folder that holds it. Trailing slashes don't
/// count; a bare name or the root has no folder.
public struct PathParts: Sendable, Hashable {
    public var name: String
    public var folder: String?

    public init(_ path: String) {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard trimmed.count > 1, let slash = trimmed.lastIndex(of: "/") else {
            name = String(trimmed)
            folder = nil
            return
        }
        name = String(trimmed[trimmed.index(after: slash)...])
        // "/bin" is in "/", not in an empty folder.
        folder = slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }
}
