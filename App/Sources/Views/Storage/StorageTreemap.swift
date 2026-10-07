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
    /// Inside a folder's tile: the item drawn in it under the pointer.
    private(set) var inner: Int?
    /// Which view `item` came from: the list follows the treemap, not itself.
    private(set) var source = Source.list
    /// The item picked in the Largest Files or Changes list (or what stands
    /// for it), as the items from the scanned folder down to it, so the
    /// treemap can outline the tile holding it in whichever folder is open.
    private(set) var marked: [Int] = []
    /// The file picked in the Largest Files list.
    private(set) var markedFile: String?
    /// The change picked in the Changes list (a `DiskSizeChange.id`).
    private(set) var markedChange: String?

    func enter(_ id: Int?, inner: Int? = nil, from source: Source = .list) {
        if self.source != source { self.source = source }
        if item != id { item = id }
        if self.inner != inner { self.inner = inner }
    }

    /// Clears the hover, unless the pointer has already moved on to another item.
    func leave(_ id: Int) {
        guard item == id else { return }
        item = nil
        inner = nil
    }

    /// Marks the item at `path` in `usage`: itself, or what stands for it
    /// there (see `DiskUsage.closestItem`), picked as a file or a change.
    func mark(_ path: String, exists: Bool, in usage: DiskUsage, file: String? = nil, change: String? = nil) {
        let chain = usage.ancestry(of: usage.closestItem(to: path, exists: exists).id).map(\.id)
        if marked != chain { marked = chain }
        if markedFile != file { markedFile = file }
        if markedChange != change { markedChange = change }
    }

    func clearMarks() {
        if !marked.isEmpty { marked = [] }
        if markedFile != nil { markedFile = nil }
        if markedChange != nil { markedChange = nil }
    }
}

/// The comparison the treemap colours its tiles by in Changes mode.
struct TreemapChanges {
    let comparison: DiskScanComparison

    var since: Date { comparison.earlier.scannedAt }

    /// How `item` changed, from its size in this scan; nil for a "smaller
    /// items" row, which stands for many things.
    func change(of item: DiskItem, in usage: DiskUsage) -> DiskSizeChange? {
        guard item.kind != .smallerItems, let path = comparison.later.scope.relativePath(usage.path(of: item.id)) else { return nil }
        switch item.kind {
        case .file:
            return comparison.change(ofFile: path, now: item.allocatedSize)
        case .package:
            return comparison.change(ofFolder: path, isPackage: true, now: .exact(item.allocatedSize))
        case .folder, .smallerItems:
            // A folder this scan couldn't open could hold anything.
            let now = item.isUnreadable
                ? DiskSizeEstimate(low: item.allocatedSize, high: .max, unreadableCount: item.unreadableCount)
                : .exact(item.allocatedSize, unreadableCount: item.unreadableCount)
            return comparison.change(ofFolder: path, now: now)
        }
    }
}

/// A tile's colour and second line: its category and size, or in Changes
/// mode which way it went and by how much.
struct TileLook {
    /// The grey tile for everything past a folder's first `innerLimit` items.
    static let rest = TileLook(color: Theme.smallerItems, caption: "", change: nil, direction: nil)

    let color: Color
    let caption: String
    let change: DiskSizeChange?
    let direction: DiskSizeChange.Direction?

    var isHatched: Bool { direction == .unclear }
    /// In Changes mode, nothing to see: no change, or a "smaller items"
    /// tile, which stands for many things.
    var isUnchanged: Bool { direction == nil || direction == .same }

    private init(color: Color, caption: String, change: DiskSizeChange?, direction: DiskSizeChange.Direction?) {
        self.color = color
        self.caption = caption
        self.change = change
        self.direction = direction
    }

    init(_ item: DiskItem, changes: TreemapChanges?, in usage: DiskUsage, threshold: UInt64) {
        guard let changes, let change = changes.change(of: item, in: usage) else {
            self.init(color: StorageStyle.color(item), caption: Format.bytes(item.allocatedSize), change: nil, direction: nil)
            return
        }
        let direction = change.direction(ignoringUnder: threshold)
        self.init(color: StorageChangeStyle.fill(direction), caption: StorageChangeStyle.caption(change, direction), change: change,
                  direction: direction)
    }
}

/// The squarified tiles for one folder's children, worked out once per
/// scan, folder, size and comparison, never per frame or per hover.
struct TreemapLayout: Equatable {
    struct Key: Equatable {
        let scan: Date
        let folder: Int
        let size: CGSize
        /// The earlier scan the tiles show changes since, in Changes mode.
        let since: Date?
    }

