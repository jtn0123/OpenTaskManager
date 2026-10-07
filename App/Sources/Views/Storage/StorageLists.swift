import AppKit
import OTMKit
import SwiftUI

/// Beside the treemap: the open folder's contents ranked by size, the
/// largest files anywhere in the scan, or what changed since an earlier scan.
struct StorageListCard: View {
    let store: StorageStore
    let usage: DiskUsage
    let folder: DiskItem
    let hover: StorageHover
    var open: (Int) -> Void
    /// Opens the folder holding a path and outlines its tile, if it's still there.
    var show: (_ path: String, _ exists: Bool) -> Void

    var body: some View {
        Card(tint: nil) {
            // The short titles when the list is narrow.
            ViewThatFits(in: .horizontal) {
                picker(\.rawValue)
                picker(\.shortTitle)
            }
            switch store.list {
            case .contents:
                FolderContentsList(store: store, usage: usage, folder: folder, hover: hover, open: open)
            case .largest:
                LargestFilesList(store: store, usage: usage, hover: hover) { show($0.path, true) }
            case .changes:
                ChangesList(store: store, usage: usage, folder: folder, show: show)
            }
        }
    }

    private func picker(_ title: KeyPath<StorageList, String>) -> some View {
        Picker("List", selection: Binding(get: { store.list }, set: { store.list = $0 })) {
            ForEach(StorageList.allCases) { Text($0[keyPath: title]).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - This folder

private struct FolderContentsList: View {
    let store: StorageStore
    let usage: DiskUsage
    let folder: DiskItem
    let hover: StorageHover
    var open: (Int) -> Void

    var body: some View {
        let children = usage.children(of: folder)
        if children.isEmpty {
            Text(folder.isUnreadable ? "Couldn't read this folder." : folder.contentsOmitted ? "Contents weren't kept." : "Empty folder.")
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(children) { item in
                            ContentRow(store: store, usage: usage, item: item, total: folder.allocatedSize, hover: hover, open: open)
                        }
                    }
                }
                .background(ListFollower(hover: hover, proxy: proxy))
            }
            .id(folder.id)
        }
    }
}

/// Scrolls the row for the tile under the pointer into view, so its
/// highlight shows. Its own view, so only it reads the hover here.
private struct ListFollower: View {
    let hover: StorageHover
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: hover.item) {
                // Hovers in the list itself are already in view.
                guard hover.source == .treemap, let id = hover.item else { return }
                proxy.scrollTo(id)
            }
    }
}

private struct ContentRow: View {
    let store: StorageStore
    let usage: DiskUsage
    let item: DiskItem
    let total: UInt64
    let hover: StorageHover
    var open: (Int) -> Void

    var body: some View {
        let share = Double(item.allocatedSize) / Double(max(total, 1))
        let path = usage.path(of: item.id)
        HStack(spacing: 8) {
            ItemIcon(item: item, path: path)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(StorageStyle.name(item)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Format.bytes(item.allocatedSize)).monospacedDigit().fixedSize()
                }
                .font(.callout)
                HStack(spacing: 6) {
                    ShareLine(share: share, color: StorageStyle.color(item)).frame(height: 4)
                    Text(detail(share: share)).font(.metadata).foregroundStyle(.secondaryText).monospacedDigit().fixedSize()
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondaryText)
                .opacity(item.isFolder ? 1 : 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RowHighlight(id: item.id, folder: item.parent ?? 0, color: StorageStyle.color(item), hover: hover))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hover.enter(item.id) } else { hover.leave(item.id) }
        }
        .onTapGesture {
            if item.isFolder { open(item.id) }
        }
        .contextMenu {
            StorageItemMenu(path: path, isFolder: item.isFolder, store: store)
        }
        .help(item.isFolder ? "Open \(item.name)" : (path as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.isFolder ? .isButton : [])
    }

    private func detail(share: Double) -> String {
        let percent = Format.percent(share, digits: share < 0.1 ? 1 : 0)
        if item.isUnreadable { return "\(percent) · unreadable" }
        switch item.kind {
        case .folder, .package: return "\(percent) · \(item.itemCount.formatted()) items"
        case .file, .smallerItems: return percent
        }
    }
}

