import OTMKit
import SwiftUI

/// What the pointer is over, shared by the treemap, its caption and the
/// list beside it. Only the views that read it redraw when it changes; the
/// tiles never do.
@Observable
@MainActor
final class StorageHover {
    /// The item under the pointer, in the treemap or the list.
    private(set) var item: Int?
    /// An item picked in the Largest Files list, outlined while its folder shows.
    var marked: (folder: Int, item: Int)?
    /// The file picked in the Largest Files list.
    var markedFile: String?

    func enter(_ id: Int?) {
        if item != id { item = id }
    }

    /// Clears the hover, unless the pointer has already moved on to another item.
    func leave(_ id: Int) {
        if item == id { item = nil }
    }
}

/// The squarified tiles for one folder's children, worked out once per
/// scan, folder and size, never per frame or per hover.
struct TreemapLayout: Equatable {
    struct Key: Equatable {
        let scan: Date
        let folder: Int
        let size: CGSize
    }

    struct Tile: Identifiable {
        let item: DiskItem
        let rect: CGRect
        /// For a folder big enough to show what's inside: the strip its name
        /// sits in, above tiles for its own children.
        let header: CGRect?
        let inner: [Inner]

        var id: Int { item.id }
    }

    /// A grandchild drawn inside its folder's tile.
    struct Inner {
        let color: Color
        let rect: CGRect
    }

    static let headerHeight: CGFloat = 20
    /// Grandchildren drawn per folder tile; the rest fill one grey tile.
    static let innerLimit = 60

    let key: Key
    let tiles: [Tile]

    init(usage: DiskUsage, folder: DiskItem, size: CGSize) {
        key = Key(scan: usage.finishedAt, folder: folder.id, size: size)
        let children = usage.children(of: folder).filter { $0.allocatedSize > 0 }
        let rects = Treemap.squarify(children.map { Double($0.allocatedSize) }, in: CGRect(origin: .zero, size: size))
        tiles = zip(children, rects).compactMap { item, rect in
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            // A hairline gap between neighbours, unless the tile is a sliver.
            let tile = rect.width > 4 && rect.height > 4 ? rect.insetBy(dx: 1, dy: 1) : rect
            guard item.isFolder, !item.children.isEmpty, tile.width >= 80, tile.height >= 56 else {
                return Tile(item: item, rect: tile, header: nil, inner: [])
            }
            let header = CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: Self.headerHeight)
            let room = CGRect(x: tile.minX + 3, y: tile.minY + Self.headerHeight, width: tile.width - 6, height: tile.height - Self.headerHeight - 3)
            return Tile(item: item, rect: tile, header: header, inner: Self.inner(of: item, in: usage, room: room))
        }
    }

    private static func inner(of folder: DiskItem, in usage: DiskUsage, room: CGRect) -> [Inner] {
        let children = usage.children(of: folder).filter { $0.allocatedSize > 0 }
        let shown = Array(children.prefix(innerLimit))
        let rest = children.dropFirst(innerLimit).reduce(0) { $0 + Double($1.allocatedSize) }
        var colors = shown.map(StorageStyle.color)
        var values = shown.map { Double($0.allocatedSize) }
        if rest > 0 {
            colors.append(Theme.smallerItems)
            values.append(rest)
        }
        return zip(colors, Treemap.squarify(values, in: room)).compactMap { color, rect in
            guard rect.width >= 2, rect.height >= 2 else { return nil }
            return Inner(color: color, rect: rect.width > 3 && rect.height > 3 ? rect.insetBy(dx: 0.5, dy: 0.5) : rect)
        }
    }

    static func == (lhs: TreemapLayout, rhs: TreemapLayout) -> Bool {
        lhs.key == rhs.key
    }

    func tile(at point: CGPoint) -> Tile? {
        tiles.first { $0.rect.contains(point) }
    }

    func tile(id: Int?) -> Tile? {
        guard let id else { return nil }
        return tiles.first { $0.item.id == id }
    }
}

/// Keeps the last layout, so the tiles are worked out once per scan, folder
/// and size however often the views around them redraw.
@MainActor
private final class TreemapCache {
    private var last: TreemapLayout?

