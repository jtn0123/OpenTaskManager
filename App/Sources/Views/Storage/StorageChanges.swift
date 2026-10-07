import AppKit
import OTMKit
import SwiftUI

/// Colours and words for what changed between two scans.
enum StorageChangeStyle {
    /// Tile fills: mid-tones like the category colours, so white labels read on them.
    static let grewFill = Color(red: 0.89, green: 0.35, blue: 0.27)
    static let shrankFill = Color(red: 0.13, green: 0.60, blue: 0.43)
    static let sameFill = Color(red: 0.55, green: 0.58, blue: 0.64)
    /// For figures in text, deepened in light mode.
    static let grewText = Theme.data(0.89, 0.35, 0.27)
    static let shrankText = Theme.data(0.13, 0.60, 0.43)

    /// Changes this small count as none in the folder on view.
    static func threshold(for size: UInt64) -> UInt64 {
        DiskScanComparison.noiseFloor(for: size)
    }

    static func fill(_ direction: DiskSizeChange.Direction) -> Color {
        switch direction {
        case .grew: grewFill
        case .shrank: shrankFill
        case .same, .unclear: sameFill
        }
    }

    static func textStyle(_ direction: DiskSizeChange.Direction) -> AnyShapeStyle {
        switch direction {
        case .grew: AnyShapeStyle(grewText)
        case .shrank: AnyShapeStyle(shrankText)
        case .same, .unclear: AnyShapeStyle(.secondaryText)
        }
    }

    static func title(_ direction: DiskSizeChange.Direction) -> String {
        switch direction {
        case .grew: "Grew"
        case .shrank: "Shrank"
        case .same: "No change"
        case .unclear: "Can't tell"
        }
    }

    /// "+200 MB", "−1.5 GB or more", "No change", "Can't tell".
    static func caption(_ change: DiskSizeChange, _ direction: DiskSizeChange.Direction) -> String {
        switch direction {
        case .grew: Format.byteChange(change.growth, grew: true, exact: change.isExact)
        case .shrank: Format.byteChange(change.shrinkage, grew: false, exact: change.isExact)
        case .same: change.isExact && change.measuredDelta != 0 ? Format.byteChange(change.measuredDelta) : "No change"
        case .unclear: "Can't tell"
        }
    }

    /// "735 MB → 935 MB", "new, 200 MB", "removed, was 120 MB".
    static func sizes(_ change: DiskSizeChange) -> String {
        if change.isNew, change.before.isExact { return "new, \(Format.bytes(change.after))" }
        if change.isGone, change.after.isExact { return "removed, was \(Format.bytes(change.before))" }
        return "\(Format.bytes(change.before)) → \(Format.bytes(change.after))"
    }

    /// Why a change can't be told exactly, if it can't.
    static func reason(_ change: DiskSizeChange) -> String? {
        if change.readabilityChanged { return "Part of it could be read in only one of the scans." }
        if !change.before.isBounded || !change.after.isBounded { return "Part of it couldn't be read." }
        if !change.isExact { return "It was too small to keep in a saved scan, so only a range is known." }
        return nil
    }

    /// The hover tag's line: "+200 MB since 9:59 AM · was 735 MB".
    static func summary(_ change: DiskSizeChange, _ direction: DiskSizeChange.Direction, since: Date) -> String {
        let time = when(since)
        if direction == .unclear {
            return "Can't tell how it changed since \(time). " + (reason(change) ?? "")
        }
        let was = change.before.isExact && change.before.low == 0 ? "new" : "was \(Format.bytes(change.before))"
        return "\(caption(change, direction)) since \(time) · \(was)"
    }

    /// "9:59 AM" today, "Oct 6, 9:59 AM" before.
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

extension DiskScanComparison {
    /// What the Changes list shows for the open folder.
    func report(for folder: DiskItem, in usage: DiskUsage) -> DiskScanReport {
        let path = later.scope.relativePath(usage.path(of: folder.id)) ?? ""
        return report(under: path, limit: 8, ignoringUnder: StorageChangeStyle.threshold(for: folder.allocatedSize))
    }
}

/// Beside the treemap in Changes mode: what changed in the open folder
/// since an earlier scan of the same place.
struct ChangesList: View {
    let store: StorageStore
    let usage: DiskUsage
    let folder: DiskItem
    let hover: StorageHover
    var pick: (_ change: DiskSizeChange, _ exists: Bool, _ opening: Bool) -> Void

