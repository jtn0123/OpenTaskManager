import AppKit
import OTMKit
import SwiftUI

/// A level bar of small segments under a Performance detail's title: as
/// many segments as fit its width (`LevelSegments`), lit from the left in
/// the device's colour for the current reading. nil, for a reading this Mac
/// doesn't give, leaves every segment dim.
///
/// Core Animation, like `RingGaugeView`: the segments' shape is built once
/// per size, and a reading only resizes the clip over the lit copy, which
/// eases in the render server.
struct LevelBar: NSViewRepresentable {
    var fraction: Double?
    var color: Color
    /// What the bar measures, for VoiceOver ("CPU busy").
    var label: String

    func makeNSView(context: Context) -> LevelBarView {
        LevelBarView()
    }

    func updateNSView(_ view: LevelBarView, context: Context) {
        view.update(fraction: fraction, color: NSColor(color), label: label)
    }
}

final class LevelBarView: NSView {
    static let segment: CGFloat = 5
    static let gap: CGFloat = 2.5

    /// Every segment, dim.
    private let track = CAShapeLayer()
    /// Holds the lit copy and shows as much of it as the reading lights.
    private let clip = CALayer()
    private let lit = CAGradientLayer()
    private let litMask = CAShapeLayer()
    private var fraction: Double?
    private var color = NSColor.controlAccentColor
    private var count = 0
    private var builtSize: CGSize = .zero
    private var shownLit = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clip.anchorPoint = .zero
        clip.masksToBounds = true
        lit.anchorPoint = .zero
        lit.startPoint = CGPoint(x: 0, y: 0.5)
        lit.endPoint = CGPoint(x: 1, y: 0.5)
        lit.mask = litMask
        clip.addSublayer(lit)
        layer?.addSublayer(track)
        layer?.addSublayer(clip)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(fraction: Double?, color: NSColor, label: String) {
        self.fraction = fraction
        self.color = color
        if accessibilityLabel() != label { setAccessibilityLabel(label) }
        applyColors()
        applyLevel(animated: true)
    }

    override func layout() {
        super.layout()
        guard bounds.size != builtSize else { return }
        builtSize = bounds.size
        count = LevelSegments.count(width: bounds.width, segment: Self.segment, gap: Self.gap)
        let path = segmentsPath(in: bounds, count: count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.path = path
        lit.frame = bounds
        litMask.frame = lit.bounds
        litMask.path = path
        CATransaction.commit()
        shownLit = -1
        applyLevel(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The segments spread over the whole width, so the last ends at the edge.
    private func segmentsPath(in rect: CGRect, count: Int) -> CGPath {
        let path = CGMutablePath()
        guard count > 0, rect.width > 0 else { return path }
        let width = (rect.width - CGFloat(count - 1) * Self.gap) / CGFloat(count)
        let radius = min(1.5, width / 2)
        for index in 0..<count {
            let segment = CGRect(x: CGFloat(index) * (width + Self.gap), y: 0, width: width, height: rect.height)
            path.addRoundedRect(in: segment, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let litDim: CGFloat = dark ? 0.13 : 0.10
            let dim: CGFloat = fraction == nil ? 0.06 : litDim
            track.fillColor = NSColor.labelColor.withAlphaComponent(dim).cgColor
            lit.colors = [color.fillShade.withAlphaComponent(dark ? 0.75 : 0.85).cgColor, color.cgColor]
        }
        CATransaction.commit()
    }

    /// Lights the reading's segments, easing between readings.
    private func applyLevel(animated: Bool) {
        let lit = fraction.map { LevelSegments.lit($0, of: count) } ?? 0
        guard lit != shownLit, count > 0 else { return }
        shownLit = lit
        let width = (bounds.width - CGFloat(count - 1) * Self.gap) / CGFloat(count)
        let shown = lit == 0 ? 0 : CGFloat(lit) * (width + Self.gap) - Self.gap
        CATransaction.begin()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        clip.frame = CGRect(x: 0, y: 0, width: shown, height: bounds.height)
        CATransaction.commit()
        setAccessibilityValue(fraction.map { Format.percent($0) } ?? "Not reported")
    }
}