    func layout(usage: DiskUsage, folder: DiskItem, size: CGSize) -> TreemapLayout {
        let key = TreemapLayout.Key(scan: usage.finishedAt, folder: folder.id, size: size)
        if let last, last.key == key { return last }
        let layout = TreemapLayout(usage: usage, folder: folder, size: size)
        last = layout
        return layout
    }
}

/// Colours and words shared by the Storage views.
enum StorageStyle {
    static func color(_ item: DiskItem) -> Color {
        item.kind == .smallerItems ? Theme.smallerItems : Theme.category(item.category)
    }

    static func name(_ item: DiskItem) -> String {
        item.kind == .smallerItems ? "\(item.itemCount.formatted()) smaller items" : item.name
    }
}

/// A drill-down treemap of one folder: a tile per child sized by its space
/// on disk and coloured by category, with each large folder showing its own
/// contents inside. Click a folder to open it.
struct StorageTreemap: View {
    let usage: DiskUsage
    let folder: DiskItem
    let hover: StorageHover
    var open: (DiskItem) -> Void
    var menu: (DiskItem) -> StorageItemMenu

    @State private var cache = TreemapCache()

    var body: some View {
        GeometryReader { proxy in
            let layout = cache.layout(usage: usage, folder: folder, size: proxy.size)
            ZStack(alignment: .topLeading) {
                TreemapTiles(layout: layout).equatable()
                TreemapPointer(layout: layout, folder: folder.id, hover: hover, open: open, menu: menu)
            }
        }
    }
}

/// The tiles and their labels. Equatable on the layout, so hovering (which
/// only the pointer layer reads) never redraws them.
private struct TreemapTiles: View, Equatable {
    let layout: TreemapLayout

    var body: some View {
        Canvas { context, _ in
            for tile in layout.tiles { draw(tile, in: &context) }
        }
        // An explicit stack: the overlay's own one centres its views on each
        // other, which would throw the offsets out.
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(layout.tiles) { tile in
                    TileLabel(tile: tile)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Treemap")
    }

    private func draw(_ tile: TreemapLayout.Tile, in context: inout GraphicsContext) {
        let color = StorageStyle.color(tile.item)
        let radius = min(4, tile.rect.width / 4, tile.rect.height / 4)
        let shape = RoundedRectangle(cornerRadius: radius).path(in: tile.rect)
        if tile.header != nil {
            // A folder showing its contents: a tinted frame with the name on
            // top, then a tile for each thing inside.
            context.fill(shape, with: .linearGradient(Gradient(colors: [color.opacity(0.38), color.opacity(0.20)]),
                                                      startPoint: tile.rect.origin, endPoint: CGPoint(x: tile.rect.minX, y: tile.rect.maxY)))
            context.stroke(shape, with: .color(color.opacity(0.75)), lineWidth: 1)
            for inner in tile.inner {
                let path = RoundedRectangle(cornerRadius: min(2, inner.rect.width / 4, inner.rect.height / 4)).path(in: inner.rect)
                context.fill(path, with: .linearGradient(Gradient(colors: [inner.color.opacity(0.95), inner.color.opacity(0.72)]),
                                                         startPoint: inner.rect.origin, endPoint: CGPoint(x: inner.rect.minX, y: inner.rect.maxY)))
            }
        } else {
            context.fill(shape, with: .linearGradient(Gradient(colors: [color, color.opacity(0.74)]),
                                                      startPoint: tile.rect.origin, endPoint: CGPoint(x: tile.rect.minX, y: tile.rect.maxY)))
            context.stroke(shape, with: .color(.white.opacity(0.14)), lineWidth: 1)
        }
        // A bright edge along the top, like the cards' sheen.
        if tile.rect.width > 8 {
            var sheen = Path()
            sheen.move(to: CGPoint(x: tile.rect.minX + radius, y: tile.rect.minY + 0.5))
            sheen.addLine(to: CGPoint(x: tile.rect.maxX - radius, y: tile.rect.minY + 0.5))
            context.stroke(sheen, with: .color(.white.opacity(0.30)), lineWidth: 1)
        }
    }
}

/// Name and size on tiles with room for them.
private struct TileLabel: View {
    let tile: TreemapLayout.Tile

