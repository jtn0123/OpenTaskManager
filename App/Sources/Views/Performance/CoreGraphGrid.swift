import AppKit
import OTMKit
import SwiftUI

/// A graph for every logical CPU, filling the CPU page's main graph area:
/// tiles laid out by `CoreAreaGrid` (18 CPUs in a wide pane are 6 by 3),
/// Performance cores first, each with its busy time filled in its core
/// type's colour and its kernel time as a line, on one shared scale. The
/// tiles are the Overview's Cores tiles grown to fill the area, in the same
/// `CoreTileLook`: the CPU's number and load over the plot, in a wash and
/// border that firm up with the load.
///
/// One AppKit view hosting a `StreamGraphView` per CPU, so every tile
/// scrolls as the page's other graphs do while SwiftUI updates one view a
/// tick; the tiles' washes, grids, borders and labels are layers, built when
/// the size or the CPUs change, and a tick sets only the figures that changed.
struct CoreGraphGrid: NSViewRepresentable {
    /// One logical CPU's tile.
    struct Tile {
        var cpu: Int
        /// The core type's letter, "P" or "E"; empty with one kind of core.
        var kind: String
        /// "Performance core", for the tooltip.
        var kindName: String
        var color: Color
        /// Busy share over time, 0 to 1.
        var busy: [Double]
        /// The part of it spent in the kernel.
        var kernel: [Double]
    }

    var tiles: [Tile]
    /// The tiles' runs by core type, in order (`CoreAreaGrid.best`).
    var groups: [Int]
    var top: Double
    /// The height to fill; more when tiles would otherwise be too short to read.
    var height: CGFloat
    var kernelColor: Color

    func makeNSView(context: Context) -> CoreGraphGridView {
        CoreGraphGridView()
    }

    func updateNSView(_ view: CoreGraphGridView, context: Context) {
        let capacity = context.environment.graphWindow
        let readings = CoreGraphGridView.Readings(
            tiles: tiles.map {
                CoreGraphGridView.Tile(cpu: $0.cpu, kind: $0.kind, kindName: $0.kindName, color: NSColor($0.color),
                                       busy: Array($0.busy.suffix(capacity + 1)), kernel: Array($0.kernel.suffix(capacity + 1)))
            },
            groups: groups, top: top, kernelColor: NSColor(kernelColor), colors: GraphColors.shared.revision, capacity: max(capacity, 2)
        )
        view.update(readings, interval: context.environment.sampleInterval, streams: context.environment.streamsGraphs)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CoreGraphGridView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        let layout = CoreAreaGrid.best(count: tiles.count, width: Double(width), height: Double(height),
                                       spacing: Double(CoreGraphGridView.spacing), groups: groups)
        let needed = layout.height(atLeast: Double(height), minimumTile: Double(CoreGraphGridView.minimumTile),
                                   spacing: Double(CoreGraphGridView.spacing))
        return CGSize(width: width, height: CGFloat(needed))
    }
}

final class CoreGraphGridView: NSView {
    static let spacing: CGFloat = 6
    /// A tile's labels and a plot still worth reading.
    static let minimumTile: CGFloat = 64
    private static let radius = CoreTileLook.cornerRadius
    private static let header = CoreTileLook.labelHeight
    private static let kindFont = NSFont.systemFont(ofSize: CoreTileLook.labelSize, weight: .bold)
    /// The plot's own line, a little firmer than the Overview's small tiles'
    /// at this size.
    private static let lineWidth = CoreTileLook.lineWidth + 0.2

    struct Tile {
        var cpu: Int
        var kind: String
        var kindName: String
        var color: NSColor
        var busy: [Double]
        var kernel: [Double]
    }

    /// What a tick draws: every tile's readings and the scale and window they share.
    struct Readings {
        var tiles: [Tile]
        var groups: [Int]
        var top: Double
        var kernelColor: NSColor
        /// The graph colours' revision, which restyles the tiles when it changes.
        var colors: Int
        var capacity: Int
    }

    /// The layers drawn around one tile's graph, and the graph.
    @MainActor
    private final class Chrome {
        let wash = CAGradientLayer()
        let minor = CAShapeLayer()
        let major = CAShapeLayer()
        let border = CALayer()
        let name = CATextLayer()
        let value = CATextLayer()
        let graph = StreamGraphView()
        /// The figure shown and whether it was in the core type's colour.
        var shownValue = ""
        var shownLoad = -1.0

