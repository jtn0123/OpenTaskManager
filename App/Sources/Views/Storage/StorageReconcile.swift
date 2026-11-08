import AppKit
import OTMKit
import SwiftUI

/// "Where the space is": how a scan relates to its volume, under the
/// results. Folded, it's one line: the volume's used space, the scan's total
/// and what isn't in it, or a folder's share of the volume. Unfolded, the
/// volume's figures with its APFS container and snapshots, the scan's own,
/// and what could make up the rest, never as space to free. The figures are
/// read once per scan (`StorageStore.reconciliation`), never per tick.
struct StorageReconcilePanel: View {
    let store: StorageStore
    /// The details' natural height, so the scroll view around them is never
    /// taller than they are, and scrolls only when the window is short.
    @State private var detailsHeight: CGFloat = 0

    var body: some View {
        let reconciliation = store.reconciliation
        VStack(alignment: .leading, spacing: 0) {
            header(reconciliation)
            if store.showsReconciliation, let reconciliation {
                Divider().padding(.horizontal, 12)
                ScrollView {
                    ReconcileDetails(store: store, reconciliation: reconciliation)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                }
                .frame(maxHeight: detailsHeight)
            }
        }
        .background(CardSurface(tint: Theme.disk, glow: 0))
    }

    private func header(_ reconciliation: DiskReconciliation?) -> some View {
        let shows = store.showsReconciliation
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                store.showsReconciliation.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: shows ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                    Text("Where the space is").fontWeight(.semibold)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reconciliation == nil)
            .help(shows ? "Hide the volume's figures" : "Show how this scan relates to its volume: the volume's figures and what the scan leaves out")
            Group {
                if let reconciliation {
                    Text(reconciliation.summary)
                } else if store.readingReconciliation {
                    Text("Reading the volume's figures…")
                } else {
                    Text("The volume's figures couldn't be read.")
                }
            }
            .foregroundStyle(.secondaryText)
            .monospacedDigit()
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.explanation)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// The unfolded panel: a bar of the volume's capacity, then the volume, the
/// scan and the remainder (or the folder's share) side by side, or stacked
/// in a narrow window.
private struct ReconcileDetails: View {
    let store: StorageStore
    let reconciliation: DiskReconciliation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CapacityBar(reconciliation: reconciliation)
            ColumnGrid(minimum: 250, spacing: 20) {
                VolumeSection(reconciliation: reconciliation)
                ScanSection(store: store, reconciliation: reconciliation)
                if reconciliation.hasRemainder {
                    RemainderSection(reconciliation: reconciliation)
                } else {
                    ShareSection(reconciliation: reconciliation)
                }
            }
            Text(reconciliation.hasRemainder
                ? "These are possible reasons, not a breakdown: macOS doesn't report how much its snapshots or its own records hold, "
                + "and none of it is a measure of space you could free."
                : "A folder's scan leaves the rest of the volume out, so there's nothing to account for. Scan the whole volume "
                + "or Home to see what a scan doesn't count.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The volume's capacity as one bar: the scan, the container's other
/// volumes, the rest of the used space, and what's free, with a legend.
private struct CapacityBar: View {
    let reconciliation: DiskReconciliation

    var body: some View {
        let parts = Self.parts(reconciliation)
        VStack(alignment: .leading, spacing: 6) {
            ShareBar(segments: parts.map { ($0.color, Double($0.bytes)) })
                .frame(height: 10)
            FlowLegend(parts: parts)
        }
        .help("The volume's \(Format.bytes(reconciliation.space.capacity)) capacity")
    }

    struct Part: Identifiable {
        var id: String { label }
        let label: String
        /// Its length in the bar, which never runs past the used space.
        let bytes: UInt64
        let color: Color
        /// The legend's figure: the whole of it, even where the bar is cut
        /// short (a scan that counted more than the volume uses).
        var figure: UInt64?
    }

    static func parts(_ reconciliation: DiskReconciliation) -> [Part] {
        let space = reconciliation.space
        let scanned = min(reconciliation.scan.allocated, space.used)
        var parts = [Part(label: "This scan", bytes: scanned, color: Theme.disk, figure: reconciliation.scan.allocated)]
        let otherVolumes = reconciliation.hasRemainder ? reconciliation.otherVolumesUsed : 0
        let others = min(otherVolumes, space.used - scanned)
        if otherVolumes > 0 {
            parts.append(Part(label: "Other volumes", bytes: others, color: Theme.diskSecondary, figure: otherVolumes))
        }
        let rest = space.used - scanned - others
        if rest > 0 {
            parts.append(Part(label: "Rest of the used space", bytes: rest, color: Color.secondary.opacity(0.55)))
        }
        parts.append(Part(label: "Available", bytes: space.available, color: Color.secondary.opacity(0.2)))
        return parts
    }
}

/// The bar's legend, wrapping in a narrow window.
private struct FlowLegend: View {
    let parts: [CapacityBar.Part]

    var body: some View {
        FillGrid(minimum: 200, spacing: 12) {
            ForEach(parts) { part in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 10, height: 10)
                    Text(part.label).lineLimit(1)
                    Text(Format.bytes(part.figure ?? part.bytes)).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.explanation)
            }
        }
    }
}

