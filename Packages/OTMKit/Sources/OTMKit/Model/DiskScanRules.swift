import Foundation

/// The files a scan has met under more than one name (hard links), by device
/// and inode, so each is counted once however many names it has, and two
/// files on different file systems that happen to share an inode number
/// are never taken for one.
public struct HardLinkLedger: Sendable {
    public struct Key: Hashable, Sendable {
        public let device: Int64
        public let inode: UInt64

        public init(device: Int64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    private var seen = Set<Key>()
    /// Names met for a file already counted.
    public private(set) var duplicates = 0
    /// The space those names would have added had they been counted again.
    public private(set) var duplicateSize: UInt64 = 0

    public init() {}

    /// Notes a name of a file with more than one. True the first time the
    /// file is met, when it's counted; false for every name after that,
    /// whose `allocated` size is noted as not counted again.
    public mutating func count(device: Int64, inode: UInt64, allocated: UInt64) -> Bool {
        if seen.insert(Key(device: device, inode: inode)).inserted { return true }
        duplicates += 1
        duplicateSize += allocated
        return false
    }
}

/// The scan's mount rule: it enters a folder only on a volume it started
/// on (the scanned folder's own, or one it was asked to enter as well, as
/// the startup disk's Data volume behind `/`'s firmlinks), and never one
/// that's a mount point of its own: an external disk under /Volumes, a disk
/// image, a network share, devfs, and the Data volume's mount point under
/// /System/Volumes, which reports the same volume as `/` but would count
/// everything on it a second time. It notes the first few it passed by.
public struct MountBoundary<Volume: Hashable> {
    /// Mount points passed by that are listed; the count covers the rest.
    public static var listLimit: Int { 20 }

    public let allowed: Set<Volume>
    /// Mount points strictly inside the scanned folder.
    public let mountPoints: Set<String>
    /// The most path components any of them has, so folders deeper than
    /// that are never looked up.
    public let deepestMount: Int
    public private(set) var skipped: [String] = []
    public private(set) var skippedCount = 0

    /// `mountPoints` is the whole mount table; those outside `root`, and
    /// `root` itself, are left out.
    public init(root: String, allowed: some Sequence<Volume>, mountPoints: some Sequence<String>) {
        self.allowed = Set(allowed)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let inside = Set(mountPoints.filter { $0.hasPrefix(prefix) && $0.count > prefix.count })
        self.mountPoints = inside
        deepestMount = inside.map(Self.depth).max() ?? 0
    }

    /// Path components below `/`: 0 for `/`, 3 for /System/Volumes/Data.
    public static func depth(of path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }

    /// Whether to enter the folder at `path`, `depth` components below `/`,
    /// on `volume`. A folder whose volume couldn't be read is entered unless
    /// it's a mount point: it's on whichever volume holds the folder it's in.
    public mutating func enters(depth: Int, volume: Volume?, path: () -> String) -> Bool {
        var outside = volume.map { !allowed.contains($0) } ?? false
        var resolved: String?
        if !outside, depth <= deepestMount {
            let folder = path()
            resolved = folder
            outside = mountPoints.contains(folder)
        }
        guard outside else { return true }
        skippedCount += 1
        if skipped.count < Self.listLimit { skipped.append(resolved ?? path()) }
        return false
    }
}
