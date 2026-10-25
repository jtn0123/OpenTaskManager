import Darwin
import Foundation

/// Reads only for a review or just before a move, never for a sampling tick.
public enum StorageCleanupReader {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .totalFileSizeKey, .fileSizeKey,
        .contentModificationDateKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeURLKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]
    /// A review must not turn into another unbounded scan of a large folder.
    public static let measurementLimit = 20_000

    public static func review(_ picks: [StorageCleanupPick], home: String) -> [StorageCleanupItem] {
        let mounts = Set(MountTable.mountPoints())
        return StorageCleanupRules.collapse(picks).map {
            StorageCleanupItem(pick: $0.pick, state: read($0.pick.path, mounts: mounts, home: home), includedPicks: $0.included, home: home)
        }
    }

    public static func read(_ path: String, mounts: Set<String>? = nil, home: String) -> StorageCleanupState {
        let manager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let mounts = mounts ?? Set(MountTable.mountPoints())
        var state = StorageCleanupState()
        state.resolvedPath = url.resolvingSymlinksInPath().path
        state.mountPoint = mounts.contains(path) || mounts.contains(state.resolvedPath)
        do {
            let attributes = try manager.attributesOfItem(atPath: path)
            state.exists = true
            let values = try url.resourceValues(forKeys: keys)
            state.symbolicLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
            state.identity = StorageFileIdentity(attributes: attributes)
            state.owned = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            state.readable = manager.isReadableFile(atPath: path)
            state.modified = values.contentModificationDate
            state.isFolder = values.isDirectory == true && !state.symbolicLink
            state.local = values.volumeIsLocal == true
            state.readOnly = values.volumeIsReadOnly != false
            state.placeholder = isPlaceholder(values)
            state.volumePath = values.volume?.path
            state.containsMount = state.isFolder && mounts.contains {
                $0 != state.resolvedPath && StorageCleanupRules.contains(state.resolvedPath, $0)
            }
            if state.isFolder {
                measureFolder(url, state: &state, home: home)
            } else {
                state.allocated = allocated(values)
                state.logical = logical(values)
            }
        } catch {
            state.error = error.localizedDescription
        }
        return state
    }

    private static func isPlaceholder(_ values: URLResourceValues) -> Bool {
        values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
            && values.ubiquitousItemDownloadingStatus != .downloaded
    }

    private static func allocated(_ values: URLResourceValues) -> UInt64? {
        (values.totalFileAllocatedSize ?? values.fileAllocatedSize).map { UInt64(max($0, 0)) }
    }

    private static func logical(_ values: URLResourceValues) -> UInt64? {
        (values.totalFileSize ?? values.fileSize).map { UInt64(max($0, 0)) }
    }

    /// Metadata alone never downloads cloud contents. Private folders are not walked for a review.
    private static func measureFolder(_ url: URL, state: inout StorageCleanupState, home: String) {
        guard state.readable, state.local, !state.placeholder, !state.containsMount,
              StorageCleanupRules.refusal(path: url.path, state: state, home: home) == nil,
              !StorageCleanupRules.protectedLocation(state.resolvedPath, home: home) else { return }
        var failed = false
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) { _, _ in
            failed = true
            return false
        }
        guard let enumerator else { return }
        var count = 0
        var bytes: UInt64 = 0
        var lengths: UInt64 = 0
        var seen = Set<StorageFileIdentity>()
        while let child = enumerator.nextObject() as? URL {
            count += 1
            guard count <= measurementLimit, let values = try? child.resourceValues(forKeys: keys), !isPlaceholder(values),
                  let identity = StorageFileIdentity.read(child), identity.volume == state.identity?.volume else { return }
            if values.isDirectory == true && values.isSymbolicLink != true { continue }
            guard let size = allocated(values), let length = logical(values) else { return }
            if seen.insert(identity).inserted {
                bytes += size
                lengths += length
            }
        }
        guard !failed else { return }
        state.allocated = bytes
        state.logical = lengths
        state.itemCount = count
    }

    public static func availableCapacity(_ volume: String) -> Int64? {
        try? URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