        init() {
            wash.cornerRadius = CoreGraphGridView.radius
            wash.masksToBounds = true
            wash.startPoint = CGPoint(x: 0.5, y: 1)
            wash.endPoint = CGPoint(x: 0.5, y: 0)
            for shape in [minor, major] {
                shape.fillColor = nil
                shape.lineWidth = 0.5
                wash.addSublayer(shape)
            }
            border.cornerRadius = CoreGraphGridView.radius
            border.borderWidth = 1
            for label in [name, value] {
                label.truncationMode = .end
                label.isWrapped = false
            }
            name.alignmentMode = .left
            value.alignmentMode = .right
            // Rounds the plot's lower corners into the tile's.
            graph.wantsLayer = true
            graph.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
    }

    /// Hosts the washes and grids, under the graphs.
    private let backdrop = LayerHostView()
    /// Hosts the borders and labels, over the graphs.
    private let overlay = LayerHostView()
    private var chrome: [Chrome] = []
    private var tiles: [Tile] = []
    private var groups: [Int] = []
    /// The CPUs and colours the chrome was styled for.
    private var styledFor: [String] = []
    private var laidOutSize: CGSize = .zero
    private var kernelColor = NSColor.systemPink

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(backdrop)
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ readings: Readings, interval: TimeInterval, streams: Bool) {
        let tiles = readings.tiles
        groups = readings.groups
        kernelColor = readings.kernelColor
        syncChrome(count: tiles.count)
        self.tiles = tiles
        let identity = tiles.map { "\($0.cpu)\($0.kind)" } + [String(readings.colors)]
        if identity != styledFor {
            styledFor = identity
            laidOutSize = .zero
            needsLayout = true
            applyStyle()
            for item in chrome {
                item.shownValue = ""
                item.shownLoad = -1
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (item, tile) in zip(chrome, tiles) {
            let configuration = StreamGraphView.Configuration(
                lines: [
                    StreamGraphView.Line(values: tile.busy, color: tile.color, fill: true, dashed: false),
                    StreamGraphView.Line(values: tile.kernel, color: kernelColor, fill: false, dashed: false),
                ],
                maxValue: readings.top, capacity: readings.capacity, showsGrid: false, lineWidth: Self.lineWidth, glows: true,
                stacked: false, minimumCeiling: 0, maximumCeiling: .infinity, axis: nil, axisUnits: .plain, axisNote: nil,
                cornerRadius: Self.radius - 1
            )
            item.graph.update(configuration, interval: interval, streams: streams)
            setFigure(item, tile: tile)
        }
        CATransaction.commit()
        updateLoad()
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, !chrome.isEmpty else { return }
        laidOutSize = bounds.size
        backdrop.frame = bounds
        overlay.frame = bounds
        let layout = CoreAreaGrid.best(count: chrome.count, width: bounds.width, height: bounds.height,
                                       spacing: Self.spacing, groups: groups)
        let size = layout.tileSize(width: bounds.width, height: bounds.height, spacing: Self.spacing)
        let tile = CGSize(width: floor(size.width), height: floor(size.height))
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.removeAllToolTips()
        for (index, item) in chrome.enumerated() {
            let column = index % layout.columns
            let row = index / layout.columns
            // Rows from the top; the view isn't flipped, so y counts up from the foot.
            let top = (CGFloat(row) * (CGFloat(size.height) + Self.spacing)).rounded()
            let rect = CGRect(x: (CGFloat(column) * (CGFloat(size.width) + Self.spacing)).rounded(),
                              y: bounds.height - top - tile.height,
                              width: tile.width, height: tile.height)
            place(item, in: rect, scale: scale)
            if tiles.indices.contains(index) {
                let tile = tiles[index]
                let kind = tile.kindName.isEmpty ? "" : " (\(tile.kindName))"
                overlay.addToolTip(rect, owner: "CPU \(tile.cpu)\(kind): busy time filled, kernel time as a line" as NSString,
                                   userData: nil)
            }
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
        for item in chrome {
            item.shownValue = ""
            item.shownLoad = -1
        }
        for (item, tile) in zip(chrome, tiles) { setFigure(item, tile: tile) }
        updateLoad()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        laidOutSize = .zero
        needsLayout = true
    }

    // MARK: - Tiles

    private func syncChrome(count: Int) {
        while chrome.count < count {
            let item = Chrome()
            backdrop.layer?.addSublayer(item.wash)
            overlay.layer?.addSublayer(item.border)
            overlay.layer?.addSublayer(item.name)
            overlay.layer?.addSublayer(item.value)
            addSubview(item.graph, positioned: .below, relativeTo: overlay)
            chrome.append(item)
        }
        while chrome.count > count {
            let item = chrome.removeLast()
            [item.wash, item.border, item.name, item.value].forEach { $0.removeFromSuperlayer() }
            item.graph.removeFromSuperview()
        }
    }

    /// Lays one tile out: its wash and border over the whole tile, its
    /// labels on the line at its top and its graph and grid in the rest.
    private func place(_ item: Chrome, in rect: CGRect, scale: CGFloat) {
        item.wash.frame = rect
        item.border.frame = rect
        // Nothing here is flipped: the labels are at the top of the tile, the plot under them.
        let plot = CGRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 2,
                          height: max(rect.height - Self.header - 1, 8))
        item.graph.frame = plot
        let plotInWash = CGRect(x: 1, y: 1, width: plot.width, height: plot.height)
        let paths = GridLines.paths(size: plotInWash.size, inset: 4, rows: 4)
        for (shape, path) in [(item.minor, paths.minor), (item.major, paths.major)] {
            shape.frame = plotInWash
            shape.path = path
        }
        // The text layers' line box, centred on the labels' line.
        let lineBox = ceil(CoreTileLook.labelNSFont.ascender - CoreTileLook.labelNSFont.descender + 1)
        let labelY = (rect.maxY - Self.header + (Self.header - lineBox) / 2).rounded()
        let inset = CoreTileLook.labelInset
        let valueWidth: CGFloat = 46
        item.value.frame = CGRect(x: rect.maxX - inset - valueWidth, y: labelY, width: valueWidth, height: lineBox)
        item.name.frame = CGRect(x: rect.minX + inset, y: labelY, width: max(rect.width - 2 * inset - valueWidth, 0), height: lineBox)
        item.name.contentsScale = scale
        item.value.contentsScale = scale
    }

    /// The grid's colours and the labels that change only with the CPUs, the
    /// palette or the appearance.
    private func applyStyle() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let lines = GridLines.colors(dark: dark, emphasis: GraphColors.shared.emphasis)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let secondary = NSColor(cgColor: NSColor.secondaryText.cgColor) ?? .secondaryText
            for (item, tile) in zip(chrome, tiles) {
                item.minor.strokeColor = lines.minor
                item.major.strokeColor = lines.major
                let name = NSMutableAttributedString(string: "CPU \(tile.cpu)",
                                                     attributes: [.font: CoreTileLook.labelNSFont, .foregroundColor: secondary])
                if !tile.kind.isEmpty {
                    let kindColor = NSColor(cgColor: tile.color.cgColor) ?? tile.color
                    name.append(NSAttributedString(string: "  \(tile.kind)", attributes: [.font: Self.kindFont, .foregroundColor: kindColor]))
                }
                item.name.string = name
                item.graph.setAccessibilityLabel("CPU \(tile.cpu)" + (tile.kindName.isEmpty ? "" : ", \(tile.kindName)") + ", busy share")
            }
        }
        CATransaction.commit()
    }

