import Foundation

/// Reads what a reconciliation needs to know about a finished scan's volume:
/// its space, and on APFS its container's volumes (`diskutil apfs list`) and
/// the scanned volumes' snapshots (`diskutil apfs listSnapshots`, which
/// needs no admin rights). Blocks for as long as the tools take, a fraction
/// of a second, so call it off the main actor, once per scan.
public enum DiskReconciliationReader {
    private static let keys: Set<URLResourceKey> = [
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityForOpportunisticUsageKey, .volumeLocalizedNameKey, .volumeNameKey,
    ]
    private static let diskutil = "/usr/sbin/diskutil"

    /// Nil when the scanned folder's volume can't be read (it's gone).
    public static func read(_ usage: DiskUsage, request: DiskScanRequest,
                            home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                            timeout: TimeInterval = 10) -> DiskReconciliation? {
        guard let volume = MountTable.volume(at: usage.rootPath),
              let space = space(at: URL(fileURLWithPath: usage.rootPath, isDirectory: true)) else { return nil }
        let name = (try? URL(fileURLWithPath: usage.rootPath).resourceValues(forKeys: keys)).flatMap { $0.volumeLocalizedName ?? $0.volumeName }
            ?? (volume.mountPoint == "/" ? "/" : (volume.mountPoint as NSString).lastPathComponent)
        let scope = ReconciliationScope.of(rootPath: usage.rootPath, mountPoint: volume.mountPoint, homePath: realPath(home))
        let scan = ScanTally(usage, request: request)
        guard volume.isAPFS else {
            return DiskReconciliation(scope: scope, volumeName: name, volume: volume, space: space, snapshots: .notAPFS, scan: scan)
        }
        // The volumes the scan covered: its own, and the startup disk's Data
        // volume behind `/`.
        var mounts = [volume]
        for url in request.alsoEnters {
            if let other = MountTable.volume(at: url.path), !mounts.contains(where: { $0.mountPoint == other.mountPoint }) { mounts.append(other) }
        }
        let list = CommandRunner.execute(diskutil, ["apfs", "list", "-plist"], capture: .output, timeout: timeout)
        let containers = list.flatMap { $0.status == 0 ? APFSContainer.parseList($0.text) : nil } ?? []
        let container = volume.device.flatMap { APFSContainer.holding(device: $0, in: containers) }
        let snapshots = SnapshotListing.combining(mounts.filter { $0.isAPFS && !$0.isReadOnly }.map { mount in
            let result = CommandRunner.execute(diskutil, ["apfs", "listSnapshots", "-plist", mount.mountPoint], capture: .both, timeout: timeout)
            return SnapshotListing.reading(status: result?.status, output: result?.text ?? "", volume: mount.mountPoint)
        })
        return DiskReconciliation(scope: scope, volumeName: name, volume: volume, space: space, container: container,
                                  scannedVolumes: DiskReconciliation.scannedVolumes(mountedFrom: mounts.compactMap(\.device), in: container),
                                  snapshots: snapshots, scan: scan)
    }

    /// The space of the volume holding `url`.
    public static func space(at url: URL) -> VolumeSpace? {
        guard let values = try? url.resourceValues(forKeys: keys), let capacity = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }
        // A disk image reports 0 for both while it has space free: not a figure.
        func figure(_ value: Int64?) -> UInt64? {
            value.flatMap { $0 > 0 || available <= 0 ? bytes($0) : nil }
        }
        return VolumeSpace(capacity: bytes(Int64(capacity)), available: bytes(Int64(available)),
                           availableForImportantUse: figure(values.volumeAvailableCapacityForImportantUsage),
                           availableForOpportunisticUse: figure(values.volumeAvailableCapacityForOpportunisticUsage))
    }

    private static func bytes(_ value: Int64) -> UInt64 {
        UInt64(max(value, 0))
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
