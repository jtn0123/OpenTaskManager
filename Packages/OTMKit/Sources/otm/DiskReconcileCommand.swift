import Foundation
import OTMKit

/// `otm du --reconcile --json`: how the scan relates to its volume. Sizes
/// are bytes; a remainder is signed, negative when the scan counted more
/// than the volume reports used.
struct DiskReconciliationReport: Encodable {
    struct Volume: Encodable {
        let name: String
        let mountPoint: String
        let device: String?
        let fileSystem: String
        let readOnly: Bool
        let capacity: UInt64
        let used: UInt64
        let available: UInt64
        let availableForImportantUse: UInt64?
        let availableForOpportunisticUse: UInt64?
        let purgeable: UInt64?
    }

    struct ContainerVolume: Encodable {
        let device: String
        let name: String
        let roles: [String]
        let used: UInt64
        let scanned: Bool
    }

    struct Container: Encodable {
        let reference: String
        let capacity: UInt64
        let free: UInt64
        let used: UInt64
        let volumes: [ContainerVolume]
    }

    struct Snapshots: Encodable {
        /// listed, needsAdmin, unreadable, notAPFS or readOnly.
        let state: String
        let count: Int?
        let names: [String]?
    }

    struct Scan: Encodable {
        let path: String
        let alsoEnters: [String]
        let allocatedSize: UInt64
        let logicalSize: UInt64
        let unreadableFolders: Int
        let unreadablePaths: [String]
        let hardLinkDuplicates: Int
        let hardLinkDuplicateSize: UInt64
        let mountsNotEntered: [String]
        let mountsNotEnteredCount: Int
        let volumeUsedAtStart: UInt64?
    }

    struct Remainder: Encodable {
        let total: Int64
        let otherVolumes: UInt64
        let rest: Int64
    }

    struct Share: Encodable {
        let ofUsed: Double?
        let ofCapacity: Double?
    }

    struct Contributor: Encodable {
        let kind: String
        let title: String
        let figure: String?
        let bytes: Int64?
        let count: Int?
        let detail: String
    }

    let scope: String
    let summary: String
    let volume: Volume
    let container: Container?
    let snapshots: Snapshots
    let scan: Scan
    /// For a whole volume or the home folder.
    let remainder: Remainder?
    /// For any other folder.
    let share: Share?
    let changeDuringScan: Int64?
    let contributors: [Contributor]

    init(_ reconciliation: DiskReconciliation) {
        let space = reconciliation.space
        let volume = reconciliation.volume
        scope = reconciliation.scope.rawValue
        summary = reconciliation.summary
        self.volume = Volume(name: reconciliation.volumeName, mountPoint: volume.mountPoint, device: volume.device, fileSystem: volume.fileSystem,
                             readOnly: volume.isReadOnly, capacity: space.capacity, used: space.used, available: space.available,
                             availableForImportantUse: space.availableForImportantUse,
                             availableForOpportunisticUse: space.availableForOpportunisticUse, purgeable: space.purgeable)
        container = reconciliation.container.map { container in
            Container(reference: container.reference, capacity: container.capacity, free: container.free, used: container.used,
                      volumes: container.volumes.map {
                          ContainerVolume(device: $0.device, name: $0.name, roles: $0.roles, used: $0.used,
                                          scanned: reconciliation.scannedVolumes.contains($0.device))
                      })
        }
        let listed = reconciliation.snapshots.snapshots
        snapshots = Snapshots(state: reconciliation.snapshots.state, count: listed?.count, names: listed?.map(\.name))
        let tally = reconciliation.scan
        scan = Scan(path: tally.rootPath, alsoEnters: tally.alsoEnters, allocatedSize: tally.allocated, logicalSize: tally.logical,
                    unreadableFolders: tally.unreadableFolders, unreadablePaths: tally.unreadablePaths,
                    hardLinkDuplicates: tally.hardLinkDuplicates, hardLinkDuplicateSize: tally.hardLinkDuplicateSize,
                    mountsNotEntered: tally.skippedMounts, mountsNotEnteredCount: tally.skippedMountCount, volumeUsedAtStart: tally.usedAtStart)
        if let total = reconciliation.remainder, let rest = reconciliation.rest {
            remainder = Remainder(total: total, otherVolumes: reconciliation.otherVolumesUsed, rest: rest)
            share = nil
        } else {
            remainder = nil
            share = Share(ofUsed: reconciliation.shareOfUsed, ofCapacity: reconciliation.shareOfCapacity)
        }
        changeDuringScan = reconciliation.changeDuringScan
        contributors = reconciliation.contributors.map {
            Contributor(kind: $0.kind.rawValue, title: $0.title, figure: $0.figure, bytes: $0.bytes, count: $0.count, detail: $0.detail)
        }
    }
}

