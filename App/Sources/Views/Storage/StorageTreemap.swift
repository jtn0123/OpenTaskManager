import OTMKit
import SwiftUI

/// What the pointer is over, shared by the treemap, its caption and the
/// list beside it. Only the views that read it redraw when it changes; the
/// tiles never do.
@Observable
@MainActor
final class StorageHover {
    /// Where the pointer is.
    enum Source {
        case treemap
        case list
    }

    /// The item under the pointer, in the treemap or the list.
    private(set) var item: Int?
    /// Which view `item` came from: the list follows the treemap, not itself.
    private(set) var source = Source.list
    /// An item picked in the Largest Files list, outlined while its folder shows.
    var marked: (folder: Int, item: Int)?
    /// The file picked in the Largest Files list.
    var markedFile: String?

    func enter(_ id: Int?, from source: Source = .list) {
        if self.source != source { self.source = source }
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
        /// Which of the name and size fit, measured once with the layout.
        let label: TreemapLabel.Fit

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

    /// The labels' fonts, which `TileLabel` draws them in too.
    @MainActor static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    @MainActor static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Space between a label and its tile's edges.
    static let labelInset = CGSize(width: 6, height: 4)
    static let headerSpacing: CGFloat = 5

    let key: Key
    let tiles: [Tile]

    @MainActor
    init(usage: DiskUsage, folder: DiskItem, size: CGSize) {
        key = Key(scan: usage.finishedAt, folder: folder.id, size: size)
        let children = usage.children(of: folder).filter { $0.allocatedSize > 0 }
        let rects = Treemap.squarify(children.map { Double($0.allocatedSize) }, in: CGRect(origin: .zero, size: size))
        tiles = zip(children, rects).compactMap { item, rect in
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            // A hairline gap between neighbours, unless the tile is a sliver.
            let tile = rect.width > 4 && rect.height > 4 ? rect.insetBy(dx: 1, dy: 1) : rect
            let name = Self.width(StorageStyle.name(item), Self.nameFont)
            let bytes = Self.width(Format.bytes(item.allocatedSize), Self.sizeFont)
            guard item.isFolder, !item.children.isEmpty, tile.width >= 80, tile.height >= 56 else {
                let room = CGSize(width: tile.width - 2 * Self.labelInset.width, height: tile.height - 2 * Self.labelInset.height)
                let label = TreemapLabel.tile(name: name, size: bytes, lineHeight: Self.lineHeight, room: room)
                return Tile(item: item, rect: tile, header: nil, inner: [], label: label)
            }
            let header = CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: Self.headerHeight)
            let room = CGRect(x: tile.minX + 3, y: tile.minY + Self.headerHeight, width: tile.width - 6, height: tile.height - Self.headerHeight - 3)
            let label = TreemapLabel.header(name: name, size: bytes, spacing: Double(Self.headerSpacing),
                                            room: Double(header.width - 2 * Self.labelInset.width))
            return Tile(item: item, rect: tile, header: header, inner: Self.inner(of: item, in: usage, room: room), label: label)
        }
    }

    @MainActor private static let lineHeight = Double(ceil(nameFont.ascender - nameFont.descender + nameFont.leading))

