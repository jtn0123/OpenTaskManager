import AppKit
import OTMKit
import SwiftUI

/// What's using the disk: pick Home, a volume or any folder, and a scan on
/// its own thread adds up every file. The results show as a treemap you can
/// open folder by folder, a ranked list beside it, the largest files and the
/// space by category.
///
/// Nothing is read until asked (the Scan button or a scope pick), the page
/// reads nothing from `AppModel`, and the last scan is kept for the session,
/// so the page costs nothing while it sits open.
struct StorageView: View {
    private let store = StorageStore.shared
    @State private var hover = StorageHover()

    var body: some View {
        Group {
            if let scope = store.scanning {
                StorageProgressView(store: store, scope: scope)
            } else if let result = store.result {
                StorageResultsView(store: store, result: result, hover: hover)
            } else {
                StorageStartView(store: store)
            }
        }
        .toolbar {
            ToolbarItem {
                ScopeMenu(store: store)
            }
            ToolbarItem {
                if store.isScanning {
                    Button {
                        store.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Stop scanning")
                } else {
                    Button {
                        store.rescan()
                    } label: {
                        Label(store.result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Scan \(store.scope.title) (\(store.scope.subtitle))")
                }
            }
        }
        .task {
            await store.loadVolumes()
            store.handleLaunchArguments()
        }
    }
}

/// Picks what to scan; picking starts the scan.
private struct ScopeMenu: View {
    let store: StorageStore

    var body: some View {
        Menu {
            ForEach(store.scopes) { scope in
                Button {
                    store.scan(scope)
                } label: {
                    Label("\(scope.title) — \(scope.subtitle)", systemImage: scope.symbol)
                }
            }
            Divider()
            Button {
                store.chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label(store.scope.title, systemImage: store.scope.symbol)
        }
        .labelStyle(.titleAndIcon)
        .help("Choose what to scan")
    }
}

/// The right-click actions for an item. Nothing here deletes anything.
struct StorageItemMenu: View {
    let path: String
    let isFolder: Bool
    let store: StorageStore

    var body: some View {
        Button("Reveal in Finder") { store.reveal(path) }
        Button("Copy Path") { store.copyPath(path) }
        if isFolder {
            Divider()
            Button("Scan This Folder") { store.scan(.folder(URL(fileURLWithPath: path, isDirectory: true))) }
        }
    }
}

// MARK: - Before a scan

/// A card per place to scan, since nothing is scanned until asked.
private struct StorageStartView: View {
    let store: StorageStore

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(28)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "chart.pie")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [Theme.disk, Theme.cpu], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityHidden(true)
                Text("What's using your disk space?").font(.title2.weight(.semibold))
                Text("Pick a place to scan. Nothing is read until you do, and nothing is ever deleted.")
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
            }
            FillGrid(minimum: 220, spacing: 14) {
                ForEach(store.scopes) { scope in
                    ScopeCard(symbol: scope.symbol, title: scope.title, subtitle: scope.subtitle,
                              detail: Self.detail(scope), volume: scope.volume) {
                        store.scan(scope)
                    }
                }
                ScopeCard(symbol: "folder.badge.plus", title: "Choose Folder…", subtitle: "Any folder, on any disk",
                          detail: "Scan just the folder you pick.", volume: nil) {
                    store.chooseFolder()
                }
            }
            .frame(maxWidth: 820)
            Text("Folders macOS keeps private (Mail, Messages, other apps' data) are counted as unreadable "
                + "unless OpenTaskManager has Full Disk Access.")
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
    }

    private static func detail(_ scope: StorageScope) -> String {
        switch scope {
        case .home: "Your files, and your apps' settings and caches."
        case let .volume(volume): volume.isRoot ? "Everything on the startup disk." : "Everything on this disk."
        case .folder: "This folder and everything in it."
        }
    }
}

extension StorageScope {
    var volume: VolumeInfo? {
        if case let .volume(volume) = self { return volume }
        return nil
    }
}

private struct ScopeCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let detail: String
    let volume: VolumeInfo?
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Card(tint: Theme.disk, glow: isHovering ? 0.55 : 0.08) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Theme.disk).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(detail).font(.metadata).foregroundStyle(.secondaryText).fixedSize(horizontal: false, vertical: true)
                if let volume, volume.totalBytes > 0 {
                    let used = Double(volume.usedBytes) / Double(volume.totalBytes)
                    VStack(alignment: .leading, spacing: 4) {
                        ShareBar(segments: [(Theme.disk, used), (Color.secondary.opacity(0.25), 1 - used)]).frame(height: 6)
                        Text("\(Format.bytes(volume.usedBytes)) used of \(Format.bytes(volume.totalBytes))")
                            .font(.metadata)
                            .foregroundStyle(.secondaryText)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                Label("Scan", systemImage: "magnifyingglass").font(.callout.weight(.medium)).foregroundStyle(Theme.disk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The focus ring traced the card's old frame; the hover glow does its job.
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help("Scan \(title)")
    }
}

// MARK: - While scanning

/// How far a scan has got. It alone reads the progress, so the rest of the
/// window stays still while the figures move (at most four times a second).
private struct StorageProgressView: View {
    let store: StorageStore
    let scope: StorageScope

    var body: some View {
        let progress = store.progress
        VStack {
            Card(tint: Theme.disk, glow: 0.3) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: scope.symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.disk).frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning \(scope.title)…").font(.title3.weight(.semibold))
                        Text(scope.subtitle).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button("Stop", role: .cancel) { store.stop() }
                        .keyboardShortcut(.cancelAction)
                }
                if let expected = scope.expectedBytes, expected > 0 {
                    ProgressView(value: min(Double(progress?.allocatedSize ?? 0) / Double(expected), 1))
                        .help("Compared with the space the volume reports used, so it's only a rough guide")
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        figure("Items", (progress?.itemCount ?? 0).formatted())
                        figure("Found", Format.bytes(progress?.allocatedSize ?? 0))
                        figure("Elapsed", Duration.seconds(progress?.elapsed ?? 0).formatted(.time(pattern: .minuteSecond)))
                        figure("Unreadable", (progress?.unreadableFolders ?? 0).formatted())
                    }
                }
                Text(progress.map { ($0.currentFolder as NSString).abbreviatingWithTildeInPath } ?? "Starting…")
                    .font(.metadata.monospaced())
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560)
            Text("You can switch pages; the scan carries on and its results stay until you quit.")
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                .padding(.top, 10)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.metadata).foregroundStyle(.secondaryText)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
    }
}

