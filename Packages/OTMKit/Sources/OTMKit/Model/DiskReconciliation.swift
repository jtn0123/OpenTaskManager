import Foundation

/// A volume's space as macOS reports it for a path on it
/// (`URLResourceValues`). On APFS every volume in a container reports the
/// container's figures, so "used" covers all of them.
public struct VolumeSpace: Sendable, Codable, Equatable {
    public let capacity: UInt64
    /// Free right now.
    public let available: UInt64
    /// Free for something the user asked for: the free space and what
    /// macOS expects to clear when it's needed (purgeable files). Nil where
    /// the volume doesn't say.
    public let availableForImportantUse: UInt64?
    /// Free for something that can wait, which leaves room in reserve.
    public let availableForOpportunisticUse: UInt64?

    public init(capacity: UInt64, available: UInt64, availableForImportantUse: UInt64? = nil, availableForOpportunisticUse: UInt64? = nil) {
        self.capacity = capacity
        self.available = available
        self.availableForImportantUse = availableForImportantUse
        self.availableForOpportunisticUse = availableForOpportunisticUse
    }

    /// The capacity less what's free right now.
    public var used: UInt64 { capacity > available ? capacity - available : 0 }

    /// What the important-use figure adds to the free space: purgeable data
    /// macOS expects to clear when space runs short.
    public var purgeable: UInt64? {
        availableForImportantUse.map { $0 > available ? $0 - available : 0 }
    }
}

/// How a scan's folder relates to its volume.
public enum ReconciliationScope: String, Sendable, Codable {
    /// The volume's mount point (or the startup disk's `/`).
    case wholeVolume
    /// The user's home folder.
    case home
    /// Any other folder.
    case folder

    public static func of(rootPath: String, mountPoint: String, homePath: String) -> ReconciliationScope {
        if rootPath == mountPoint { return .wholeVolume }
        return rootPath == homePath ? .home : .folder
    }
}

/// A scan's own figures, as the reconciliation weighs them.
public struct ScanTally: Sendable, Codable, Equatable {
    public let rootPath: String
    /// Other volumes it entered as part of the same scope: the startup
    /// disk's Data volume, through `/`'s firmlinks.
    public let alsoEnters: [String]
    /// Space on disk, each hard-linked file once.
    public let allocated: UInt64
    public let logical: UInt64
    public let unreadableFolders: Int
    /// The first `DiskUsage.unreadablePathLimit` of them.
    public let unreadablePaths: [String]
    public let hardLinkDuplicates: Int
    public let hardLinkDuplicateSize: UInt64
    /// Mount points inside it that it didn't enter (the first few).
    public let skippedMounts: [String]
    public let skippedMountCount: Int
    public let usedAtStart: UInt64?

    public init(rootPath: String, alsoEnters: [String] = [], allocated: UInt64, logical: UInt64, unreadableFolders: Int = 0,
                unreadablePaths: [String] = [], hardLinkDuplicates: Int = 0, hardLinkDuplicateSize: UInt64 = 0,
                skippedMounts: [String] = [], skippedMountCount: Int? = nil, usedAtStart: UInt64? = nil) {
        self.rootPath = rootPath
        self.alsoEnters = alsoEnters
        self.allocated = allocated
        self.logical = logical
        self.unreadableFolders = unreadableFolders
        self.unreadablePaths = unreadablePaths
        self.hardLinkDuplicates = hardLinkDuplicates
        self.hardLinkDuplicateSize = hardLinkDuplicateSize
        self.skippedMounts = skippedMounts
        self.skippedMountCount = skippedMountCount ?? skippedMounts.count
        self.usedAtStart = usedAtStart
    }

    public init(_ usage: DiskUsage, request: DiskScanRequest) {
        self.init(rootPath: usage.rootPath, alsoEnters: request.alsoEnters.map(\.path), allocated: usage.root.allocatedSize,
                  logical: usage.root.logicalSize, unreadableFolders: usage.unreadableFolders, unreadablePaths: usage.unreadablePaths,
                  hardLinkDuplicates: usage.hardLinkDuplicates, hardLinkDuplicateSize: usage.hardLinkDuplicateSize,
                  skippedMounts: usage.skippedVolumes, skippedMountCount: usage.skippedVolumeCount, usedAtStart: usage.volumeUsedAtStart)
    }
}

