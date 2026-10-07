import AppKit
import OTMKit
import SwiftUI

/// The Thermals page's table of sensors, clocks and power rails, grouped by
/// part of the Mac, each with its reading now and its lowest and highest
/// since the reset. AppKit rather than SwiftUI: the rows are made when the
/// set of rows changes (a search, a sensor appearing), and a tick only sets
/// the figures that changed, so it never lays out a few hundred SwiftUI
/// cells. The table sizes itself to its rows and scrolls with the page; its
/// heading sticks to the top of the page while the rows scroll under it.
struct SensorReadingTable: NSViewRepresentable {
    var rows: [SensorReading]
    var extremes: SensorExtremes
    /// nil leaves out the thermal pressure row (a search that doesn't match it).
    var thermalState: ThermalState?
    /// "Lowest and highest since 14:02:31", over the column titles.
    var since: String
    /// How the lowest and highest are kept, on hover.
    var sinceHelp: String
    var reset: @MainActor () -> Void
    /// Read where the table is made, so the page redraws it when the graph
    /// colours change.
    private let colors = GraphColors.shared.revision

    func makeNSView(context: Context) -> SensorTableView {
        SensorTableView()
    }

    func updateNSView(_ view: SensorTableView, context: Context) {
        view.update(rows: rows, extremes: extremes, thermalState: thermalState, colors: colors)
        view.showSince(since, help: sinceHelp, reset: reset)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SensorTableView, context: Context) -> CGSize? {
        let lines = SensorTableView.lines(rows: rows, pressure: thermalState != nil)
        return CGSize(width: proposal.width ?? 520, height: lines.reduce(0) { $0 + $1.height })
    }
}

extension SensorGroup {
    /// The data colour of the part, as its own page draws it.
    var color: Color {
        switch self {
        case .chip: Theme.thermal
        case .cpu: Theme.cpu
        case .gpu: Theme.gpu
        case .neuralEngine: Theme.neuralEngine
        case .memory: Theme.dram
        case .storage: Theme.sensor(.storage)
        case .battery: Theme.sensor(.battery)
        case .power: Theme.power
        case .fans: Theme.fan
        case .other: Theme.other
        }
    }
}

extension ThermalState {
    /// Green to red with the severity, deepened for text in light mode.
    var color: Color {
        switch self {
        case .nominal: Theme.data(.systemGreen)
        case .fair: Theme.data(.systemYellow)
        case .serious: Theme.data(.systemOrange)
        case .critical: Theme.data(.systemRed)
        }
    }

    static let explanation = "macOS's thermal state (ProcessInfo.thermalState): how hard the system is holding back "
        + "to stay cool, from nominal to critical. A level, not a temperature."
}

// MARK: - Layout

/// Where each column sits in a row of a given width: the name takes what
/// the three figures leave, and the range bar shows once there's room for it
/// beside a name of at least `labelMinimum`. In a narrow window the bar gives
/// way to the name, down to `barNarrowest`, before it's left out.
struct SensorColumns: Equatable {
    static let inset: CGFloat = 8
    static let spacing: CGFloat = 12
    /// The widest figure at the rows' size ("−1,520 mA") and the cell's margins.
    static let value: CGFloat = 76
    static let labelMinimum: CGFloat = 150
    static let barMinimum: CGFloat = 96
    static let barNarrowest: CGFloat = 56
    static let barMaximum: CGFloat = 260
    /// The dot and the gap before the name.
    static let dotWidth: CGFloat = 13

    var labelX: CGFloat = 0
    var labelWidth: CGFloat = 0
    var nowX: CGFloat = 0
    var lowX: CGFloat = 0
    var highX: CGFloat = 0
    var barX: CGFloat = 0
    /// 0 when the row is too narrow for the bar.
    var barWidth: CGFloat = 0

    init() {}