/// The row background: lit while the pointer is over the item here or in
/// the treemap, in the item's tile colour so the two read as one. Its own
/// view, so a hover change redraws only these.
private struct RowHighlight: View {
    let id: Int
    let folder: Int
    let color: Color
    let hover: StorageHover

    var body: some View {
        let isHovered = hover.item == id
        let isMarked = hover.marked.map { $0.folder == folder && $0.item == id } ?? false
        let shape = RoundedRectangle(cornerRadius: 6)
        shape
            .fill(isHovered ? color.fillShade.opacity(0.22) : Color.primary.opacity(isMarked ? 0.06 : 0))
            .overlay {
                if isHovered {
                    shape.strokeBorder(color.opacity(0.6), lineWidth: 1)
                } else if isMarked {
                    shape.strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                }
            }
    }
}

/// A thin bar showing an item's share of the folder.
private struct ShareLine: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(proxy.size.width * min(max(share, 0), 1), share > 0 ? 3 : 0))
            }
        }
    }
}

private struct ItemIcon: View {
    let item: DiskItem
    let path: String

    var body: some View {
        Group {
            switch item.kind {
            case .smallerItems:
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.smallerItems)
            case .folder, .package, .file:
                Image(nsImage: StorageIcons.icon(forFile: path)).resizable()
            }
        }
        .frame(width: 22, height: 22)
        .overlay(alignment: .bottomTrailing) {
            if item.isUnreadable {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .accessibilityHidden(true)
    }
}

/// File icons by path, bounded so a long session of drilling stays small.
/// `NSWorkspace.icon(forFile:)` reads the disk, so each path is asked once.
@MainActor
enum StorageIcons {
    private static let limit = 800
    private static var icons: [String: NSImage] = [:]

    static func icon(forFile path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        if icons.count >= limit { icons.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        icons[path] = image
        return image
    }
}

// MARK: - Largest files

private struct LargestFilesList: View {
    let store: StorageStore
    let usage: DiskUsage
    let hover: StorageHover
    var show: (DiskFile) -> Void

    var body: some View {
        if usage.largestFiles.isEmpty {
            Text("No files.")
                .font(.metadata)
                .foregroundStyle(.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(usage.largestFiles) { file in
                        FileRow(store: store, usage: usage, file: file, hover: hover, show: show)
                    }
                }
            }
        }
    }
}

private struct FileRow: View {
    let store: StorageStore
    let usage: DiskUsage
    let file: DiskFile
    let hover: StorageHover
    var show: (DiskFile) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: StorageIcons.icon(forFile: file.path))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Format.bytes(file.allocatedSize)).monospacedDigit().fixedSize()
                }
                .font(.callout)
                HStack(spacing: 5) {
                    Circle().fill(Theme.category(file.category)).frame(width: 7, height: 7)
                    Text(location).lineLimit(1).truncationMode(.head)
                }
                .font(.metadata)
                .foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(FileHighlight(path: file.path, hover: hover))
        .contentShape(Rectangle())
        .onTapGesture { show(file) }
        .contextMenu {
            Button("Show in Treemap") { show(file) }
            Divider()
            StorageItemMenu(path: file.path, isFolder: false, store: store)
        }
        .help("\(file.category.title) · \((file.path as NSString).abbreviatingWithTildeInPath)\nClick to show it in the treemap")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The enclosing folder, relative to the scanned folder when it's inside.
    private var location: String {
        let folder = file.folder
        if folder == usage.rootPath { return "Top level" }
        if folder.hasPrefix(usage.rootPath) {
            let relative = folder.dropFirst(usage.rootPath.count).drop { $0 == "/" }
            return String(relative)
        }
        return (folder as NSString).abbreviatingWithTildeInPath
    }
}

private struct FileHighlight: View {
    let path: String
    let hover: StorageHover

    var body: some View {
        let isMarked = hover.markedFile == path
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(isMarked ? 0.16 : 0))
            .overlay {
                if isMarked { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1) }
            }
    }
}