/// Something that could be part of the space a scan doesn't account for,
/// named with a figure where one is known. None is ever a measure of what
/// could be freed.
public struct ReconciliationContributor: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case otherVolumes, outsideHome, snapshots, unreadableFolders, unlinkedFolders, metadata, changedDuringScan, clones
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let title: String
    /// What's known of it, in a few words ("20.0 GB", "none", "not readable
    /// without admin rights"); nil when nothing is.
    public let figure: String?
    /// Its size, when it's known; negative when it pushes the other way.
    public let bytes: Int64?
    public let count: Int?
    public let detail: String
}

/// How a scan relates to its volume: the volume's figures (and, on APFS,
/// its container's and its snapshots'), the scan's, and for a scan of a
/// whole volume or the home folder, the remainder (the volume's used space
/// less the scan's total) with what could be in it. A folder's scan gets
/// its share of the volume instead.
public struct DiskReconciliation: Sendable, Equatable {
    public let scope: ReconciliationScope
    public let volumeName: String
    public let volume: MountedVolume
    public let space: VolumeSpace
    /// Nil off APFS, or when `diskutil` couldn't be read.
    public let container: APFSContainer?
    /// The container's volumes the scan covered, by device.
    public let scannedVolumes: [String]
    public let snapshots: SnapshotListing
    public let scan: ScanTally

    public init(scope: ReconciliationScope, volumeName: String, volume: MountedVolume, space: VolumeSpace,
                container: APFSContainer? = nil, scannedVolumes: [String] = [], snapshots: SnapshotListing, scan: ScanTally) {
        self.scope = scope
        self.volumeName = volumeName
        self.volume = volume
        self.space = space
        self.container = container
        self.scannedVolumes = scannedVolumes
        self.snapshots = snapshots
        self.scan = scan
    }

    /// The scan's devices matched to the container's volumes.
    public static func scannedVolumes(mountedFrom devices: [String], in container: APFSContainer?) -> [String] {
        guard let container else { return [] }
        return container.volumes.filter { volume in devices.contains { volume.holds(device: $0) } }.map(\.device)
    }

    /// Whether there's a remainder to explain: the scan covered a whole
    /// volume or the home folder, so the volume's used space should mostly
    /// be in it.
    public var hasRemainder: Bool { scope != .folder }

    /// The container's volumes the scan didn't cover, largest first. Their
    /// space is part of the volume's used figure.
    public var otherVolumes: [APFSVolume] {
        (container?.volumes ?? []).filter { !scannedVolumes.contains($0.device) }.sorted { $0.used > $1.used }
    }

    public var otherVolumesUsed: UInt64 {
        otherVolumes.reduce(0) { $0 + $1.used }
    }

    /// The volume's used space less the scan's total, for a whole volume or
    /// home; negative when the scan counted more. Nil for a folder.
    public var remainder: Int64? {
        hasRemainder ? Self.difference(space.used, scan.allocated) : nil
    }

    /// The remainder less the other volumes in the container: what the
    /// scanned volumes hold beyond the scan's total, not broken down further.
    public var rest: Int64? {
        remainder.map { $0 - Int64(clamping: otherVolumesUsed) }
    }

    /// A folder's share of the volume's used space.
    public var shareOfUsed: Double? {
        space.used > 0 ? Double(scan.allocated) / Double(space.used) : nil
    }

    /// A folder's share of the volume's capacity.
    public var shareOfCapacity: Double? {
        space.capacity > 0 ? Double(scan.allocated) / Double(space.capacity) : nil
    }

    /// A share in words: "16%", "2.4%", "under 0.1%".
    public static func shareWords(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.001 { return "under 0.1%" }
        return Format.percent(fraction, digits: fraction < 0.1 ? 1 : 0)
    }

    /// How far the volume's used space moved while the scan ran.
    public var changeDuringScan: Int64? {
        scan.usedAtStart.map { Self.difference(space.used, $0) }
    }

    /// `a - b`, signed, without overflow.
    static func difference(_ minuend: UInt64, _ subtrahend: UInt64) -> Int64 {
        minuend >= subtrahend ? Int64(clamping: minuend - subtrahend) : -Int64(clamping: subtrahend - minuend)
    }