    init(width: CGFloat) {
        let available = max(width - 2 * Self.inset - 3 * (Self.value + Self.spacing), 0)
        let roomy = min(max(((available - Self.spacing) * 0.42).rounded(), Self.barMinimum), Self.barMaximum)
        let bar = min(roomy, available - Self.spacing - Self.labelMinimum)
        barWidth = bar >= Self.barNarrowest ? bar : 0
        labelX = Self.inset
        labelWidth = available - (barWidth > 0 ? barWidth + Self.spacing : 0)
        nowX = labelX + labelWidth + Self.spacing
        lowX = nowX + Self.value + Self.spacing
        highX = lowX + Self.value + Self.spacing
        barX = highX + Self.value + Self.spacing
    }
}

/// Fonts and colours shared by the table's rows. The readings are what the
/// page is for, so the rows take the body size (13 pt), a step up from other
/// tables' rows, with every figure in equal-width digits; what supports them
/// (the since line, column titles, where readings come from, the key) is
/// 12 pt in `.secondaryText`.
@MainActor
private enum SensorStyle {
    static let size = NSFont.preferredFont(forTextStyle: .body).pointSize
    static let label = NSFont.systemFont(ofSize: size)
    static let now = NSFont.numeric(size: size, weight: .medium)
    static let range = NSFont.numeric(size: size, weight: .regular)
    static let groupTitle = NSFont.systemFont(ofSize: size, weight: .semibold)
    static let supporting = NSFont.preferredFont(forTextStyle: .callout)
    static let columnTitle = NSFont.systemFont(ofSize: supporting.pointSize, weight: .medium)
    /// A one-line label's height at the rows' size.
    static let lineHeight = height(label)
    /// A one-line label's height at the supporting size.
    static let supportingHeight = height(supporting)

    private static func height(_ font: NSFont) -> CGFloat {
        let field = NSTextField(labelWithString: "Xg")
        field.font = font
        return ceil(field.intrinsicContentSize.height)
    }

    static func field(font: NSFont, alignment: NSTextAlignment = .left, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.alignment = alignment
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityElement(false)
        return field
    }
}

// MARK: - Table

final class SensorTableView: NSView {
    enum Line: Hashable {
        case header
        case pressure
        case group(SensorGroup)
        case reading(String)

        var height: CGFloat {
            switch self {
            case .header: SensorHeaderView.height
            case .pressure: 26
            case .group: 32
            case .reading: 24
            }
        }
    }

    /// The table's lines for these rows: the heading, thermal pressure,
    /// then each group's heading and its rows.
    static func lines(rows: [SensorReading], pressure: Bool) -> [Line] {
        var lines: [Line] = [.header]
        if pressure { lines.append(.pressure) }
        var group: SensorGroup?
        for row in rows {
            if row.group != group {
                group = row.group
                lines.append(.group(row.group))
            }
            lines.append(.reading(row.id))
        }
        return lines
    }

    override var isFlipped: Bool { true }

    private var lines: [Line] = []
    private let header = SensorHeaderView()
    private let pressureRow = SensorRowView()
    private var groupViews: [SensorGroup: SensorGroupView] = [:]
    private var rowViews: [String: SensorRowView] = [:]
    /// Each group's sources as its heading shows them, to notice a change.
    private var groupSources: [SensorGroup: String] = [:]
    /// The graph colours' revision the rows were coloured for.
    private var colorRevision: Int?
    /// The page's clip view, whose scrolling moves the heading.
    private weak var clipView: NSClipView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(header)
        addSubview(pressureRow)
        pressureRow.configurePressure()
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Sensors and clocks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `colors` is the graph colours' revision: when it changes, the rows are
    /// coloured again and the headings made again.
    func update(rows: [SensorReading], extremes: SensorExtremes, thermalState: ThermalState?, colors: Int) {
        let lines = Self.lines(rows: rows, pressure: thermalState != nil)
        if colors != colorRevision {
            colorRevision = colors
            groupViews.values.forEach { $0.removeFromSuperview() }
            groupViews = [:]
            groupSources = [:]
            header.recolor()
            self.lines = []
        }
        if lines != self.lines {
            rebuild(lines, rows: rows)
        }
        for row in rows {
            rowViews[row.id]?.show(row, range: extremes[row.id])
        }
        if let thermalState {
            pressureRow.showPressure(thermalState, mildest: extremes.mildestThermalState, worst: extremes.worstThermalState)
        }
        updateGroupSources(rows)
    }