    struct Tile: Identifiable {
        let item: DiskItem
        let rect: CGRect
        /// For a folder big enough to show what's inside: the strip its name
        /// sits in, above tiles for its own children.
        let header: CGRect?
        let inner: [Inner]
        /// Which of the name and caption fit, measured once with the layout.
        let label: TreemapLabel.Fit
        /// The name as drawn: whole, or a file's without its extension when
        /// only that fits.
        let title: String
        let look: TileLook

        var id: Int { item.id }
    }

    /// A grandchild drawn inside its folder's tile, labelled when its name
    /// and caption fit.
    struct Inner {
        /// Nil for the grey tile standing for everything past `innerLimit`.
        let item: DiskItem?
        let rect: CGRect
        let look: TileLook
        let label: TreemapLabel.Fit
        let title: String
    }

    static let headerHeight: CGFloat = 20
    /// Grandchildren drawn per folder tile; the rest fill one grey tile.
    static let innerLimit = 60

    /// The labels' fonts, which `TileLabel` draws them in too.
    @MainActor static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    @MainActor static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// A point smaller inside a folder's tile, so grandchildren read as inside it.
    @MainActor static let innerNameFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    @MainActor static let innerSizeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    /// Space between a label and its tile's edges.
    static let labelInset = CGSize(width: 6, height: 4)
    static let innerInset = CGSize(width: 4, height: 2)
    static let headerSpacing: CGFloat = 5

    @MainActor static let lineHeight = lineHeight(of: nameFont)
    @MainActor static let innerLineHeight = lineHeight(of: innerNameFont)

    let key: Key
    let tiles: [Tile]

    var since: Date? { key.since }