    /// The current load at the labels' far end, set only when its text, or
    /// whether it's in the core type's colour, changes.
    private func setFigure(_ item: Chrome, tile: Tile) {
        let load = tile.busy.last ?? 0
        let text = Format.percent(load)
        let hot = CoreTileLook.isHot(load)
        let key = hot ? text + "!" : text
        guard key != item.shownValue else { return }
        item.shownValue = key
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = hot ? tile.color : NSColor.secondaryText
            let resolved = NSColor(cgColor: color.cgColor) ?? color
            item.value.string = NSAttributedString(string: text, attributes: [.font: CoreTileLook.labelNSFont, .foregroundColor: resolved])
        }
    }

    /// Each tile's wash and border firm up with its load, easing between
    /// readings, in steps of a tenth so an idle grid doesn't restyle every tick.
    private func updateLoad() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (item, tile) in zip(chrome, tiles) {
                let step = (min(max(tile.busy.last ?? 0, 0), 1) * 10).rounded() / 10
                guard step != item.shownLoad else { continue }
                item.shownLoad = step
                let color = NSColor(cgColor: tile.color.cgColor) ?? tile.color
                item.wash.colors = [color.withAlphaComponent(CoreTileLook.washTop(step)).cgColor,
                                    color.withAlphaComponent(CoreTileLook.washFoot).cgColor]
                item.border.borderColor = color.withAlphaComponent(CoreTileLook.border(step)).cgColor
            }
        }
        CATransaction.commit()
    }
}

/// A view that only holds layers: the tiles' washes under the graphs, or
/// their borders and labels over them, with the tiles' tooltips.
private final class LayerHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