    /// How wide `text` draws, with a point to spare for SwiftUI's rounding.
    @MainActor
    private static func width(_ text: String, _ font: NSFont) -> Double {
        Double(ceil((text as NSString).size(withAttributes: [.font: font]).width)) + 1
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
                TreemapPointer(layout: layout, folder: folder, hover: hover, open: open, menu: menu)
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

/// Name and size on tiles with room for them. The layout measured what
/// fits, so a label shows whole or not at all; hovering names the rest.
private struct TileLabel: View {
    let tile: TreemapLayout.Tile

    var body: some View {
        if tile.label != .none {
            let inset = TreemapLayout.labelInset
            if let header = tile.header {
                HStack(spacing: TreemapLayout.headerSpacing) {
                    name
                    if tile.label == .nameAndSize { size.foregroundStyle(.secondaryText) }
                }
                .padding(.horizontal, inset.width)
                .frame(width: header.width, height: header.height, alignment: .leading)
                .clipped()
                .offset(x: header.minX, y: header.minY)
                .allowsHitTesting(false)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    name
                    if tile.label == .nameAndSize { size.opacity(0.88) }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: 0.5)
                .padding(.horizontal, inset.width)
                .padding(.vertical, inset.height)
                .frame(width: tile.rect.width, height: tile.rect.height, alignment: .topLeading)
                .clipped()
                .offset(x: tile.rect.minX, y: tile.rect.minY)
                .allowsHitTesting(false)
            }
        }
    }

    private var name: some View {
        Text(StorageStyle.name(tile.item)).font(Font(TreemapLayout.nameFont)).fixedSize()
    }

    private var size: some View {
        Text(Format.bytes(tile.item.allocatedSize)).font(Font(TreemapLayout.sizeFont)).fixedSize()
    }
}

/// Reads the pointer: highlights the tile under it and names it in a tag,
/// opens folders on click, and offers the item's actions on right-click.
/// It alone redraws as the pointer moves, and only when the tile changes.
private struct TreemapPointer: View {
    let layout: TreemapLayout
    let folder: DiskItem
    let hover: StorageHover
    var open: (DiskItem) -> Void
    var menu: (DiskItem) -> StorageItemMenu

    var body: some View {
        let hovered = layout.tile(id: hover.item)
        let marked = hover.marked.flatMap { $0.folder == folder.id ? layout.tile(id: $0.item) : nil }
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let marked, marked.id != hovered?.id { Highlight(tile: marked, strength: 0.7) }
                    if let hovered { Highlight(tile: hovered, strength: 1) }
                }
            }
            .overlay {
                // Only for hovers here: the list beside it shows its own row.
                if let hovered, hover.source == .treemap {
                    TagPlacement(tile: hovered.rect) {
                        HoverTag(item: hovered.item, total: folder.allocatedSize)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hover.enter(layout.tile(at: point)?.item.id, from: .treemap)
                case .ended: hover.enter(nil, from: .treemap)
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

/// The hovered tile's full name, size and share of the folder, whether or
/// not its label fits on the tile.
private struct HoverTag: View {
    let item: DiskItem
    let total: UInt64

    var body: some View {
        let share = Double(item.allocatedSize) / Double(max(total, 1))
        var detail = "\(Format.bytes(item.allocatedSize)) · \(Format.percent(share, digits: share < 0.1 ? 1 : 0))"
        if item.kind != .file, item.kind != .smallerItems { detail += " · \(item.itemCount.formatted()) items" }
        let shape = RoundedRectangle(cornerRadius: 7)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(StorageStyle.color(item)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(StorageStyle.name(item))
                    .font(.callout.weight(.semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.metadata)
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.background, in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        // Drawn once per tile hovered, never per tick.
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
}

/// Puts the hover tag beside its tile, under or over it, inside the
/// treemap's bounds; the rules are `TreemapLabel.tagOrigin`.
private struct TagPlacement: Layout {
    static let maximumWidth: CGFloat = 260

    let tile: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tag = subviews.first else { return }
        let size = tag.sizeThatFits(ProposedViewSize(width: min(Self.maximumWidth, bounds.width), height: nil))
        let origin = TreemapLabel.tagOrigin(size: size, tile: tile, bounds: bounds.size)
        tag.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(size))
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
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.metadata)
        } else {
            Text(items.contains(where: \.isFolder) ? "Click a folder to open it" : "")
                .font(.metadata)
                .foregroundStyle(.secondaryText)
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
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondaryText)
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
                    .foregroundStyle(item.id == folder.id ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondaryText))
                    .lineLimit(1)
                    .truncationMode(.middle)
                } else {
                    Text("…").foregroundStyle(.secondaryText)
                }
            }
        }
        .font(.callout)
    }
}
