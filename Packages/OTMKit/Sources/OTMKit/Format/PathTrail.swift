import Foundation

extension Format {
    /// Between the folders of a trail, as the Storage page writes them.
    public static let trailSeparator = " › "

    /// Where `path` is below `folder`, folder by folder: "Projects › webapp
    /// › build" for "/demo/Projects/webapp/build" below "/demo". Both may be
    /// absolute or below a scanned folder ("Projects/webapp"). Empty for
    /// `folder` itself; a path outside `folder` gives its whole trail.
    public static func trail(_ path: String, under folder: String = "") -> String {
        let names = path.split(separator: "/")
        let base = folder.split(separator: "/")
        let inside = names.count >= base.count && names.starts(with: base)
        return (inside ? names.dropFirst(base.count) : names[...]).joined(separator: trailSeparator)
    }
}