    @MainActor
    init(usage: DiskUsage, folder: DiskItem, size: CGSize, changes: TreemapChanges? = nil) {
        key = Key(scan: usage.finishedAt, folder: folder.id, size: size, since: changes?.since)
        // One yardstick for the whole map, so a colour means the same in every tile.
        let threshold = StorageChangeStyle.threshold(for: folder.allocatedSize)
        let children = usage.children(of: folder).filter { $0.allocatedSize > 0 }
        let rects = Treemap.squarify(children.map { Double($0.allocatedSize) }, in: CGRect(origin: .zero, size: size))
        tiles = zip(children, rects).compactMap { item, rect in
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            // A hairline gap between neighbours, unless the tile is a sliver.
            let tile = rect.width > 4 && rect.height > 4 ? rect.insetBy(dx: 1, dy: 1) : rect
            let look = TileLook(item, changes: changes, in: usage, threshold: threshold)
            let name = StorageStyle.name(item)
            guard item.isFolder, !item.children.isEmpty, tile.width >= 80, tile.height >= 56 else {
                let room = CGSize(width: tile.width - 2 * Self.labelInset.width, height: tile.height - 2 * Self.labelInset.height)
                let (label, title) = Self.label(item, name: name, caption: look.caption, room: room, inner: false)
                return Tile(item: item, rect: tile, header: nil, inner: [], label: label, title: title, look: look)
            }
            let header = CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: Self.headerHeight)
            let room = CGRect(x: tile.minX + 3, y: tile.minY + Self.headerHeight, width: tile.width - 6, height: tile.height - Self.headerHeight - 3)
            let label = TreemapLabel.header(name: Self.width(name, Self.nameFont), size: Self.width(look.caption, Self.sizeFont),
                                            spacing: Double(Self.headerSpacing), room: Double(header.width - 2 * Self.labelInset.width))
            let inner = Self.inner(of: item, in: usage, room: room, changes: changes, threshold: threshold)
            return Tile(item: item, rect: tile, header: header, inner: inner, label: label, title: name, look: look)
        }
    }

    @MainActor
    private static func lineHeight(of font: NSFont) -> Double {
        Double(ceil(font.ascender - font.descender + font.leading))
    }

    /// How wide `text` draws, with a point to spare for SwiftUI's rounding.
    @MainActor
    private static func width(_ text: String, _ font: NSFont) -> Double {
        Double(ceil((text as NSString).size(withAttributes: [.font: font]).width)) + 1
    }

    /// What of a plain tile's name and caption fit in `room`, and the name
    /// to draw. A file or package may drop its extension to fit; a folder's
    /// name stays whole, since a dot in it starts no extension.
    @MainActor
    private static func label(_ item: DiskItem, name: String, caption: String, room: CGSize, inner: Bool) -> (TreemapLabel.Fit, String) {
        let fonts = inner ? (name: innerNameFont, size: innerSizeFont) : (name: nameFont, size: sizeFont)
        let line = inner ? innerLineHeight : lineHeight
        // Too small for any name: skip the measuring.
        guard room.width >= 14, Double(room.height) >= line else { return (.none, name) }
        let short = item.kind == .file || item.kind == .package ? TreemapLabel.shortName(name) : nil
        let fit = TreemapLabel.tile(name: width(name, fonts.name), shortName: short.map { width($0, fonts.name) },
                                    size: width(caption, fonts.size), lineHeight: line, room: room)
        return (fit.fit, fit.short ? short ?? name : name)
    }

    @MainActor
    private static func inner(of folder: DiskItem, in usage: DiskUsage, room: CGRect, changes: TreemapChanges?,
                              threshold: UInt64) -> [Inner] {
        let children = usage.children(of: folder).filter { $0.allocatedSize > 0 }
        var shown: [DiskItem?] = Array(children.prefix(innerLimit))
        let rest = children.dropFirst(innerLimit).reduce(0) { $0 + Double($1.allocatedSize) }
        var values = shown.map { Double($0?.allocatedSize ?? 0) }
        if rest > 0 {
            shown.append(nil)
            values.append(rest)
        }
        return zip(shown, Treemap.squarify(values, in: room)).compactMap { item, rect in
            guard rect.width >= 2, rect.height >= 2 else { return nil }
            let rect = rect.width > 3 && rect.height > 3 ? rect.insetBy(dx: 0.5, dy: 0.5) : rect
            guard let item else { return Inner(item: nil, rect: rect, look: .rest, label: .none, title: "") }
            let look = TileLook(item, changes: changes, in: usage, threshold: threshold)
            let name = StorageStyle.name(item)
            let labelRoom = CGSize(width: rect.width - 2 * innerInset.width, height: rect.height - 2 * innerInset.height)
            let (label, title) = Self.label(item, name: name, caption: look.caption, room: labelRoom, inner: true)
            return Inner(item: item, rect: rect, look: look, label: label, title: title)
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

extension TreemapLayout.Tile {
    /// The item drawn inside this folder's tile at `point`.
    func inner(at point: CGPoint) -> TreemapLayout.Inner? {
        inner.first { $0.rect.contains(point) }
    }

    func inner(id: Int?) -> TreemapLayout.Inner? {
        guard let id else { return nil }
        return inner.first { $0.item?.id == id }
    }
}

/// Keeps the last layout, so the tiles are worked out once per scan,
/// folder, size and comparison however often the views around them redraw.
@MainActor
private final class TreemapCache {
    private var last: TreemapLayout?

    func layout(usage: DiskUsage, folder: DiskItem, size: CGSize, changes: TreemapChanges?) -> TreemapLayout {
        let key = TreemapLayout.Key(scan: usage.finishedAt, folder: folder.id, size: size, since: changes?.since)
        if let last, last.key == key { return last }
        let layout = TreemapLayout(usage: usage, folder: folder, size: size, changes: changes)
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
/// on disk and coloured by category (or, in Changes mode, by how it changed
/// since an earlier scan), with each large folder showing its own contents
/// inside. Click a folder to open it.
struct StorageTreemap: View {
    let usage: DiskUsage
    let folder: DiskItem
    let hover: StorageHover
    var changes: TreemapChanges?
    /// In Changes mode, fades what didn't change ("Changes only").
    var quietsUnchanged = false
    var open: (DiskItem) -> Void
    var menu: (DiskItem) -> StorageItemMenu

    @State private var cache = TreemapCache()

    var body: some View {
        GeometryReader { proxy in
            let layout = cache.layout(usage: usage, folder: folder, size: proxy.size, changes: changes)
            ZStack(alignment: .topLeading) {
                TreemapTiles(layout: layout, quiet: quietsUnchanged && changes != nil).equatable()
                TreemapPointer(layout: layout, folder: folder, hover: hover, open: open, menu: menu)
            }
        }
    }
}

/// The tiles and their labels. Equatable on the layout, so hovering (which
/// only the pointer layer reads) never redraws them.
private struct TreemapTiles: View, Equatable {
    /// A faded tile, for what didn't change while "Changes only" is on.
    static let quietFill = StorageChangeStyle.sameFill.opacity(0.16)
    static let quietEdge = StorageChangeStyle.sameFill.opacity(0.32)

    let layout: TreemapLayout
    /// Fade the tiles whose look `isUnchanged`.
    let quiet: Bool

    var body: some View {
        Canvas { context, _ in
            for tile in layout.tiles { draw(tile, in: &context) }
        }
        // An explicit stack: the overlay's own one centres its views on each
        // other, which would throw the offsets out.
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(layout.tiles) { tile in
                    TileLabel(tile: tile, isQuiet: quiet && tile.look.isUnchanged)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(layout.since == nil ? "Treemap" : "Treemap of changes")
    }

    private func draw(_ tile: TreemapLayout.Tile, in context: inout GraphicsContext) {
        let color = tile.look.color
        let radius = min(4, tile.rect.width / 4, tile.rect.height / 4)
        let shape = RoundedRectangle(cornerRadius: radius).path(in: tile.rect)
        if quiet, tile.look.isUnchanged {
            // Still there to hover and open, but out of the way.
            context.fill(shape, with: .color(tile.header == nil ? Self.quietFill : Self.quietFill.opacity(0.5)))
            context.stroke(shape, with: .color(Self.quietEdge), lineWidth: 1)
            for inner in tile.inner { draw(inner, in: &context) }
            return
        }
        if tile.header != nil {
            // A folder showing its contents: a tinted frame with the name on
            // top, then a tile for each thing inside.
            context.fill(shape, with: .linearGradient(Gradient(colors: [color.opacity(0.38), color.opacity(0.20)]),
                                                      startPoint: tile.rect.origin, endPoint: CGPoint(x: tile.rect.minX, y: tile.rect.maxY)))
            context.stroke(shape, with: .color(color.opacity(0.75)), lineWidth: 1)
            for inner in tile.inner { draw(inner, in: &context) }
        } else {
            context.fill(shape, with: .linearGradient(Gradient(colors: [color, color.opacity(0.74)]),
                                                      startPoint: tile.rect.origin, endPoint: CGPoint(x: tile.rect.minX, y: tile.rect.maxY)))
            if tile.look.isHatched { hatch(tile.rect, in: context) }
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

    private func draw(_ inner: TreemapLayout.Inner, in context: inout GraphicsContext) {
        let color = inner.look.color
        let isQuiet = quiet && inner.look.isUnchanged
        let path = RoundedRectangle(cornerRadius: min(2, inner.rect.width / 4, inner.rect.height / 4)).path(in: inner.rect)
        if isQuiet {
            context.fill(path, with: .color(Self.quietFill))
        } else {
            context.fill(path, with: .linearGradient(Gradient(colors: [color.opacity(0.95), color.opacity(0.72)]),
                                                     startPoint: inner.rect.origin, endPoint: CGPoint(x: inner.rect.minX, y: inner.rect.maxY)))
        }
        if inner.look.isHatched { hatch(inner.rect, in: context) }
        guard inner.label != .none else { return }
        // Drawn here rather than as views: a folder tile can hold dozens.
        var lines = [Text(inner.title).font(Font(TreemapLayout.innerNameFont))]
        if inner.label == .nameAndSize { lines.append(Text(inner.look.caption).font(Font(TreemapLayout.innerSizeFont))) }
        for (index, line) in lines.enumerated() {
            let point = CGPoint(x: inner.rect.minX + TreemapLayout.innerInset.width,
                                y: inner.rect.minY + TreemapLayout.innerInset.height + CGFloat(index) * TreemapLayout.innerLineHeight)
            if isQuiet {
                context.draw(line.foregroundStyle(.secondaryText), at: point, anchor: .topLeading)
                continue
            }
            context.draw(line.foregroundStyle(Color.black.opacity(0.45)), at: CGPoint(x: point.x, y: point.y + 0.5), anchor: .topLeading)
            context.draw(line.foregroundStyle(Color.white.opacity(index == 0 ? 1 : 0.9)), at: point, anchor: .topLeading)
        }
    }

    /// Light diagonal stripes over a tile whose change can't be told.
    private func hatch(_ rect: CGRect, in context: GraphicsContext) {
        var context = context
        context.clip(to: Path(rect))
        var stripes = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: CGPoint(x: x, y: rect.maxY))
            stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        context.stroke(stripes, with: .color(.white.opacity(0.28)), lineWidth: 1.5)
    }
}

/// Name and size (or change) on tiles with room for them. The layout
/// measured what fits, so a label shows whole or not at all; hovering names
/// the rest.
private struct TileLabel: View {
    let tile: TreemapLayout.Tile
    /// On a faded tile: grey, without the shadow white text needs.
    var isQuiet = false

    var body: some View {
        if tile.label != .none {
            let inset = TreemapLayout.labelInset
            if let header = tile.header {
                HStack(spacing: TreemapLayout.headerSpacing) {
                    name.foregroundStyle(isQuiet ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
                    if tile.label == .nameAndSize { caption.foregroundStyle(.secondaryText) }
                }
                .padding(.horizontal, inset.width)
                .frame(width: header.width, height: header.height, alignment: .leading)
                .clipped()
                .offset(x: header.minX, y: header.minY)
                .allowsHitTesting(false)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    name
                    if tile.label == .nameAndSize { caption.opacity(0.88) }
                }
                .foregroundStyle(isQuiet ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.white))
                .shadow(color: .black.opacity(isQuiet ? 0 : 0.45), radius: 0, x: 0, y: 0.5)
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
        Text(tile.title).font(Font(TreemapLayout.nameFont)).fixedSize()
    }

    private var caption: some View {
        Text(tile.look.caption).font(Font(TreemapLayout.sizeFont)).fixedSize()
    }
}

/// Reads the pointer: highlights the tile under it (and the item inside a
/// folder's tile) and names it in a tag, opens folders on click, and offers
/// the item's actions on right-click. It alone redraws as the pointer
/// moves, and only when the item under it changes. It also outlines the
/// tile holding the item picked in a list.
private struct TreemapPointer: View {
    let layout: TreemapLayout
    let folder: DiskItem
    let hover: StorageHover
    var open: (DiskItem) -> Void
    var menu: (DiskItem) -> StorageItemMenu
    /// Where the pointer rested when these tiles appeared under it. Until it
    /// moves, nothing is hovered, so a map that opens (or changes) under a
    /// still pointer doesn't start with a tag over whatever happens to be there.
    @State private var restingAt: CGPoint?

    var body: some View {
        let hovered = layout.tile(id: hover.item)
        let inner = hovered?.inner(id: hover.inner)
        // The tile on the way to the picked item, and the item inside it on the way too.
        let marked = hover.marked.isEmpty ? nil : layout.tiles.first { hover.marked.contains($0.id) }
        let markedInner = marked?.inner.first { $0.item.map { hover.marked.contains($0.id) } ?? false }
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let marked { MarkHighlight(rect: marked.rect, inner: markedInner?.rect) }
                    if let hovered { Highlight(rect: hovered.rect, color: hovered.look.color, strength: 1) }
                    if let inner { InnerHighlight(rect: inner.rect) }
                }
            }
            .overlay {
                // Only for hovers here: the list beside it shows its own row.
                if let hovered, hover.source == .treemap {
                    TagPlacement(tile: inner?.rect ?? hovered.rect) {
                        if let inner, let item = inner.item {
                            HoverTag(item: item, look: inner.look, total: hovered.item.allocatedSize, within: hovered.item.name, since: layout.since)
                        } else {
                            HoverTag(item: hovered.item, look: hovered.look, total: folder.allocatedSize, within: nil, since: layout.since)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    if let restingAt {
                        guard NSEvent.mouseLocation != restingAt else { return }
                        self.restingAt = nil
                    }
                    let tile = layout.tile(at: point)
                    hover.enter(tile?.item.id, inner: tile?.inner(at: point)?.item?.id, from: .treemap)
                case .ended:
                    // Also sent when the tiles are resized under a still pointer,
                    // just before it's entered again where it rests.
                    restingAt = NSEvent.mouseLocation
                    hover.enter(nil, from: .treemap)
                }
            }
            .onAppear { restingAt = NSEvent.mouseLocation }
            .onChange(of: layout.key) {
                // The tile that was hovered may be somewhere else now.
                restingAt = NSEvent.mouseLocation
                if hover.source == .treemap { hover.enter(nil, from: .treemap) }
            }
            .onTapGesture { point in
                if let tile = layout.tile(at: point), tile.item.isFolder { open(tile.item) }
            }
            .contextMenu {
                if let item = inner?.item ?? hovered?.item, item.kind != .smallerItems { menu(item) }
            }
    }
}

/// A bright outline with a soft halo, faked with a wide translucent stroke
/// rather than a blur.
private struct Highlight: View {
    let rect: CGRect
    let color: Color
    let strength: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.55 * strength), lineWidth: 7)
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.16 * strength))
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.95 * strength), lineWidth: 2)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }
}