// MARK: - Results

private struct StorageResultsView: View {
    let store: StorageStore
    let result: StorageResult
    let hover: StorageHover

    var body: some View {
        let usage = result.usage
        let folder = usage.items.indices.contains(store.folder) ? usage.items[store.folder] : usage.root
        // This scan's comparison, once saved; the treemap shows it in Changes mode.
        let comparison = store.comparison.flatMap { $0.later.scannedAt == usage.finishedAt ? $0 : nil }
        let changes = store.list == .changes ? comparison.map(TreemapChanges.init) : nil
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SummaryCard(store: store, result: result, comparison: comparison)
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: 340)
                CategoriesCard(usage: usage)
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            GeometryReader { proxy in
                HStack(spacing: 12) {
                    TreemapCard(store: store, result: result, folder: folder, hover: hover, changes: changes, open: open)
                    StorageListCard(store: store, usage: usage, folder: folder, hover: hover, open: open, show: show)
                        .frame(width: min(max(proxy.size.width * 0.36, 250), 340))
                }
            }
            .frame(minHeight: 200)
            StorageFooter(store: store, usage: usage)
        }
        .padding(16)
    }

    private func open(_ id: Int) {
        hover.enter(nil)
        hover.marked = nil
        hover.markedFile = nil
        store.folder = id
    }

    /// Opens the folder holding `path` and, if it's in this scan, outlines
    /// the tile it's in: its own, or the one for the folder or smaller items
    /// holding it.
    private func show(_ path: String, exists: Bool) {
        let usage = result.usage
        let folder = usage.closestFolder(to: (path as NSString).deletingLastPathComponent)
        let base = usage.path(of: folder.id)
        let next = path.dropFirst(base.count).split(separator: "/").first.map(String.init)
        let children = usage.children(of: folder)
        let target = exists ? children.first { $0.name == next } ?? children.first { $0.kind == .smallerItems } : nil
        hover.enter(nil)
        store.folder = folder.id
        hover.marked = target.map { (folder: folder.id, item: $0.id) }
        hover.markedFile = path
    }
}