    func showSince(_ text: String, help: String, reset: @escaping @MainActor () -> Void) {
        header.showSince(text, help: help)
        header.reset = reset
    }

    /// Makes and drops rows to match a new set; rows that stay keep their views.
    private func rebuild(_ lines: [Line], rows: [SensorReading]) {
        let ids = Set(rows.map(\.id))
        for (id, view) in rowViews where !ids.contains(id) {
            view.removeFromSuperview()
            rowViews[id] = nil
        }
        let groups = Set(rows.map(\.group))
        for (group, view) in groupViews where !groups.contains(group) {
            view.removeFromSuperview()
            groupViews[group] = nil
            groupSources[group] = nil
        }
        var group: SensorGroup?
        var index = 0
        for row in rows {
            if row.group != group {
                group = row.group
                index = 0
                if groupViews[row.group] == nil {
                    let view = SensorGroupView(group: row.group)
                    // Under the heading, which rows scroll beneath.
                    addSubview(view, positioned: .below, relativeTo: header)
                    groupViews[row.group] = view
                }
            }
            let view = rowViews[row.id] ?? {
                let view = SensorRowView()
                addSubview(view, positioned: .below, relativeTo: header)
                rowViews[row.id] = view
                return view
            }()
            view.configure(row, striped: index % 2 == 1)
            index += 1
        }
        pressureRow.isHidden = !lines.contains(.pressure)
        self.lines = lines
        needsLayout = true
    }

    /// The sources under each heading, such as "HID sensors · Derived".
    private func updateGroupSources(_ rows: [SensorReading]) {
        var sources: [SensorGroup: [String]] = [:]
        for row in rows where !(sources[row.group]?.contains(row.source.shortTitle) ?? false) {
            sources[row.group, default: []].append(row.source.shortTitle)
        }
        for (group, names) in sources {
            let text = names.joined(separator: " · ")
            guard groupSources[group] != text else { continue }
            groupSources[group] = text
            groupViews[group]?.sources = text
        }
    }

    // MARK: Sticky heading

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followScrolling()
    }

    /// Watches the page's scroll view, so the heading moves as it scrolls.
    /// Nothing here runs per tick: only scrolling and layout move it.
    private func followScrolling() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard clip !== clipView else { return }
        let center = NotificationCenter.default
        center.removeObserver(self)
        clipView = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(pageScrolled), name: NSView.boundsDidChangeNotification, object: clip)
        // Cards above the table growing or shrinking move it without a scroll.
        if let page = clip.documentView {
            center.addObserver(self, selector: #selector(pageResized), name: NSView.frameDidChangeNotification, object: page)
        }
        pinHeader()
    }

    @objc private func pageScrolled(_ notification: Notification) {
        pinHeader()
    }

    @objc private func pageResized(_ notification: Notification) {
        // After the page has placed the table, not before.
        needsLayout = true
    }

    /// Keeps the heading level with the top of the visible area once the
    /// table's top has scrolled past it (`StickyHeader`).
    private func pinHeader() {
        var visibleTop: CGFloat = 0
        if let clip = clipView {
            let inset = clip.contentInsets.top
            let edge = clip.isFlipped ? clip.bounds.minY + inset : clip.bounds.maxY - inset
            visibleTop = convert(NSPoint(x: 0, y: edge), from: clip).y
        }
        let y = CGFloat(StickyHeader.offset(visibleTop: Double(visibleTop), tableHeight: Double(bounds.height),
                                            headerHeight: Double(SensorHeaderView.height)))
        if header.frame.minY != y { header.setFrameOrigin(NSPoint(x: 0, y: y)) }
        header.isPinned = y > 0
    }

    override func layout() {
        super.layout()
        followScrolling()
        let columns = SensorColumns(width: bounds.width)
        var y: CGFloat = 0
        for line in lines {
            let frame = NSRect(x: 0, y: y, width: bounds.width, height: line.height)
            switch line {
            case .header:
                // Its slot stays at the top; `pinHeader` places it.
                header.frame.size = frame.size
                header.columns = columns
            case .pressure:
                pressureRow.frame = frame
                pressureRow.columns = columns
            case let .group(group):
                groupViews[group]?.frame = frame
            case let .reading(id):
                rowViews[id]?.frame = frame
                rowViews[id]?.columns = columns
            }
            y += line.height
        }
        pinHeader()
    }
}