/// A section's heading.
private struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title).font(.callout.weight(.semibold))
    }
}

/// A label and its figure, the figure at the end of the line.
private struct FigureRow: View {
    let label: String
    let value: String
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondaryText)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.explanation)
        .help(help ?? "")
    }
}

private struct VolumeSection: View {
    let reconciliation: DiskReconciliation

    var body: some View {
        let space = reconciliation.space
        let volume = reconciliation.volume
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Volume: \(reconciliation.volumeName)")
            Text("\(volume.mountPoint) · \(volume.fileSystem.uppercased())\(volume.isReadOnly ? " · read-only" : "")")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            FigureRow(label: "Capacity", value: Format.bytes(space.capacity))
            FigureRow(label: "Used", value: Format.bytes(space.used), help: "The capacity less what's available"
                + (reconciliation.container == nil ? "" : ": on APFS, every volume in the container counts"))
            FigureRow(label: "Available", value: Format.bytes(space.available), help: "Free right now")
            if let important = space.availableForImportantUse {
                FigureRow(label: "For important use", value: Format.bytes(important),
                          help: "What macOS would make room for something you asked for: the free space and what it expects to clear "
                              + "when it's needed (purgeable files, \(Format.bytes(space.purgeable ?? 0)) here)")
            }
            if let opportunistic = space.availableForOpportunisticUse {
                FigureRow(label: "For opportunistic use", value: Format.bytes(opportunistic),
                          help: "What macOS would make room for something that can wait, which keeps space in reserve")
            }
            FigureRow(label: "Local snapshots", value: Self.snapshots(reconciliation.snapshots), help: Self.snapshotHelp(reconciliation.snapshots))
            if let container = reconciliation.container {
                ContainerList(reconciliation: reconciliation, container: container)
                    .padding(.top, 6)
            }
        }
    }

    static func snapshots(_ listing: SnapshotListing) -> String {
        switch listing {
        case let .listed(snapshots): snapshots.isEmpty ? "none" : snapshots.count.formatted()
        case .needsAdmin: "not readable without admin rights"
        case .unreadable: "couldn't be read"
        case .notAPFS: "none (not APFS)"
        case .readOnly: "not asked"
        }
    }

    static func snapshotHelp(_ listing: SnapshotListing) -> String {
        switch listing {
        case let .listed(snapshots) where !snapshots.isEmpty: snapshots.map(\.name).joined(separator: "\n")
        case .listed: "No snapshots of the scanned volumes"
        case .needsAdmin: "Listing them needs administrator rights"
        case .unreadable: "diskutil didn't list them"
        case .notAPFS: "Only APFS keeps snapshots"
        case .readOnly: "Only read-only volumes were scanned, such as the startup disk's sealed system volume"
        }
    }
}

/// The volumes sharing the APFS container, largest first, those the scan
/// covered marked.
private struct ContainerList: View {
    let reconciliation: DiskReconciliation
    let container: APFSContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("APFS container \(container.reference), shared by")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
            ForEach(container.volumes.sorted { $0.used > $1.used }) { volume in
                let scanned = reconciliation.scannedVolumes.contains(volume.device)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: scanned ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9))
                        .foregroundStyle(scanned ? Theme.disk : Color.secondary)
                        .accessibilityLabel(scanned ? "In this scan" : "Not in this scan")
                    Text(volume.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Format.bytes(volume.used)).monospacedDigit()
                }
                .font(.explanation)
                .help("\(volume.title), \(volume.device): \(Format.bytes(volume.used)) in the container, its snapshots included"
                    + (scanned ? "; in this scan" : "; not in this scan"))
            }
        }
    }
}

private struct ScanSection: View {
    let store: StorageStore
    let reconciliation: DiskReconciliation
    @State private var showsUnreadable = false

