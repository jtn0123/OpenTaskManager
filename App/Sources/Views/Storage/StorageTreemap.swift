import OTMKit
import SwiftUI

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
        /// A plain tile's label ink in each appearance.
        let ink: TileInk

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
        let ink: TileInk
    }

    static let headerHeight: CGFloat = 20
    /// Grandchildren drawn per folder tile; the rest fill one grey tile.
    static let innerLimit = 60

    /// The labels' fonts, which `TileLabel` draws them in too. Names are
    /// bold, so they lead over the size or change under them.
    @MainActor static let nameFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    @MainActor static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    /// A point smaller inside a folder's tile, so grandchildren read as inside it.
    @MainActor static let innerNameFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    @MainActor static let innerSizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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
                let (label, title) = Self.label(item, name: name, caption: look.tileCaption, room: room, inner: false)
                let ink = label == .none ? .dark : TreemapInk.plain(look, height: tile.height, label: Self.labelSpan(label, inner: false))
                return Tile(item: item, rect: tile, header: nil, inner: [], label: label, title: title, look: look, ink: ink)
            }
            let header = CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: Self.headerHeight)
            let room = CGRect(x: tile.minX + 3, y: tile.minY + Self.headerHeight, width: tile.width - 6, height: tile.height - Self.headerHeight - 3)
            let label = TreemapLabel.header(name: Self.width(name, Self.nameFont), size: Self.width(look.tileCaption, Self.sizeFont),
                                            spacing: Double(Self.headerSpacing), room: Double(header.width - 2 * Self.labelInset.width))
            let inner = Self.inner(of: item, in: usage, room: room, changes: changes, threshold: threshold)
            // The header's name sits on the frame's pale wash in the label colours, not on the tile colour.
            return Tile(item: item, rect: tile, header: header, inner: inner, label: label, title: name, look: look, ink: .dark)
        }
    }

    @MainActor
    private static func lineHeight(of font: NSFont) -> Double {
        Double(ceil(font.ascender - font.descender + font.leading))
    }

    /// How wide `text` draws, with a point to spare for SwiftUI's rounding.
    /// Nothing to draw takes no room, but never fits as a line of its own.
    @MainActor
    private static func width(_ text: String, _ font: NSFont) -> Double {
        guard !text.isEmpty else { return .infinity }
        return Double(ceil((text as NSString).size(withAttributes: [.font: font]).width)) + 1
    }

    /// Where a label of `fit` sits, from the top of its tile.
    @MainActor
    private static func labelSpan(_ fit: TreemapLabel.Fit, inner: Bool) -> ClosedRange<Double> {
        let top = Double(inner ? innerInset.height : labelInset.height)
        let lines = fit == .nameAndSize ? 2.0 : 1.0
        return top...(top + lines * (inner ? innerLineHeight : lineHeight))
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
        // The folder's frame shows through its tiles a little.
        let folderLook = TileLook(folder, changes: changes, in: usage, threshold: threshold)
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
            guard let item else { return Inner(item: nil, rect: rect, look: .rest, label: .none, title: "", ink: .dark) }
            let look = TileLook(item, changes: changes, in: usage, threshold: threshold)
            let name = StorageStyle.name(item)
            let labelRoom = CGSize(width: rect.width - 2 * innerInset.width, height: rect.height - 2 * innerInset.height)
            let (label, title) = Self.label(item, name: name, caption: look.tileCaption, room: labelRoom, inner: true)
            let ink = label == .none ? .dark
                : TreemapInk.inner(look, in: folderLook, height: rect.height, label: Self.labelSpan(label, inner: true))
            return Inner(item: item, rect: rect, look: look, label: label, title: title, ink: ink)
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
    /// Light or dark mode, which can change the labels' ink.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            let layout = cache.layout(usage: usage, folder: folder, size: proxy.size, changes: changes)
            ZStack(alignment: .topLeading) {
                TreemapTiles(layout: layout, quiet: quietsUnchanged && changes != nil, scheme: scheme).equatable()
                TreemapPointer(layout: layout, folder: folder, folderPath: usage.path(of: folder.id), hover: hover, open: open, menu: menu)
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
    let scheme: ColorScheme

    var body: some View {
        Canvas { context, _ in
            for tile in layout.tiles { draw(tile, in: &context) }
        }
        // An explicit stack: the overlay's own one centres its views on each
        // other, which would throw the offsets out.
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(layout.tiles) { tile in
                    TileLabel(tile: tile, isQuiet: quiet && tile.look.isUnchanged, scheme: scheme)
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
            context.fill(shape, with: Self.fade(color, TreemapInk.frameFade, in: tile.rect))
            context.stroke(shape, with: .color(color.opacity(0.75)), lineWidth: 1)
            for inner in tile.inner { draw(inner, in: &context) }
        } else {
            context.fill(shape, with: Self.fade(color, TreemapInk.plainFade, in: tile.rect))
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
            context.fill(path, with: Self.fade(color, TreemapInk.innerFade, in: inner.rect))
        }
        if inner.look.isHatched { hatch(inner.rect, in: context) }
        guard inner.label != .none else { return }
        // Drawn here rather than as views: a folder tile can hold dozens.
        let lightInk = !isQuiet && inner.ink(scheme) == .light
        var lines = [(Text(inner.title).font(Font(TreemapLayout.innerNameFont)), inner.ink.name(scheme))]
        if inner.label == .nameAndSize {
            lines.append((Text(inner.look.tileCaption).font(Font(TreemapLayout.innerSizeFont)), inner.ink.caption(scheme)))
        }
        for (index, (line, ink)) in lines.enumerated() {
            let point = CGPoint(x: inner.rect.minX + TreemapLayout.innerInset.width,
                                y: inner.rect.minY + TreemapLayout.innerInset.height + CGFloat(index) * TreemapLayout.innerLineHeight)
            if isQuiet {
                context.draw(line.foregroundStyle(.secondaryText), at: point, anchor: .topLeading)
                continue
            }
            // White text keeps a hairline shadow; dark text needs none.
            if lightInk {
                context.draw(line.foregroundStyle(Color.black.opacity(0.4)), at: CGPoint(x: point.x, y: point.y + 0.5), anchor: .topLeading)
            }
            context.draw(line.foregroundStyle(ink), at: point, anchor: .topLeading)
        }
    }

    /// `color` fading down `rect` as `fade` says.
    private static func fade(_ color: Color, _ fade: TreemapInk.Fade, in rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [color.opacity(fade.top), color.opacity(fade.bottom)]),
                        startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY))
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
        context.stroke(stripes, with: .color(.white.opacity(TreemapInk.hatchOpacity)), lineWidth: 1.5)
    }
}