// MARK: - Rows

/// The table's heading: when the lowest and highest count from, with Reset
/// and a key to the range bars, over the column titles. It sticks to the top
/// of the page while the rows scroll under it, and takes a solid fill and a
/// hairline only then, so at rest it reads as part of the card.
private final class SensorHeaderView: NSView {
    nonisolated static let sinceHeight: CGFloat = 28
    nonisolated static let titlesHeight: CGFloat = 22
    nonisolated static let height = sinceHeight + titlesHeight
    static let rangeHelp = "Each bar spans the sensor's scale. The coloured band runs from the lowest to the highest "
        + "reading since the reset, and the tick marks the reading now."

    private let since = SensorStyle.field(font: SensorStyle.supporting, color: .secondaryText)
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let key = SensorRangeKey()
    // The column titles.
    private let name = SensorStyle.field(font: SensorStyle.columnTitle, color: .secondaryText)
    private let now = SensorStyle.field(font: SensorStyle.columnTitle, alignment: .right, color: .secondaryText)
    private let low = SensorStyle.field(font: SensorStyle.columnTitle, alignment: .right, color: .secondaryText)
    private let high = SensorStyle.field(font: SensorStyle.columnTitle, alignment: .right, color: .secondaryText)
    private let range = SensorStyle.field(font: SensorStyle.columnTitle, color: .secondaryText)
    private let rangeInfo = NSImageView()
    private let rule = SensorRuleView()

    var reset: (@MainActor () -> Void)?

    var columns = SensorColumns() {
        didSet { if columns != oldValue { needsLayout = true } }
    }