    var body: some View {
        if let comparison = store.comparison, comparison.later.scannedAt == usage.finishedAt {
            ChangesReport(store: store, usage: usage, folder: folder, comparison: comparison, hover: hover, pick: pick)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
                Text(store.summary == nil ? "Saving this scan…" : "No earlier scan of this folder yet")
                    .font(.callout.weight(.medium))
                Text("Each scan is saved, the last \(DiskScanHistory.keptPerScope) of each folder. "
                    + "Scan again later to see what grew and shrank since this one.")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The open folder's total change, then what grew and shrank most inside
/// it and the large files that came and went.
private struct ChangesReport: View {
    private static let caveat = "Only changes both scans prove are counted: a folder too small to keep in a saved scan shows as a range, "
        + "and one only a single scan could read never counts as space freed. Deleted files may not free their space "
        + "while APFS snapshots or clones still hold it."

    let store: StorageStore
    let usage: DiskUsage
    let folder: DiskItem
    let comparison: DiskScanComparison
    let hover: StorageHover
    var pick: (DiskSizeChange, Bool, Bool) -> Void

    var body: some View {
        let threshold = StorageChangeStyle.threshold(for: folder.allocatedSize)
        let report = comparison.report(for: folder, in: usage)
        let path = report.path
        let direction = report.total.direction(ignoringUnder: threshold)
        let name = folder.name.isEmpty ? "this folder" : folder.name
        VStack(alignment: .leading, spacing: 8) {
            BaselineMenu(store: store, comparison: comparison)
            VStack(alignment: .leading, spacing: 2) {
                Text(StorageChangeStyle.caption(report.total, direction))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StorageChangeStyle.textStyle(direction))
                    .monospacedDigit()
                Text(direction == .unclear ? StorageChangeStyle.reason(report.total) ?? "" : "\(StorageChangeStyle.sizes(report.total)) in \(name)")
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help("Since \(comparison.earlier.scannedAt.formatted(date: .abbreviated, time: .shortened))")
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if report.isEmpty {
                            Text("Nothing in \(name) changed by more than \(Format.bytes(threshold)).")
                                .font(.explanation)
                                .foregroundStyle(.secondaryText)
                                .padding(.vertical, 4)
                        }
                        section("Grew", report.grew, under: path, amount: \.growth, grew: true)
                        section("Shrank", report.shrank, under: path, amount: \.shrinkage, grew: false)
                        section("Large files added", report.filesAdded, under: path, amount: \.growth, grew: true)
                        section("Large files removed", report.filesRemoved, under: path, amount: \.shrinkage, grew: false)
                        readability("Couldn't be read this time", report.becameUnreadable, under: path,
                                    note: "Not counted as space freed")
                        readability("Could be read this time", report.becameReadable, under: path, note: "Not counted as growth")
                        Text(Self.caveat)
                            .font(.explanation)
                            .foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                }
                .background(PickFollower(hover: hover, proxy: proxy))
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ changes: [DiskSizeChange], under path: String, amount: KeyPath<DiskSizeChange, UInt64>,
                         grew: Bool) -> some View {
        if !changes.isEmpty {
            SectionTitle(title: title)
            ForEach(changes) { change in
                ChangeRow(store: store, root: usage.rootPath, under: path, change: change,
                          amount: Format.byteChange(change[keyPath: amount], grew: grew, exact: change.isExact),
                          direction: grew ? .grew : .shrank, detail: StorageChangeStyle.sizes(change), hover: hover, pick: pick)
            }
        }
    }

    @ViewBuilder
    private func readability(_ title: String, _ changes: [DiskSizeChange], under path: String, note: String) -> some View {
        if !changes.isEmpty {
            SectionTitle(title: title)
            ForEach(changes) { change in
                ChangeRow(store: store, root: usage.rootPath, under: path, change: change, amount: nil, direction: .unclear,
                          detail: note, hover: hover, pick: pick)
            }
        }
    }
}

private struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.explanation.weight(.semibold))
            .foregroundStyle(.secondaryText)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One folder or file that changed: its name and change, then where it is
/// and its size before and after. Click to pick it and outline it in the
/// treemap.
private struct ChangeRow: View {
    let store: StorageStore
    let root: String
    /// The open folder, below the scanned one.
    let under: String
    let change: DiskSizeChange
    let amount: String?
    let direction: DiskSizeChange.Direction
    let detail: String
    let hover: StorageHover
    var pick: (DiskSizeChange, Bool, Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        let fullPath = (root as NSString).appendingPathComponent(change.path)
        // Not in this scan: nothing to outline or reveal.
        let gone = !change.isListed && change.after.low == 0 && direction != .unclear
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(StorageChangeStyle.fill(direction))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(change.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let amount {
                        Text(amount).foregroundStyle(StorageChangeStyle.textStyle(direction)).monospacedDigit().fixedSize()
                    }
                }
                .font(.callout)
                Text(location.map { "\($0) · \(detail)" } ?? detail)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(ChangeHighlight(id: change.id, isHovering: isHovering, hover: hover))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { pick(change, !gone, false) }
        .contextMenu {
            Button("Show in Treemap") { pick(change, !gone, false) }
            Button("Open Enclosing Folder") { pick(change, !gone, true) }
            Divider()
            if !gone { Button("Reveal in Finder") { store.reveal(fullPath) } }
            Button("Copy Path") { store.copyPath(fullPath) }
        }
        .help("\((fullPath as NSString).abbreviatingWithTildeInPath)\n\(StorageChangeStyle.sizes(change))"
            + (StorageChangeStyle.reason(change).map { "\n\($0)" } ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var symbol: String {
        if direction == .unclear { return "lock.fill" }
        switch change.kind {
        case .folder: return "folder.fill"
        case .package: return "shippingbox.fill"
        case .file: return "doc.fill"
        }
    }

    /// The folder holding it, as a trail below the open folder ("Projects ›
    /// webapp", as the treemap's tag writes it); nil when that's the open folder.
    private var location: String? {
        let trail = Format.trail(change.parentPath, under: under)
        return trail.isEmpty ? nil : trail
    }
}

/// Scrolls the picked change's row into view, such as the largest change
/// when the list opens. Its own view, so only it reads the pick here.
private struct PickFollower: View {
    let hover: StorageHover
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: hover.markedChange, initial: true) {
                if let id = hover.markedChange { proxy.scrollTo(id) }
            }
    }
}

/// A change row's background: the picked one in the accent colour, like
/// its outline in the treemap. Its own view, so a pick redraws only these.
private struct ChangeHighlight: View {
    let id: String
    let isHovering: Bool
    let hover: StorageHover

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        if hover.markedChange == id {
            shape.fill(Color.accentColor.opacity(0.16)).overlay(shape.strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
        } else {
            shape.fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        }
    }
}

/// Which earlier scan the changes are since, and a way to pick another.
private struct BaselineMenu: View {
    let store: StorageStore
    let comparison: DiskScanComparison

    var body: some View {
        let selection = Binding(get: { comparison.earlier.scannedAt }, set: { date in
            if let earlier = store.history.first(where: { $0.scannedAt == date }) { store.compare(with: earlier) }
        })
        Menu {
            Picker("Compare With", selection: selection) {
                ForEach(store.history, id: \.scannedAt) { earlier in
                    Text("\(StorageChangeStyle.when(earlier.scannedAt)) — \(Format.bytes(earlier.allocatedSize))").tag(earlier.scannedAt)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Forget Saved Scans of This Folder") { store.forgetSavedScans() }
        } label: {
            Text("Since \(StorageChangeStyle.when(comparison.earlier.scannedAt))")
        }
        .fixedSize()
        .help("Compare with an earlier scan of this folder. The last \(DiskScanHistory.keptPerScope) scans of each folder are kept.")
    }
}
