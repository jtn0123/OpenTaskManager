import Foundation
import IOKit

final class DiskSampler {
    private struct Counters {
        let read: UInt64
        let written: UInt64
        let readOps: UInt64
        let writeOps: UInt64
        let busyNanoseconds: UInt64
    }

    /// A disk as the registry describes it, before its names are added.
    private struct Found {
        let bsdName: String
        let model: String?
        let isInternal: Bool?
        let isSolidState: Bool?
        let size: UInt64?
        let counters: Counters
    }

    private var previous: [String: Counters] = [:]
    /// Each disk's names, read again only when the disks or the mounts change.
    private var names: [String: DiskNameReader.Names] = [:]
    private var namedDisks: [String] = []
    private var namedMounts: Int32 = -1

    func sample(interval: TimeInterval) -> [DiskSample] {
        var found: [Found] = []
        var seen: [String: Counters] = [:]

        IORegistry.forEachService(matching: "IOBlockStorageDriver") { driver in
            guard let stats = IORegistry.properties(of: driver).dictionary("Statistics") else { return }

            var bsdName: String?
            var size: UInt64?
            IORegistry.forEachChild(of: driver) { media in
                guard bsdName == nil, let name = IORegistry.property("BSD Name", of: media) as? String else { return }
                bsdName = name
                size = (IORegistry.property("Size", of: media) as? NSNumber)?.uint64Value
            }
            guard let bsdName else { return }

            var model: String?
            var isInternal: Bool?
            var isSolidState: Bool?
            if let device = IORegistry.parent(of: driver) {
                let properties = IORegistry.properties(of: device)
                let characteristics = properties.dictionary("Device Characteristics")
                model = characteristics?.string("Product Name")?.trimmingCharacters(in: .whitespaces)
                isSolidState = characteristics?.string("Medium Type").map { $0 == "Solid State" }
                isInternal = properties.dictionary("Protocol Characteristics")?
                    .string("Physical Interconnect Location").map { $0 == "Internal" }
                IOObjectRelease(device)
            }

            let counters = Counters(
                read: stats.uint64("Bytes (Read)") ?? 0,
                written: stats.uint64("Bytes (Write)") ?? 0,
                readOps: stats.uint64("Operations (Read)") ?? 0,
                writeOps: stats.uint64("Operations (Write)") ?? 0,
                busyNanoseconds: (stats.uint64("Total Time (Read)") ?? 0) + (stats.uint64("Total Time (Write)") ?? 0)
            )
            seen[bsdName] = counters
            found.append(Found(bsdName: bsdName, model: model, isInternal: isInternal, isSolidState: isSolidState,
                               size: size, counters: counters))
        }

        found.sort { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        refreshNames(found.map(\.bsdName))
        let disks = found.map { disk in
            let before = previous[disk.bsdName]
            func rate(_ keyPath: KeyPath<Counters, UInt64>) -> Double {
                guard let before, interval > 0, disk.counters[keyPath: keyPath] >= before[keyPath: keyPath] else { return 0 }
                return Double(disk.counters[keyPath: keyPath] - before[keyPath: keyPath]) / interval
            }
            return DiskSample(
                bsdName: disk.bsdName,
                model: disk.model,
                isInternal: disk.isInternal,
                isSolidState: disk.isSolidState,
                size: disk.size,
                name: names[disk.bsdName]?.name,
                imagePath: names[disk.bsdName]?.imagePath,
                readBytesPerSecond: rate(\.read),
                writeBytesPerSecond: rate(\.written),
                readOperationsPerSecond: rate(\.readOps),
                writeOperationsPerSecond: rate(\.writeOps),
                totalRead: disk.counters.read,
                totalWritten: disk.counters.written,
                activeFraction: min(rate(\.busyNanoseconds) / 1_000_000_000, 1)
            )
        }

        previous = seen
        return disks
    }

    /// Reads the disks' names when a disk came or went, or a volume was
    /// mounted or ejected (an image's volume mounts a moment after its disk
    /// appears); otherwise a sample costs one `getfsstat` count.
    private func refreshNames(_ disks: [String]) {
        let mounts = DiskNameReader.mountCount()
        guard disks != namedDisks || mounts != namedMounts else { return }
        names = DiskNameReader.read(disks: disks)
        namedDisks = disks
        namedMounts = mounts
    }
}

/// Mounted volumes and their space, for the Overview, System and Storage pages.
public enum VolumeReader {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
    ]

    public static func read() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
                ?? UInt64(max(values.volumeAvailableCapacity ?? 0, 0))
            return VolumeInfo(
                name: values.volumeName ?? url.lastPathComponent,
                mountPoint: url.path,
                fileSystem: values.volumeLocalizedFormatDescription,
                totalBytes: UInt64(total),
                availableBytes: available,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isRoot: values.volumeIsRootFileSystem ?? false,
                physicalDisk: deviceName(of: url.path).flatMap(IORegistry.physicalDisk(forBSDName:))
            )
        }
    }

    /// The BSD device a volume is mounted from, e.g. "disk3s1s1".
    private static func deviceName(of path: String) -> String? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        let source = withUnsafeBytes(of: stats.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return bsdName(mountSource: source)
    }

    /// "/dev/disk3s1s1" → "disk3s1s1". Network shares and automounts have no device.
    static func bsdName(mountSource: String) -> String? {
        guard mountSource.hasPrefix("/dev/disk") else { return nil }
        return String(mountSource.dropFirst("/dev/".count))
    }
}