    var body: some View {
        let scan = reconciliation.scan
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "This scan")
            Text(Self.scope(reconciliation))
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(([scan.rootPath] + scan.alsoEnters).joined(separator: "\n"))
            FigureRow(label: "On disk", value: Format.bytes(scan.allocated), help: "Whole blocks, each hard-linked file once")
            FigureRow(label: "Logical size", value: Format.bytes(scan.logical), help: "The files' own lengths")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Unreadable folders").foregroundStyle(.secondaryText)
                Spacer(minLength: 8)
                if scan.unreadableFolders > 0 {
                    Button("Show…") { showsUnreadable = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $showsUnreadable, arrowEdge: .bottom) {
                            UnreadableList(store: store, scan: scan)
                        }
                }
                Text(scan.unreadableFolders == 0 ? "none" : scan.unreadableFolders.formatted()).monospacedDigit()
            }
            .font(.explanation)
            FigureRow(label: "Extra hard-link names", value: scan.hardLinkDuplicates == 0 ? "none" : scan.hardLinkDuplicates.formatted(),
                      help: scan.hardLinkDuplicates == 0 ? "Each file is counted once, by device and inode"
                          : "Counted once, by device and inode: \(Format.bytes(scan.hardLinkDuplicateSize)) not counted again")
            FigureRow(label: "Other mounts not entered", value: scan.skippedMountCount == 0 ? "none" : scan.skippedMountCount.formatted(),
                      help: scan.skippedMounts.isEmpty ? "The scan stays on its own volumes"
                          : "The scan stays on its own volumes, so it didn't enter:\n" + scan.skippedMounts.joined(separator: "\n"))
        }
    }

    private static func scope(_ reconciliation: DiskReconciliation) -> String {
        let path = (reconciliation.scan.rootPath as NSString).abbreviatingWithTildeInPath
        switch reconciliation.scope {
        case .wholeVolume:
            return reconciliation.scan.alsoEnters.isEmpty ? "The whole volume, \(path)" : "The whole startup disk: \(path) and its Data volume"
        case .home: return "Your home folder, \(path)"
        case .folder: return "A folder, \(path)"
        }
    }
}

/// The folders a scan couldn't read, each to reveal or copy.
private struct UnreadableList: View {
    let store: StorageStore
    let scan: ScanTally

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scan.unreadableFolders == 1 ? "1 folder couldn't be read" : "\(scan.unreadableFolders.formatted()) folders couldn't be read")
                .font(.headline)
            Text(scan.unreadablePaths.count < scan.unreadableFolders
                ? "The first \(scan.unreadablePaths.count) are listed. Their contents aren't in the scan's total."
                : "Their contents aren't in the scan's total.")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(scan.unreadablePaths, id: \.self) { path in
                        HStack(spacing: 6) {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.explanation.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Spacer(minLength: 6)
                            Button {
                                store.reveal(path)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("Reveal in Finder")
                            .accessibilityLabel("Reveal in Finder")
                            Button {
                                store.copyPath(path)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .help("Copy Path")
                            .accessibilityLabel("Copy Path")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxHeight: 240)
            HStack {
                Button("Copy All") { store.copyPath(scan.unreadablePaths.joined(separator: "\n")) }
                Spacer()
                Button("Open Full Disk Access Settings") { store.openFullDiskAccessSettings() }
            }
        }
        .padding(14)
        .frame(width: 460)
    }
}

/// What the volume's used space holds beyond the scan's total, and what
/// could make it up: named, with figures only where they're known.
private struct RemainderSection: View {
    let reconciliation: DiskReconciliation

    var body: some View {
        let remainder = reconciliation.remainder ?? 0
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Not in this scan")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.bytes(remainder.magnitude)).font(.title3.weight(.semibold)).monospacedDigit()
                Text(remainder >= 0 ? "of the used space" : "more counted than the volume uses")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
            }
            .help("The volume's used space less the scan's total")
            if let rest = reconciliation.rest, reconciliation.otherVolumesUsed > 0 {
                FigureRow(label: "Less the other volumes", value: (rest < 0 ? "\u{2212}" : "") + Format.bytes(rest.magnitude),
                          help: "What's left once the container's other volumes are taken out")
            }
            Text("Could be in it")
                .font(.explanation)
                .foregroundStyle(.secondaryText)
                .padding(.top, 4)
            ForEach(reconciliation.contributors) { contributor in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(contributor.title).lineLimit(2)
                    Spacer(minLength: 8)
                    if let figure = contributor.figure {
                        Text(figure).monospacedDigit().foregroundStyle(.secondaryText).multilineTextAlignment(.trailing)
                    }
                }
                .font(.explanation)
                .help(contributor.detail)
            }
        }
    }
}

/// A folder's share of its volume, in place of a remainder.
private struct ShareSection: View {
    let reconciliation: DiskReconciliation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Share of the volume")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(reconciliation.shareOfUsed.map(DiskReconciliation.shareWords) ?? "—").font(.title3.weight(.semibold)).monospacedDigit()
                Text("of the \(Format.bytes(reconciliation.space.used)) used").font(.explanation).foregroundStyle(.secondaryText)
            }
            FigureRow(label: "Of the capacity", value: reconciliation.shareOfCapacity.map(DiskReconciliation.shareWords) ?? "—")
            if let change = reconciliation.changeDuringScan {
                FigureRow(label: "Used space moved during the scan", value: Format.byteChange(change))
            }
        }
    }
}
