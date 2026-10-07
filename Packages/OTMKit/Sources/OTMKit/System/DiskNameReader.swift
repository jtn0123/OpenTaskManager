import Foundation
import IOKit

/// Reads what `DiskNaming` needs: every mounted volume, hidden ones too,
/// with the whole disk it's stored on, and the file each disk image was
/// attached from. It walks the I/O Registry once per volume, so
/// `DiskSampler` calls it only when the disks or the mounts change.
enum DiskNameReader {
    struct Names: Equatable {
        var name: String?
        var imagePath: String?
    }

    /// Names for each of `disks` ("disk0").
    static func read(disks: [String]) -> [String: Names] {
        let volumes = mountedVolumes()
        var names: [String: Names] = [:]
        for disk in disks {
            let imagePath = imagePath(forBSDName: disk)
            names[disk] = Names(name: DiskNaming.name(of: disk, volumes: volumes, imagePath: imagePath), imagePath: imagePath)
        }
        return names
    }

    /// How many file systems are mounted: one cheap call, so a sample can
    /// tell a volume was mounted or ejected without reading them all.
    static func mountCount() -> Int32 {
        getfsstat(nil, 0, MNT_NOWAIT)
    }

    /// Every volume mounted from a disk device, with its name and the whole disk under it.
    static func mountedVolumes() -> [DiskNaming.Volume] {
        let count = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard count > 0 else { return [] }
        // Room for a mount or two arriving between the calls.
        var mounts = Array(repeating: statfs(), count: count + 4)
        let stride = MemoryLayout.stride(ofValue: mounts[0])
        let filled = mounts.withUnsafeMutableBufferPointer { buffer in
            Int(getfsstat(buffer.baseAddress, Int32(buffer.count * stride), MNT_NOWAIT))
        }
        return mounts.prefix(max(filled, 0)).compactMap { mount -> DiskNaming.Volume? in
            let source = withUnsafeBytes(of: mount.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let path = withUnsafeBytes(of: mount.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard let device = VolumeReader.bsdName(mountSource: source),
                  let disk = IORegistry.physicalDisk(forBSDName: device) else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            return DiskNaming.Volume(name: name, disk: disk,
                                     isRoot: mount.f_flags & UInt32(MNT_ROOTFS) != 0,
                                     isBrowsable: mount.f_flags & UInt32(MNT_DONTBROWSE) == 0)
        }
    }

    /// The file a disk image was attached from. The disk images driver
    /// keeps it on the device's ancestors as "image-path" (bytes); nil for
    /// a drive.
    static func imagePath(forBSDName bsdName: String) -> String? {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "image-path" as CFString, kCFAllocatorDefault, options)
        else { return nil }
        if let path = value as? String { return path.isEmpty ? nil : path }
        guard let data = value as? Data else { return nil }
        let path = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }
}