    var body: some View {
        if let header = tile.header {
            HStack(spacing: 5) {
                Text(StorageStyle.name(tile.item)).fontWeight(.semibold)
                Text(Format.bytes(tile.item.allocatedSize)).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .frame(width: header.width, height: header.height, alignment: .leading)
            .offset(x: header.minX, y: header.minY)
            .allowsHitTesting(false)
        } else if tile.rect.width >= 58, tile.rect.height >= 32 {
            VStack(alignment: .leading, spacing: 0) {
                Text(StorageStyle.name(tile.item)).fontWeight(.semibold).truncationMode(.middle)
                Text(Format.bytes(tile.item.allocatedSize)).opacity(0.88).monospacedDigit()
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: 0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: tile.rect.width, height: tile.rect.height, alignment: .topLeading)
            .clipped()
            .offset(x: tile.rect.minX, y: tile.rect.minY)
            .allowsHitTesting(false)
        }
    }
}

/// Reads the pointer: highlights the tile under it, opens folders on
/// click, and offers the item's actions on right-click. It alone redraws
/// as the pointer moves.
private struct TreemapPointer: View {
    let layout: TreemapLayout
    let folder: Int
    let hover: StorageHover
    var open: (DiskItem) -> Void
    var menu: (DiskItem) -> StorageItemMenu

    var body: some View {
        let hovered = layout.tile(id: hover.item)
        let marked = hover.marked.flatMap { $0.folder == folder ? layout.tile(id: $0.item) : nil }
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let marked, marked.id != hovered?.id { Highlight(tile: marked, strength: 0.7) }
                    if let hovered { Highlight(tile: hovered, strength: 1) }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hover.enter(layout.tile(at: point)?.item.id)
                case .ended: hover.enter(nil)
                }
            }
            .onTapGesture { point in
                if let tile = layout.tile(at: point), tile.item.isFolder { open(tile.item) }
            }
            .contextMenu {
                if let hovered { menu(hovered.item) }
            }
    }
}

/// A bright outline with a soft halo, faked with a wide translucent stroke
/// rather than a blur.
private struct Highlight: View {
    let tile: TreemapLayout.Tile
    let strength: Double

    var body: some View {
        let color = StorageStyle.color(tile.item)
        ZStack {
            RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.55 * strength), lineWidth: 7)
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.16 * strength))
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.95 * strength), lineWidth: 2)
        }
        .frame(width: tile.rect.width, height: tile.rect.height)
        .offset(x: tile.rect.minX, y: tile.rect.minY)
        .allowsHitTesting(false)
    }
}

/// What's under the pointer, beside the breadcrumb.
struct TreemapCaption: View {
    let usage: DiskUsage
    let folder: DiskItem
    let hover: StorageHover

    var body: some View {
        let items = usage.children(of: folder)
        if let id = hover.item, let item = items.first(where: { $0.id == id }) {
            let share = Double(item.allocatedSize) / Double(max(folder.allocatedSize, 1))
            HStack(spacing: 6) {
                Circle().fill(StorageStyle.color(item)).frame(width: 8, height: 8)
                Text(StorageStyle.name(item)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text("\(Format.bytes(item.allocatedSize)) · \(Format.percent(share, digits: share < 0.1 ? 1 : 0))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.subheadline)
        } else {
            Text(items.contains(where: \.isFolder) ? "Click a folder to open it" : "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Where the treemap is: the scanned folder, then each folder opened.
struct StorageBreadcrumb: View {
    let usage: DiskUsage
    let scope: StorageScope
    let folder: DiskItem
    var open: (Int) -> Void

    var body: some View {
        let chain = usage.ancestry(of: folder.id)
        // Long trails keep the start and the last three folders.
        let shown: [DiskItem?] = chain.count > 5 ? [chain[0], nil] + chain.suffix(3) : chain
        HStack(spacing: 4) {
            Button {
                if let parent = folder.parent { open(parent) }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .disabled(folder.parent == nil)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Back to the enclosing folder (⌘↑)")
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                if let item {
                    Button {
                        open(item.id)
                    } label: {
                        if item.id == 0 {
                            Label(scope.title, systemImage: scope.symbol)
                        } else {
                            Text(item.name)
                        }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(item.id == folder.id ? .semibold : .regular)
                    .foregroundStyle(item.id == folder.id ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                } else {
                    Text("…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}
