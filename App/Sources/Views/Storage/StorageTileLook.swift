import AppKit
import OTMKit
import SwiftUI

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
    /// The second line on the tile itself. A tile that didn't change shows
    /// just its name: its grey and the key under the map say "No change",
    /// which otherwise filled most tiles with the same words.
    var tileCaption: String { direction == .same ? "" : caption }

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

/// A tile label's ink, dark or light, in each appearance.
struct TileInk: Equatable {
    static let dark = TileInk(aqua: .dark, darkAqua: .dark)

    let aqua: ColorContrast.Ink
    let darkAqua: ColorContrast.Ink

    func callAsFunction(_ scheme: ColorScheme) -> ColorContrast.Ink {
        scheme == .dark ? darkAqua : aqua
    }

    /// The name's colour: near-black, or white.
    func name(_ scheme: ColorScheme) -> Color {
        self(scheme) == .dark ? Color.black.opacity(0.88) : .white
    }

    /// The size or change under the name: a step back from it, and still
    /// 4.5:1 on the darkest tile colour that takes dark ink (the purple).
    func caption(_ scheme: ColorScheme) -> Color {
        self(scheme) == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.9)
    }
}

/// How the tiles' fills fade from top to bottom, and the ink their labels
/// take over that: dark or light, whichever contrasts more with the colours
/// under the label (`ColorContrast.ink(over:)`) in each appearance. Worked
/// out once per layout, with the tiles.
enum TreemapInk {
    typealias RGB = ColorContrast.RGB

    struct Fade {
        let top: Double
        let bottom: Double

        func opacity(at fraction: Double) -> Double {
            top + (bottom - top) * min(max(fraction, 0), 1)
        }
    }

    /// A plain tile: its colour, fading a little towards the bottom.
    static let plainFade = Fade(top: 1, bottom: 0.74)
    /// A folder showing its contents: a tinted frame.
    static let frameFade = Fade(top: 0.38, bottom: 0.20)
    /// The tiles inside a folder's frame.
    static let innerFade = Fade(top: 0.95, bottom: 0.72)
    /// The stripes over a tile whose change can't be told.
    static let hatchOpacity = 0.28

    /// Roughly what shows through a faded fill: the window under the
    /// treemap card's faint grey wash, in light and in dark mode.
    private static let card = (aqua: RGB(red: 0.95, green: 0.95, blue: 0.96), darkAqua: RGB(red: 0.16, green: 0.16, blue: 0.17))

    /// The ink for a label over the stretch `label` (points from the top) of
    /// a plain tile `height` tall.
    @MainActor
    static func plain(_ look: TileLook, height: CGFloat, label: ClosedRange<Double>) -> TileInk {
        let color = rgb(look.color)
        let span = fractions(label, of: height)
        return TileInk(aqua: ink(color, fade: plainFade, at: span, hatched: look.isHatched, over: card.aqua),
                       darkAqua: ink(color, fade: plainFade, at: span, hatched: look.isHatched, over: card.darkAqua))
    }

    /// The same for a tile inside a folder's frame, which shows through it a little.
    @MainActor
    static func inner(_ look: TileLook, in folder: TileLook, height: CGFloat, label: ClosedRange<Double>) -> TileInk {
        let color = rgb(look.color)
        let frame = rgb(folder.color)
        let span = fractions(label, of: height)
        let wash = (frameFade.top + frameFade.bottom) / 2
        func under(_ card: RGB) -> RGB { ColorContrast.composite(frame, opacity: wash, over: card) }
        return TileInk(aqua: ink(color, fade: innerFade, at: span, hatched: look.isHatched, over: under(card.aqua)),
                       darkAqua: ink(color, fade: innerFade, at: span, hatched: look.isHatched, over: under(card.darkAqua)))
    }

    /// The label's top and bottom, as fractions of the tile's height.
    private static func fractions(_ label: ClosedRange<Double>, of height: CGFloat) -> [Double] {
        guard height > 0 else { return [0] }
        return [label.lowerBound / Double(height), label.upperBound / Double(height)]
    }

    /// The ink for `color` fading by `fade`, over `card`, at those fractions
    /// down the tile, and over the hatch's stripes too when it has them.
    private static func ink(_ color: RGB, fade: Fade, at fractions: [Double], hatched: Bool, over card: RGB) -> ColorContrast.Ink {
        let backgrounds = fractions.map { ColorContrast.composite(color, opacity: fade.opacity(at: $0), over: card) }
        let stripes = hatched ? backgrounds.map { ColorContrast.composite(.white, opacity: hatchOpacity, over: $0) } : []
        return ColorContrast.ink(over: backgrounds + stripes)
    }

    @MainActor
    private static func rgb(_ color: Color) -> RGB {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return RGB(red: 0.5, green: 0.5, blue: 0.5) }
        return RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }
}