    /// What could be in the remainder, with figures where they're known,
    /// the other volumes first; empty for a folder.
    public var contributors: [ReconciliationContributor] {
        guard hasRemainder else { return [] }
        var list: [ReconciliationContributor] = []
        let others = otherVolumes
        if container != nil, !others.isEmpty {
            let names = others.map { "\($0.title) \(Format.bytes($0.used))" }.joined(separator: ", ")
            list.append(.init(kind: .otherVolumes, title: "Other volumes in the container", figure: Format.bytes(otherVolumesUsed),
                              bytes: Int64(clamping: otherVolumesUsed), count: others.count,
                              detail: "\(names). They share the container's space, so the volume's used figure includes them."))
        }
        if scope == .home {
            list.append(.init(kind: .outsideHome, title: "The volume outside your home folder", figure: nil, bytes: nil, count: nil,
                              detail: "Apps, the shared Library, other users' folders and the system's own files."))
        }
        if let snapshot = snapshotContributor { list.append(snapshot) }
        list.append(.init(kind: .unreadableFolders, title: "Folders the scan couldn't read",
                          figure: scan.unreadableFolders == 0 ? "none" : scan.unreadableFolders.formatted(), bytes: nil,
                          count: scan.unreadableFolders, detail: "Their contents aren't in the scan's total."))
        if !scan.alsoEnters.isEmpty {
            list.append(.init(kind: .unlinkedFolders, title: "Data volume folders / doesn't reach", figure: nil, bytes: nil, count: nil,
                              detail: "Spotlight's index, file-system event logs and saved document versions sit at the top of the "
                                  + "Data volume, outside the links that join it to /, so a scan of / doesn't reach them."))
        }
        list.append(.init(kind: .metadata, title: "File-system metadata", figure: nil, bytes: nil, count: nil,
                          detail: "The file system's own records take space that no file owns."))
        if let change = changeDuringScan {
            list.append(.init(kind: .changedDuringScan, title: "Changes while the scan ran", figure: Format.byteChange(change), bytes: change,
                              count: nil, detail: "Used space moved this much between the scan's start and end. Files written or "
                                  + "removed in folders it had already passed aren't reflected in its total."))
        }
        if volume.isAPFS {
            list.append(.init(kind: .clones, title: "Clones and shared extents", figure: nil, bytes: nil, count: nil,
                              detail: "Copies that share blocks are counted in full for each copy, so they make the scan larger than "
                                  + "the space they use: they push the remainder down, never up."))
        }
        return list
    }

    private var snapshotContributor: ReconciliationContributor? {
        let detail = "Snapshots keep the blocks of files changed or removed since they were taken. macOS doesn't say how much each holds."
        switch snapshots {
        case let .listed(list):
            return .init(kind: .snapshots, title: "Local snapshots", figure: list.isEmpty ? "none" : list.count.formatted(), bytes: nil,
                         count: list.count, detail: detail)
        case .needsAdmin:
            return .init(kind: .snapshots, title: "Local snapshots", figure: "not readable without admin rights", bytes: nil, count: nil,
                         detail: detail)
        case .unreadable:
            return .init(kind: .snapshots, title: "Local snapshots", figure: "couldn't be read", bytes: nil, count: nil, detail: detail)
        case .notAPFS, .readOnly:
            return nil
        }
    }

    /// One line on how the scan relates to the volume: "Macintosh HD:
    /// 635 GB used; this scan 580 GB; 55.5 GB not in it", or a folder's
    /// "3.79 GB, 16% of the 23.3 GB used on Macintosh HD".
    public var summary: String {
        guard let remainder else {
            let share = shareOfUsed.map(Self.shareWords) ?? "—"
            return "\(Format.bytes(scan.allocated)), \(share) of the \(Format.bytes(space.used)) used on \(volumeName)"
        }
        let gap = remainder >= 0 ? "\(Format.bytes(remainder.magnitude)) not in it"
            : "\(Format.bytes(remainder.magnitude)) more than the volume uses"
        return "\(volumeName): \(Format.bytes(space.used)) used; this scan \(Format.bytes(scan.allocated)); \(gap)"
    }
}
