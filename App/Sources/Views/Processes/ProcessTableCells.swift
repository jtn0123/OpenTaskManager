import AppKit
import OTMKit

// The process table's cells and menu items (see `ProcessOutlineView`).

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

final class SectionCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class NameCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.textColor = .secondaryLabelColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        addSubview(badge)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @MainActor
    func configure(process: ProcessSample, app: NSRunningApplication?, childCount: Int, isExpanded: Bool) {
        // Skip unchanged values: the table restyles visible rows every tick and
        // re-setting an image or string forces a redraw.
        let icon = IconCache.icon(for: process, app: app)
        if imageView?.image !== icon { imageView?.image = icon }
        let name = app?.localizedName ?? process.name
        if textField?.stringValue != name { textField?.stringValue = name }
        let color: NSColor = process.state == .stopped ? .secondaryLabelColor : .labelColor
        if textField?.textColor != color { textField?.textColor = color }
        var notes: [String] = []
        if childCount > 0, !isExpanded { notes.append("(\(childCount + 1))") }
        if process.state == .stopped { notes.append("Suspended") }
        if process.state == .zombie { notes.append("Zombie") }
        if process.isTranslated { notes.append("Rosetta") }
        let badgeText = notes.joined(separator: " · ")
        if badge.stringValue != badgeText { badge.stringValue = badgeText }
        if toolTip != process.executablePath { toolTip = process.executablePath }
    }
}

/// Value cell with an optional meter bar behind busy values.
final class ValueCell: NSTableCellView {
    private let bar = CALayer()
    private var fraction: Double = 0

    func setMeter(_ fraction: Double, color: NSColor?) {
        let shown = color == nil || fraction < 0.01 ? 0 : min(fraction, 1)
        // Busier rows get a deeper colour as well as a longer bar.
        let fill = color?.withAlphaComponent(0.20 + 0.40 * shown).cgColor
        if bar.backgroundColor != fill {
            // A standalone layer animates every change unless told not to.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.backgroundColor = fill
            CATransaction.commit()
        }
        guard shown != self.fraction else { return }
        self.fraction = shown
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let track = bounds.insetBy(dx: 2, dy: 3)
        bar.frame = CGRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        bar.isHidden = fraction == 0
        CATransaction.commit()
    }

    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        wantsLayer = true
        bar.cornerRadius = 3
        bar.isHidden = true
        layer?.addSublayer(bar)
        let label = NSTextField(labelWithString: "")
        label.alignment = alignment
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