/// The scan's total, with the counts behind it and what changed since the
/// last scan of the same place.
private struct SummaryCard: View {
    let store: StorageStore
    let result: StorageResult
    let comparison: DiskScanComparison?

    var body: some View {
        let usage = result.usage
        Card(tint: Theme.disk, glow: 0.15) {
            VStack(alignment: .leading, spacing: 1) {
                Label(result.scope.title, systemImage: result.scope.symbol).font(.headline).foregroundStyle(Theme.disk)
                Text(result.scope.subtitle).font(.metadata).foregroundStyle(.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.bytes(usage.root.allocatedSize)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                Text("on disk").foregroundStyle(.secondaryText)
            }
            .help("Space on disk: whole blocks, with each hard-linked file counted once")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.bytes(usage.root.logicalSize)) logical size")
                    .help("The files' own lengths, as Finder's Size column shows them")
                Text("\(usage.fileCount.formatted()) files in \(usage.folderCount.formatted()) folders")
                Text("Scanned at \(usage.finishedAt.formatted(date: .omitted, time: .shortened)), took \(Self.duration(usage.duration))")
                if let comparison { change(comparison) }
            }
            .font(.metadata)
            .foregroundStyle(.secondaryText)
            .monospacedDigit()
        }
    }

    /// "+200 MB since 9:59 AM", which opens the Changes list.
    private func change(_ comparison: DiskScanComparison) -> some View {
        let total = comparison.total
        let direction = total.direction(ignoringUnder: StorageChangeStyle.threshold(for: usage.root.allocatedSize))
        return Button {
            store.list = .changes
        } label: {
            HStack(spacing: 4) {
                Text(StorageChangeStyle.caption(total, direction)).foregroundStyle(StorageChangeStyle.textStyle(direction)).fontWeight(.medium)
                Text("since \(StorageChangeStyle.when(comparison.earlier.scannedAt))")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .help("Show what changed since the scan at \(comparison.earlier.scannedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private var usage: DiskUsage { result.usage }

    private static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 0.1 { return "under 0.1 s" }
        if seconds < 60 { return "\(Format.fixed(seconds, seconds < 10 ? 1 : 0)) s" }
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// The space by category, as one bar and a legend with each one's share.
private struct CategoriesCard: View {
    private static let columns = [GridItem(.adaptive(minimum: 190), spacing: 18, alignment: .leading)]

    let usage: DiskUsage

    var body: some View {
        let shown = usage.categories.filter { $0.allocatedSize > 0 }
        let total = Double(max(shown.reduce(0) { $0 + $1.allocatedSize }, 1))
        Card(tint: shown.first.map { Theme.category($0.category) } ?? Theme.disk) {
            Text("By Category").font(.headline)
            if shown.isEmpty {
                Text("Nothing here takes up space.").font(.metadata).foregroundStyle(.secondaryText)
            }
            ShareBar(segments: shown.map { (Theme.category($0.category), Double($0.allocatedSize)) })
                .frame(height: 12)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 5) {
                ForEach(shown) { entry in
                    let share = Double(entry.allocatedSize) / total
                    HStack(spacing: 6) {
                        Circle().fill(Theme.category(entry.category)).frame(width: 8, height: 8)
                        Text(entry.category.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.bytes(entry.allocatedSize)).monospacedDigit()
                        Text(Format.percent(share, digits: share < 0.1 ? 1 : 0))
                            .foregroundStyle(.secondaryText)
                            .monospacedDigit()
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    .font(.metadata)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("\(entry.category.title): \(Format.bytes(entry.allocatedSize)) on disk, "
                        + "\(Format.percent(share, digits: 1)) of the total")
                }
            }
        }
    }
}

/// The treemap of the open folder, with the way back above it and what the
/// pointer is over below.
private struct TreemapCard: View {
    let store: StorageStore
    let result: StorageResult
    let folder: DiskItem
    let hover: StorageHover
    let changes: TreemapChanges?
    var open: (Int) -> Void
    @State private var copied = false

    var body: some View {
        let usage = result.usage
        let path = usage.path(of: folder.id)
        Card(tint: nil) {
            HStack(spacing: 8) {
                StorageBreadcrumb(usage: usage, scope: result.scope, folder: folder, open: open)
                Spacer(minLength: 8)
                Button {
                    store.reveal(path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal this folder in Finder")
                .accessibilityLabel("Reveal in Finder")
                Button {
                    store.copyPath(path)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this folder's path")
                .accessibilityLabel("Copy Path")
            }
            Group {
                if usage.children(of: folder).contains(where: { $0.allocatedSize > 0 }) {
                    StorageTreemap(usage: usage, folder: folder, hover: hover, changes: changes) { item in
                        open(item.id)
                    } menu: { item in
                        StorageItemMenu(path: usage.path(of: item.id), isFolder: item.isFolder, store: store)
                    }
                } else {
                    EmptyFolder(store: store, usage: usage, folder: folder)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                TreemapCaption(usage: usage, folder: folder, hover: hover, changes: changes)
                Spacer(minLength: 8)
                Text(caption)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }

    /// The open folder's size, or in Changes mode which scan the colours compare with.
    private var caption: String {
        if let changes { return "Since \(StorageChangeStyle.when(changes.since))" }
        return "\(Format.bytes(folder.allocatedSize)) · \(folder.itemCount.formatted()) items"
    }
}

/// Why an open folder has no tiles.
private struct EmptyFolder: View {
    let store: StorageStore
    let usage: DiskUsage
    let folder: DiskItem

    var body: some View {
        if folder.isUnreadable {
            ContentUnavailableView {
                Label("Couldn't read this folder", systemImage: "lock")
            } description: {
                Text("macOS keeps it private unless OpenTaskManager has Full Disk Access.")
            } actions: {
                Button("Open Full Disk Access Settings") { store.openFullDiskAccessSettings() }
            }
        } else if folder.contentsOmitted {
            ContentUnavailableView {
                Label("Only the total was kept", systemImage: "square.dashed")
            } description: {
                Text("To keep memory down on a big scan, folders under \(Format.bytes(usage.detailThreshold)) "
                    + "keep their size but not their contents.")
            } actions: {
                Button("Scan This Folder") { store.scan(.folder(URL(fileURLWithPath: usage.path(of: folder.id), isDirectory: true))) }
            }
        } else {
            ContentUnavailableView("Nothing here takes up space", systemImage: "folder",
                                   description: Text("This folder is empty, or holds only empty files."))
        }
    }
}

/// The unreadable-folder warning and why the totals can differ from the volume's.
private struct StorageFooter: View {
    private static let explanation = "Sizes are space on disk. They won't match the space the volume reports used: "
        + "APFS clones and snapshots, purgeable files and unreadable folders count differently."

    let store: StorageStore
    let usage: DiskUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usage.unreadableFolders > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(usage.unreadableFolders == 1
                        ? "1 folder couldn't be read."
                        : "\(usage.unreadableFolders.formatted()) folders couldn't be read.")
                        .fontWeight(.medium)
                    Text("Give OpenTaskManager Full Disk Access to count them.").foregroundStyle(.secondaryText)
                    Button("Open Full Disk Access Settings") { store.openFullDiskAccessSettings() }
                        .buttonStyle(.link)
                }
                .lineLimit(1)
                .help(usage.unreadablePaths.prefix(5).map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"))
            }
            Text(Self.explanation)
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.metadata)
    }
}
