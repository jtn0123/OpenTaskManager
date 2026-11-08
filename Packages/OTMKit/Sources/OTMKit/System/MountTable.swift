import Darwin
import Foundation

/// Where a path's volume is mounted, from the kernel's mount table.
public struct MountedVolume: Sendable, Codable, Equatable {
    public let mountPoint: String
    /// The BSD device it's mounted from ("disk3s5", or "disk3s1s1" for the
    /// startup disk's system volume, which runs from a snapshot of
    /// disk3s1); nil for a network share or devfs.
    public let device: String?
    /// "apfs", "hfs", "msdos", "smbfs"…
    public let fileSystem: String
    public let isReadOnly: Bool

    public init(mountPoint: String, device: String?, fileSystem: String, isReadOnly: Bool) {
        self.mountPoint = mountPoint
        self.device = device
        self.fileSystem = fileSystem
        self.isReadOnly = isReadOnly
    }

    public var isAPFS: Bool { fileSystem == "apfs" }
}

/// The kernel's mount table. `MNT_NOWAIT` returns what the kernel already
/// holds, so a share whose server has gone quiet can't hang a read.
public enum MountTable {
    /// Every mount point.
    public static func mountPoints() -> [String] {
        let count = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard count > 0 else { return [] }
        // Room for a mount or two arriving between the calls.
        var mounts = Array(repeating: statfs(), count: count + 4)
        let stride = MemoryLayout.stride(ofValue: mounts[0])
        let filled = mounts.withUnsafeMutableBufferPointer { buffer in
            Int(getfsstat(buffer.baseAddress, Int32(buffer.count * stride), MNT_NOWAIT))
        }
        return mounts.prefix(max(filled, 0)).map { text($0.f_mntonname) }
    }

    /// The volume holding `path`.
    public static func volume(at path: String) -> MountedVolume? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        return MountedVolume(mountPoint: text(stats.f_mntonname), device: VolumeReader.bsdName(mountSource: text(stats.f_mntfromname)),
                             fileSystem: text(stats.f_fstypename), isReadOnly: stats.f_flags & UInt32(MNT_RDONLY) != 0)
    }

    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