/// The tile holding the item picked in a list, in the accent colour like
/// the picked row: a halo round the tile and, when the item is drawn inside
/// it (or inside something drawn there), a ring round that too.
private struct MarkHighlight: View {
    let rect: CGRect
    let inner: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 6)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white, lineWidth: 1)
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            if let inner {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.14)))
                    .frame(width: inner.width, height: inner.height)
                    .offset(x: inner.minX, y: inner.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A thin outline round the item under the pointer inside a folder's tile.
private struct InnerHighlight: View {
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.14)))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

/// The hovered tile's full name, size and share of its folder, whether or
/// not its label fits on the tile, and in Changes mode how it changed.
private struct HoverTag: View {
    let item: DiskItem
    let look: TileLook
    let total: UInt64
    /// For an item inside a folder's tile: that folder.
    let within: String?
    let since: Date?

    var body: some View {
        let share = Double(item.allocatedSize) / Double(max(total, 1))
        var detail = "\(Format.bytes(item.allocatedSize)) · \(Format.percent(share, digits: share < 0.1 ? 1 : 0))"
        if let within { detail += " of \(within)" }
        if item.kind != .file, item.kind != .smallerItems { detail += " · \(item.itemCount.formatted()) items" }
        let shape = RoundedRectangle(cornerRadius: 7)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(look.color).frame(width: 8, height: 8)
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
                if let since, let change = look.change, let direction = look.direction {
                    Text(StorageChangeStyle.summary(change, direction, since: since))
                        .font(.metadata)
                        .foregroundStyle(StorageChangeStyle.textStyle(direction))
                        .monospacedDigit()
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

/// What's under the pointer, beside the breadcrumb; in Changes mode, the
/// colours' key while nothing is.
struct TreemapCaption: View {
    let usage: DiskUsage
    let folder: DiskItem
    let hover: StorageHover
    var changes: TreemapChanges?
    var quietsUnchanged = false

    var body: some View {
        let items = usage.children(of: folder)
        if let id = hover.item, let item = items.first(where: { $0.id == id }) {
            let share = Double(item.allocatedSize) / Double(max(folder.allocatedSize, 1))
            let look = TileLook(item, changes: changes, in: usage, threshold: StorageChangeStyle.threshold(for: folder.allocatedSize))
            HStack(spacing: 6) {
                Circle().fill(look.color).frame(width: 8, height: 8)
                Text(StorageStyle.name(item)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Group {
                    if let direction = look.direction {
                        Text(look.caption).foregroundStyle(StorageChangeStyle.textStyle(direction))
                    } else {
                        Text("\(Format.bytes(item.allocatedSize)) · \(Format.percent(share, digits: share < 0.1 ? 1 : 0))")
                            .foregroundStyle(.secondaryText)
                    }
                }
                .monospacedDigit()
                .fixedSize()
            }
            .font(.metadata)
        } else if changes != nil {
            ChangeLegend(quietsUnchanged: quietsUnchanged)
        } else {
            Text(items.contains(where: \.isFolder) ? "Click a folder to open it" : "")
                .font(.metadata)
                .foregroundStyle(.secondaryText)
        }
    }
}

/// What the Changes colours mean.
private struct ChangeLegend: View {
    /// "No change" is faded on the map, so in the key too.
    var quietsUnchanged = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            entries([.grew, .shrank, .same, .unclear])
            entries([.grew, .shrank, .same])
            entries([.grew, .shrank])
        }
        .font(.metadata)
        .foregroundStyle(.secondaryText)
    }

    private func entries(_ directions: [DiskSizeChange.Direction]) -> some View {
        HStack(spacing: 10) {
            ForEach(directions, id: \.self) { direction in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(quietsUnchanged && direction == .same ? AnyShapeStyle(StorageChangeStyle.sameFill.opacity(0.22))
                            : AnyShapeStyle(StorageChangeStyle.fill(direction)))
                        .overlay {
                            if direction == .unclear {
                                Image(systemName: "line.diagonal").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .frame(width: 10, height: 10)
                    Text(StorageChangeStyle.title(direction))
                }
                .fixedSize()
            }
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