    /// Stuck to the top of the page, over rows.
    var isPinned = false {
        didSet {
            guard isPinned != oldValue else { return }
            rule.isHidden = !isPinned
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        since.setAccessibilityElement(true)
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        resetButton.imagePosition = .imageLeading
        resetButton.bezelStyle = .push
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        resetButton.target = self
        resetButton.action = #selector(resetPressed)
        resetButton.toolTip = "Start every lowest and highest again from now"
        for (field, title) in [(name, "Sensor"), (now, "Now"), (low, "Lowest"), (high, "Highest"), (range, "Range")] {
            field.stringValue = title
        }
        rangeInfo.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        rangeInfo.contentTintColor = .secondaryText
        for view in [range, rangeInfo] as [NSView] { view.toolTip = Self.rangeHelp }
        rule.isHidden = true
        for view in [since, resetButton, key, name, now, low, high, range, rangeInfo, rule] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// After a change of graph colours: the key's bar and the pinned fill.
    func recolor() {
        key.recolor()
        needsDisplay = true
    }

    func showSince(_ text: String, help: String) {
        if since.stringValue != text {
            since.stringValue = text
            needsLayout = true
        }
        if since.toolTip != help { since.toolTip = help }
    }

    @objc private func resetPressed() {
        reset?()
    }

    override func updateLayer() {
        layer?.cornerRadius = 6
        // Opaque, so the rows under it don't show through: the page's
        // background washed with the card's colour, close to the card itself.
        layer?.backgroundColor = isPinned
            ? NSColor.windowBackgroundColor.blended(withFraction: 0.07, of: NSColor(Theme.thermal).fillShade)?.cgColor
            : nil
    }

    override func layout() {
        super.layout()
        let inset = SensorColumns.inset
        // The first line: since when, Reset beside it, and the key at the far end.
        let sinceSize = since.fittingSize
        let button = resetButton.fittingSize
        let sinceWidth = min(ceil(sinceSize.width), max(bounds.width - 2 * inset - button.width - 8, 0))
        since.frame = NSRect(x: inset, y: ((Self.sinceHeight - sinceSize.height) / 2).rounded(), width: sinceWidth, height: sinceSize.height)
        resetButton.frame = NSRect(x: since.frame.maxX + 8, y: ((Self.sinceHeight - button.height) / 2).rounded(),
                                   width: button.width, height: button.height)
        let keyWidth = key.fittingWidth
        let keyX = bounds.width - inset - keyWidth
        key.frame = NSRect(x: keyX, y: 0, width: keyWidth, height: Self.sinceHeight)
        key.isHidden = columns.barWidth == 0 || keyX < resetButton.frame.maxX + 16
        // The column titles.
        let height = ceil(name.intrinsicContentSize.height)
        let y = bounds.height - height - 3
        name.frame = NSRect(x: columns.labelX, y: y, width: columns.labelWidth, height: height)
        now.frame = NSRect(x: columns.nowX, y: y, width: SensorColumns.value, height: height)
        low.frame = NSRect(x: columns.lowX, y: y, width: SensorColumns.value, height: height)
        high.frame = NSRect(x: columns.highX, y: y, width: SensorColumns.value, height: height)
        let rangeWidth = min(ceil(range.fittingSize.width), columns.barWidth)
        range.frame = NSRect(x: columns.barX, y: y, width: rangeWidth, height: height)
        rangeInfo.frame = NSRect(x: range.frame.maxX + 1, y: y, width: 12, height: height)
        range.isHidden = columns.barWidth == 0
        rangeInfo.isHidden = range.isHidden
        rule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

/// A key to the range bars: a small bar and what its band and tick mean.
private final class SensorRangeKey: NSView {
    private static let barWidth: CGFloat = 30
    private static let gap: CGFloat = 6

    private let bar = SensorRangeBar()
    private let text = SensorStyle.field(font: SensorStyle.supporting, color: .secondaryText)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        recolor()
        bar.set(scale: 0...1, lowest: 0.2, highest: 0.75, now: 0.55)
        text.stringValue = "band: lowest to highest · tick: now"
        for view in [self, bar, text] as [NSView] { view.toolTip = SensorHeaderView.rangeHelp }
        addSubview(bar)
        addSubview(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var fittingWidth: CGFloat {
        Self.barWidth + Self.gap + ceil(text.fittingSize.width)
    }

    func recolor() {
        bar.color = NSColor(Theme.thermal)
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: ((bounds.height - 10) / 2).rounded(), width: Self.barWidth, height: 10)
        let height = ceil(text.intrinsicContentSize.height)
        text.frame = NSRect(x: Self.barWidth + Self.gap, y: ((bounds.height - height) / 2).rounded(),
                            width: max(bounds.width - Self.barWidth - Self.gap, 0), height: height)
    }
}

/// A group's heading: a swatch of the part's colour, its name, and where its
/// readings come from, over a hairline.
private final class SensorGroupView: NSView {
    private let swatch = SensorDotView()
    private let title = SensorStyle.field(font: SensorStyle.groupTitle)
    private let sourceField = SensorStyle.field(font: SensorStyle.supporting, alignment: .right, color: .secondaryText)
    private let rule = SensorRuleView()

    var sources = "" {
        didSet {
            sourceField.stringValue = sources
            // The field is as wide as its text.
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    init(group: SensorGroup) {
        super.init(frame: .zero)
        swatch.color = NSColor(group.color)
        swatch.cornerRadius = 2
        title.stringValue = group.title
        for view in [rule, swatch, title, sourceField] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(group.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let inset = SensorColumns.inset
        let height = SensorStyle.lineHeight
        let y = bounds.height - height - 3
        rule.frame = NSRect(x: inset, y: 6, width: max(bounds.width - 2 * inset, 0), height: 1)
        swatch.frame = NSRect(x: inset, y: (y + (height - 8) / 2).rounded(), width: 8, height: 8)
        // The cell draws its text inset, so its fitting width, not its text width.
        let sourceWidth = min(ceil(sourceField.fittingSize.width), bounds.width * 0.45)
        let sourceHeight = SensorStyle.supportingHeight
        // On the title's baseline (descenders are negative).
        let sourceY = y + height - sourceHeight + SensorStyle.groupTitle.descender - SensorStyle.supporting.descender
        sourceField.frame = NSRect(x: bounds.width - inset - sourceWidth, y: sourceY.rounded(), width: sourceWidth, height: sourceHeight)
        let titleX = inset + SensorColumns.dotWidth
        title.frame = NSRect(x: titleX, y: y, width: max(sourceField.frame.minX - titleX - 8, 0), height: height)
    }
}

/// One reading: a dot of its group's colour, its name, the reading now, the
/// lowest and highest since the reset, and a bar of that range with a tick
/// at the reading now. The figures are set only when they change.
final class SensorRowView: NSView {
    private let dot = SensorDotView()
    private let label = SensorStyle.field(font: SensorStyle.label)
    private let now = SensorStyle.field(font: SensorStyle.now, alignment: .right)
    private let low = SensorStyle.field(font: SensorStyle.range, alignment: .right, color: .secondaryText)
    private let high = SensorStyle.field(font: SensorStyle.range, alignment: .right, color: .secondaryText)
    private let bar = SensorRangeBar()
    private var striped = false
    /// What the figures show, so an unchanged reading isn't formatted again.
    private var shown = Shown()

    private struct Shown: Equatable {
        var now: Double?
        var note: String?
        var lowest: Double?
        var highest: Double?
        var unit: SensorUnit?
    }

    var columns = SensorColumns() {
        didSet { if columns != oldValue { needsLayout = true } }
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for view in [dot, label, now, low, high, bar] as [NSView] { addSubview(view) }
        // Over the row's own hover text, which says where the reading comes from.
        bar.toolTip = SensorHeaderView.rangeHelp
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ reading: SensorReading, striped: Bool) {
        label.stringValue = reading.label
        let color = NSColor(reading.group.color)
        dot.color = color
        bar.color = color
        toolTip = Self.help(for: reading)
        if striped != self.striped {
            self.striped = striped
            needsDisplay = true
        }
    }

    func configurePressure() {
        label.stringValue = "Thermal pressure"
        toolTip = ThermalState.explanation
    }

    func show(_ reading: SensorReading, range: SensorExtremes.Range?) {
        let next = Shown(now: reading.value, note: reading.note, lowest: range?.lowest, highest: range?.highest, unit: reading.unit)
        guard next != shown else { return }
        let unit = reading.unit
        if next.now != shown.now || next.note != shown.note || next.unit != shown.unit {
            now.stringValue = reading.value.map(unit.format) ?? reading.note ?? "—"
            now.textColor = reading.value == nil ? .secondaryText : .labelColor
        }
        if next.lowest != shown.lowest || next.unit != shown.unit {
            low.stringValue = range.map { unit.format($0.lowest) } ?? "—"
        }
        if next.highest != shown.highest || next.unit != shown.unit {
            high.stringValue = range.map { unit.format($0.highest) } ?? "—"
        }
        shown = next
        let scale = reading.scale ?? min(0, range?.lowest ?? 0)...max(0, range?.highest ?? 0)
        bar.set(scale: scale, lowest: range?.lowest, highest: range?.highest, now: reading.value)
        setAccessibilityLabel("\(reading.label): now \(now.stringValue), lowest \(low.stringValue), highest \(high.stringValue)")
    }

    func showPressure(_ state: ThermalState, mildest: ThermalState?, worst: ThermalState?) {
        let next = Shown(now: Double(state.severity), lowest: mildest.map { Double($0.severity) }, highest: worst.map { Double($0.severity) })
        guard next != shown else { return }
        shown = next
        now.stringValue = state.title
        low.stringValue = mildest?.title ?? "—"
        high.stringValue = worst?.title ?? "—"
        let color = NSColor(state.color)
        dot.color = color
        bar.color = NSColor((worst ?? state).color)
        bar.set(scale: 0...3, lowest: next.lowest, highest: next.highest, now: next.now)
        setAccessibilityLabel("Thermal pressure: now \(state.title), mildest \(low.stringValue), worst \(high.stringValue)")
    }

    override func updateLayer() {
        layer?.backgroundColor = striped ? NSColor.labelColor.withAlphaComponent(0.04).cgColor : nil
        layer?.cornerRadius = 4
    }

    override func layout() {
        super.layout()
        let height = SensorStyle.lineHeight
        let y = ((bounds.height - height) / 2).rounded()
        dot.frame = NSRect(x: columns.labelX, y: ((bounds.height - 7) / 2).rounded(), width: 7, height: 7)
        let labelX = columns.labelX + SensorColumns.dotWidth
        label.frame = NSRect(x: labelX, y: y, width: max(columns.labelWidth - SensorColumns.dotWidth, 0), height: height)
        now.frame = NSRect(x: columns.nowX, y: y, width: SensorColumns.value, height: height)
        low.frame = NSRect(x: columns.lowX, y: y, width: SensorColumns.value, height: height)
        high.frame = NSRect(x: columns.highX, y: y, width: SensorColumns.value, height: height)
        bar.frame = NSRect(x: columns.barX, y: (bounds.height - 10) / 2, width: columns.barWidth, height: 10)
        bar.isHidden = columns.barWidth == 0
    }

    /// Where the reading comes from, and what a signed figure means.
    private static func help(for reading: SensorReading) -> String {
        var lines = [reading.source.title + (reading.origin.map { ": \($0)" } ?? "")]
        if reading.group == .battery, reading.unit == .watts || reading.unit == .amperes {
            lines.append("Positive while charging, negative while discharging.")
        }
        if reading.unit == .fraction {
            lines.append("Share of the time it was running rather than idle or powered down.")
        }
        if reading.unit == .megahertz {
            lines.append("Average clock while it was running, weighted by time at each step.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Parts

/// A small filled circle (or rounded square) in a colour that follows the appearance.
private final class SensorDotView: NSView {
    var color = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    var cornerRadius: CGFloat?

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = cornerRadius ?? min(bounds.width, bounds.height) / 2
    }
}

/// A hairline in the separator colour.
private final class SensorRuleView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// A reading's range since the reset on its scale: a faint track, the span
/// from lowest to highest in the group's colour, and a tick at the reading now.
final class SensorRangeBar: NSView {
    var color = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    private var scale: ClosedRange<Double> = 0...1
    private var lowest: Double?
    private var highest: Double?
    private var now: Double?

    func set(scale: ClosedRange<Double>, lowest: Double?, highest: Double?, now: Double?) {
        guard scale != self.scale || lowest != self.lowest || highest != self.highest || now != self.now else { return }
        self.scale = scale
        self.lowest = lowest
        self.highest = highest
        self.now = now
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 6) / 2, width: bounds.width, height: 6)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let span = scale.upperBound - scale.lowerBound
        guard span > 0 else { return }
        func x(_ value: Double) -> CGFloat {
            CGFloat(min(max((value - scale.lowerBound) / span, 0), 1)) * bounds.width
        }
        if let lowest, let highest {
            let start = min(x(lowest), bounds.width - 3)
            let rect = NSRect(x: start, y: track.minY, width: max(x(highest) - start, 3), height: track.height)
            NSGradient(starting: color.withAlphaComponent(0.4), ending: color.withAlphaComponent(0.9))?
                .draw(in: NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3), angle: 0)
        }
        if let now {
            let tick = NSRect(x: min(max(x(now) - 1.25, 0), bounds.width - 2.5), y: 0, width: 2.5, height: bounds.height)
            NSColor.labelColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: tick, xRadius: 1.25, yRadius: 1.25).fill()
        }
    }
}