/// `otm du --reconcile`: the "Where the space is" section under the scan.
func diskReconciliationSummary(_ reconciliation: DiskReconciliation) -> String {
    let space = reconciliation.space
    let volume = reconciliation.volume
    var lines = ["", "Where the space is", reconciliation.summary, ""]
    lines.append("Volume: \(reconciliation.volumeName) at \(volume.mountPoint) (\(volume.fileSystem)\(volume.isReadOnly ? ", read-only" : ""))")
    lines.append(pad(Format.bytes(space.capacity), 10, right: true) + "  capacity")
    lines.append(pad(Format.bytes(space.used), 10, right: true) + "  used")
    lines.append(pad(Format.bytes(space.available), 10, right: true) + "  available")
    if let important = space.availableForImportantUse {
        let purgeable = space.purgeable.map { $0 > 0 ? ", with \(Format.bytes($0)) macOS can clear when it's needed" : "" } ?? ""
        lines.append(pad(Format.bytes(important), 10, right: true) + "  available for important use" + purgeable)
    }
    if let opportunistic = space.availableForOpportunisticUse {
        lines.append(pad(Format.bytes(opportunistic), 10, right: true) + "  available for opportunistic use")
    }
    if let container = reconciliation.container {
        lines += ["", "APFS container \(container.reference): \(Format.bytes(container.capacity)), \(Format.bytes(container.used)) used"]
        for item in container.volumes.sorted(by: { $0.used > $1.used }) {
            let scanned = reconciliation.scannedVolumes.contains(item.device) ? "  (in this scan)" : ""
            lines.append(pad(Format.bytes(item.used), 10, right: true) + "  \(item.title), \(item.device)\(scanned)")
        }
    }
    lines += ["", "Local snapshots: " + snapshotWords(reconciliation.snapshots)]
    let scan = reconciliation.scan
    let scope = ([scan.rootPath] + scan.alsoEnters).joined(separator: " and ")
    lines += ["", "This scan: \(scope), \(Format.bytes(scan.allocated)) on disk, \(Format.bytes(scan.logical)) of data"]
    if scan.unreadableFolders > 0 {
        lines.append("  \(scan.unreadableFolders.formatted()) folders couldn't be read: " + scan.unreadablePaths.prefix(5).joined(separator: ", ")
            + (scan.unreadableFolders > 5 ? ", …" : ""))
    }
    if scan.hardLinkDuplicates > 0 {
        let names = scan.hardLinkDuplicates == 1 ? "1 extra hard-link name" : "\(scan.hardLinkDuplicates.formatted()) extra hard-link names"
        lines.append("  \(names) for files already counted (\(Format.bytes(scan.hardLinkDuplicateSize)) not counted again)")
    }
    if scan.skippedMountCount > 0 {
        lines.append("  \(scan.skippedMountCount.formatted()) mounts inside it not entered: " + scan.skippedMounts.prefix(5).joined(separator: ", ")
            + (scan.skippedMountCount > 5 ? ", …" : ""))
    }
    guard let remainder = reconciliation.remainder else {
        let ofUsed = reconciliation.shareOfUsed.map(DiskReconciliation.shareWords) ?? "—"
        let ofCapacity = reconciliation.shareOfCapacity.map(DiskReconciliation.shareWords) ?? "—"
        lines += ["", "Share of the volume: \(ofUsed) of its used space, \(ofCapacity) of its capacity"]
        return lines.joined(separator: "\n")
    }
    lines.append("")
    lines.append(remainder >= 0 ? "Not in this scan: \(Format.bytes(remainder.magnitude)) (the volume's used space less the scan's total)"
        : "The scan counted \(Format.bytes(remainder.magnitude)) more than the volume reports used")
    if let rest = reconciliation.rest, reconciliation.otherVolumesUsed > 0 {
        lines.append("  \(signedBytes(rest)) once the container's other volumes are taken out")
    }
    lines += ["", "What could account for the difference"]
    for contributor in reconciliation.contributors {
        lines.append(pad(contributor.figure ?? "", 10, right: true) + "  \(contributor.title): \(contributor.detail)")
    }
    lines += ["", "None of this is a measure of space you could free."]
    return lines.joined(separator: "\n")
}

/// "150 GB", or "−100 GB" when the scan counted more.
private func signedBytes(_ value: Int64) -> String {
    (value < 0 ? "\u{2212}" : "") + Format.bytes(value.magnitude)
}

private func snapshotWords(_ listing: SnapshotListing) -> String {
    switch listing {
    case let .listed(snapshots) where snapshots.isEmpty: "none"
    case let .listed(snapshots): "\(snapshots.count): " + snapshots.map(\.name).joined(separator: ", ")
    case .needsAdmin: "not readable without admin rights"
    case .unreadable: "couldn't be read"
    case .notAPFS: "none (not APFS)"
    case .readOnly: "not asked (read-only volume)"
    }
}