/// Name and size (or change) on tiles with room for them. The layout
/// measured what fits, so a label shows whole or not at all; hovering names
/// the rest. The ink, dark or white, is the one that reads best on the
/// tile's colour (`TileInk`).
private struct TileLabel: View {
    let tile: TreemapLayout.Tile
    /// On a faded tile: grey, without the shadow white text needs.
    var isQuiet = false
    var scheme: ColorScheme

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
                let lightInk = !isQuiet && tile.ink(scheme) == .light
                VStack(alignment: .leading, spacing: 0) {
                    name.foregroundStyle(isQuiet ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(tile.ink.name(scheme)))
                    if tile.label == .nameAndSize {
                        caption.foregroundStyle(isQuiet ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(tile.ink.caption(scheme)))
                    }
                }
                // White text keeps a hairline shadow; dark text needs none.
                .shadow(color: .black.opacity(lightInk ? 0.4 : 0), radius: 0, x: 0, y: 0.5)
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
        Text(tile.look.tileCaption).font(Font(TreemapLayout.sizeFont)).fixedSize()
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
    /// The open folder's path, which the picked item's trail starts under.
    let folderPath: String
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
        // The deepest of those is the picked item itself, or only what holds
        // it: too small or too deep to draw here, or kept only in a folder's
        // "smaller items".
        let drawn = markedInner?.item?.id ?? marked?.id
        let isExact = hover.pick?.isKept == true && drawn == hover.marked.last
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let marked { MarkHighlight(rect: marked.rect, inner: markedInner?.rect, isExact: isExact) }
                    if let hovered { Highlight(rect: hovered.rect, color: hovered.look.color, strength: 1) }
                    if let inner { InnerHighlight(rect: inner.rect) }
                }
            }
            .overlay {
                // Only for hovers here: the list beside it shows its own row.
                if let hovered, hover.source == .treemap {
                    TagPlacement(tile: inner?.rect ?? hovered.rect, heading: hovered.header) {
                        if let inner, let item = inner.item {
                            HoverTag(item: item, look: inner.look, total: hovered.item.allocatedSize, within: hovered.item.name, since: layout.since)
                        } else {
                            HoverTag(item: hovered.item, look: hovered.look, total: folder.allocatedSize, within: nil, since: layout.since)
                        }
                    }
                    .allowsHitTesting(false)
                } else if let marked, let pick = hover.pick, pick.change == nil {
                    // Names what the outline stands for, until the pointer explores the map,
                    // clear of the name of the folder holding it. A change has the bar
                    // above the map (`PickedChangeBar`) instead, which hides no tiles.
                    TagPlacement(tile: markedInner?.rect ?? marked.rect, heading: marked.header) {
                        PickTag(pick: pick, isExact: isExact, trail: Format.trail(pick.path, under: folderPath))
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
            // Once per pick, folder or size: what the bar above says it outlined.
            .onChange(of: OutlinedMark(folder: folder.id, chain: hover.marked, drawn: drawn), initial: true) { _, mark in
                hover.outline(mark)
            }
            .onDisappear { hover.outline(nil) }
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

/// Where the item picked in a list is, in the accent colour like the picked
/// row: a halo and ring round the deepest thing drawn on the way to it (a
/// tile, or an item drawn inside a folder's tile, whose tile then gets a
/// thin line). The ring is solid round the item itself, and dashed round
/// what only holds it.
private struct MarkHighlight: View {
    let rect: CGRect
    let inner: CGRect?
    let isExact: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let inner {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                ring(inner, radius: 2)
            } else {
                ring(rect, radius: 4)
            }
        }
        .allowsHitTesting(false)
    }

    private func ring(_ rect: CGRect, radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius + 2).stroke(Color.accentColor.opacity(0.45), lineWidth: 6)
            RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(isExact ? 0.14 : 0))
            RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white, lineWidth: 1).padding(2)
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: isExact ? [] : [5, 3]))
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// Names what the outline stands for: the file picked in Largest Files
/// itself ("bundle.bin"), or, when that's too small or too deep to draw
/// here, the region holding it ("Contains bundle.bin"), with its size, and
/// where it is below the open folder in the words the list uses ("Projects ›
/// webapp › build").
private struct PickTag: View {
    let pick: StoragePick
    let isExact: Bool
    let trail: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        let title = isExact ? pick.name : "Contains \(pick.name)"
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pick.figure)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                    .fixedSize()
            }
            if !trail.isEmpty, trail != pick.name {
                Text(trail)
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.background, in: shape)
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
        // Drawn once per pick, never per tick.
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
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
                    .font(.explanation)
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                if let since, let change = look.change, let direction = look.direction {
                    Text(StorageChangeStyle.summary(change, direction, since: since))
                        .font(.explanation)
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
    /// The name strip of the folder tile holding `tile`, kept in view.
    var heading: CGRect?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tag = subviews.first else { return }
        let size = tag.sizeThatFits(ProposedViewSize(width: min(Self.maximumWidth, bounds.width), height: nil))
        let origin = TreemapLabel.tagOrigin(size: size, tile: tile, bounds: bounds.size, heading: heading)
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
            .font(.explanation)
        } else if changes != nil {
            ChangeLegend(quietsUnchanged: quietsUnchanged)
        } else {
            Text(items.contains(where: \.isFolder) ? "Click a folder to open it" : "")
                .font(.explanation)
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
        .font(.explanation)
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
