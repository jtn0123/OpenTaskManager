import Foundation

/// The retro display look Settings offers: live graphs on dark display
/// panels, each resource lit in its own colour or all in one, and figures
/// drawn as lit dots or bars, the way instrument panels and old terminals
/// showed them, instead of as type. On by default, in Color. This is the data and the maths; the app draws it
/// (`GraphColors`, `StreamGraphView`, `GlyphCache`).
public struct RetroDisplay: Sendable, Hashable {
    public typealias RGB = ColorContrast.RGB

    /// How figures are drawn, and whether the look is on at all.
    public enum Style: String, CaseIterable, Sendable, Identifiable {
        /// The app's usual graphs and type.
        case off
        /// Figures as round dots on a grid five wide and seven high.
        case dotMatrix
        /// Figures as seven bars each, the unlit bars faintly showing.
        case segments

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .off: "Off"
            case .dotMatrix: "Dot matrix"
            case .segments: "Segments"
            }
        }
    }

    /// The colour the panels light up in: each resource in its own, or
    /// all in one.
    public enum Tint: String, CaseIterable, Sendable, Identifiable {
        /// Each resource lit in its own colour, made as vivid as it goes
        /// (`GraphPalette.vivid`), on a panel tinted by its graph's first line.
        case color
        case green, amber, cyan, red, yellow, white

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .color: "Color"
            case .green: "Green"
            case .amber: "Amber"
            case .cyan: "Cyan"
            case .red: "Red"
            case .yellow: "Yellow"
            case .white: "White"
            }
        }

        /// Whether each resource keeps a colour of its own.
        public var isMulticolor: Bool { self == .color }

        /// The lit colour, as the dark panel shows it. Under `color`, the
        /// cool white of figures and panels that have no colour of their own.
        public var tone: RGB {
            switch self {
            case .color: RGB(red: 0.90, green: 0.94, blue: 0.96)
            case .green: RGB(red: 0.33, green: 1.00, blue: 0.48)
            case .amber: RGB(red: 1.00, green: 0.69, blue: 0.16)
            case .cyan: RGB(red: 0.30, green: 0.93, blue: 0.90)
            case .red: RGB(red: 1.00, green: 0.33, blue: 0.27)
            case .yellow: RGB(red: 0.98, green: 0.90, blue: 0.30)
            case .white: RGB(red: 0.90, green: 0.94, blue: 0.96)
            }
        }
    }

    /// How far lit dots, bars and lines bleed light around them.
    public enum Glow: String, CaseIterable, Sendable, Identifiable {
        case off, soft, strong

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .off: "Off"
            case .soft: "Soft"
            case .strong: "Strong"
            }
        }

        /// A figure's blur radius, as a share of one dot's cell (a bar's
        /// thickness for segments). Kept under a cell, so it stays inside
        /// the gap between figures.
        public var readoutBlur: Double {
            switch self {
            case .off: 0
            case .soft: 0.45
            case .strong: 0.9
            }
        }

        /// Opacity of the wide stroke under each graph line (the app's
        /// usual bloom is 0.18), 0 for none.
        public var bloom: Double {
            switch self {
            case .off: 0
            case .soft: 0.16
            case .strong: 0.28
            }
        }
    }

    public var style: Style
    public var tint: Tint
    public var glow: Glow

    public init(style: Style, tint: Tint, glow: Glow) {
        self.style = style
        self.tint = tint
        self.glow = glow
    }

    public var isOn: Bool { style != .off }

    /// What lit dots and bars sit on, unlit: black with a trace of the tint,
    /// as a display's glass is.
    public static let glass = RGB(0x070807)
    /// A Color display's glass: smoked, a shade under a dark window, so a
    /// panel takes on its colour and its grid shows, as a lit instrument
    /// panel's does. One colour's stays black, where lines that step down
    /// to the tint dimmed still read.
    public static let smokedGlass = RGB(0x181818)

    /// The panel graphs draw on.
    public var panel: RGB {
        panel(lit: tint.tone)
    }

    /// The panel under lines lit in `tone`: the glass with a trace of it.
    public func panel(lit tone: RGB) -> RGB {
        tint.isMulticolor ? ColorContrast.composite(tone, opacity: 0.06, over: Self.smokedGlass)
            : ColorContrast.composite(tone, opacity: 0.05, over: Self.glass)
    }

    /// How a panel's grid, edge and axis labels draw over its glass.
    public struct Ruling: Sendable, Hashable {
        /// What the grid is drawn in: a plain grid's lines at `grid`, a
        /// fine grid's rows at `minorGrid` and every few at `majorGrid`.
        public var ink: RGB
        public var grid: Double
        public var minorGrid: Double
        public var majorGrid: Double
        /// The edge and the axis labels, in the panel's light at these opacities.
        public var edge: Double
        public var label: Double
    }

    /// A panel lit in `tone`'s ruling. One colour's is all the tint, faint,
    /// labels a little dimmed so the data comes first. Color's grid is
    /// near white with a trace of the light, so every panel's reads alike
    /// whatever its colour (in the tint, a blue one's barely showed), its
    /// edge lit nearly as its line is, and its labels at full strength.
    public func ruling(lit tone: RGB) -> Ruling {
        guard tint.isMulticolor else {
            return Ruling(ink: tone, grid: 0.13, minorGrid: 0.13, majorGrid: 0.22, edge: 0.28, label: 0.72)
        }
        return Ruling(ink: ColorContrast.composite(tone, opacity: 0.2, over: .white),
                      grid: 0.12, minorGrid: 0.045, majorGrid: 0.13, edge: 0.65, label: 0.95)
    }

    /// The opacity of the wide stroke under each graph line, and how far
    /// past the line it spreads, in points: on a Color display tighter and
    /// brighter, as a neon tube's light is, on one colour's softer, as a
    /// phosphor's.
    public var bloom: (opacity: Double, spread: Double) {
        tint.isMulticolor ? (glow.bloom * 1.6, 4) : (glow.bloom, 6)
    }
    /// Dots and bars that aren't lit, so a figure reads as a display's:
    /// fainter on a pale window, where they stand out more and could turn
    /// a small 6 into an 8.
    public static func unlitOpacity(dark: Bool) -> Double {
        dark ? 0.1 : 0.05
    }

    /// Figures' colour: the tint as it is on a dark window, and deepened to
    /// 4.5:1 against white in light mode, as the graphs' labels are.
    public var readout: GraphPalette.Swatch {
        GraphPalette.Swatch(tone: tint.tone, lightContrast: 4.5, darkContrast: 3)
    }
}

// MARK: - Palette

extension GraphPalette {
    /// Every role in the retro tint and nothing else, as a one-colour
    /// display shows it: lines that share a chart differ by brightness, from
    /// near white down to the tint dimmed, as well as by the dashes and
    /// fills the graphs already give a pair's second line.
    /// Under `color`, `base` (the preset and the user's own colours) made
    /// vivid instead.
    public static func retro(_ tint: RetroDisplay.Tint, base: GraphPalette = .preset(.standard)) -> GraphPalette {
        guard !tint.isMulticolor else {
            var vivid = base.vivid()
            vivid.emphasis = .vivid
            return vivid
        }
        let tone = tint.tone
        let levels = RetroDisplay.levels(of: tone)
        // Each resource's own page draws it in the tint. Where lines share a
        // chart, heat and what's pinned take the brightest level, a pair's
        // second line and the parts beside the main one the middle levels,
        // what's kept back (cached, swap, DRAM) the deep one and "the rest"
        // the dimmest.
        let brightest = levels[0], second = levels[1], middle = levels[2], deep = levels[4], dimmest = levels[5]
        let tones: [Role: RGB] = [
            .cpu: tone, .memory: tone, .disk: tone, .network: tone, .charging: tone, .gpuRenderer: tone, .gpuClock: tone,
            .batterySensor: tone,
            .gpu: brightest, .wired: brightest, .pageIn: brightest, .thermal: brightest, .discharging: brightest,
            .diskSecondary: second, .networkSecondary: second, .pageOut: second,
            .compressed: middle, .slowerTier: middle, .power: middle, .neuralEngine: middle, .gpuTiler: middle,
            .storageSensor: middle, .fan: middle,
            .cached: deep, .swap: deep, .dram: deep, .other: dimmest, .restOfSystem: dimmest,
        ]
        // Neighbours in a stack alternate bright and deep; "other" is the dimmest.
        let series = [tone, levels[3], brightest, deep, second, middle]
        return GraphPalette(swatches: tones.mapValues { Swatch(tone: $0, lightContrast: 4.5, darkContrast: 3) },
                            series: series.map { Swatch(tone: $0, lightContrast: 4.5, darkContrast: 3) },
                            emphasis: .retro)
    }
}

extension RetroDisplay {
    /// The brightest and dimmest a shade gets, as OKLab lightness: just
    /// short of white, and just above where a line would need lightening
    /// to read on a dark window (which would squeeze the dim levels together).
    static let lightnessRange = (top: 0.95, bottom: 0.54)

    /// Six shades of `tone` besides itself, brightest first, spread evenly
    /// in lightness over `lightnessRange` with `tone` in its place among
    /// them. Lighter ones are `tone` mixed toward white, darker ones `tone`
    /// scaled down, so all keep its hue.
    static func levels(of tone: RGB) -> [RGB] {
        let (top, bottom) = lightnessRange
        let lightness = tone.lightness
        let step = (top - bottom) / 6
        var above = Int(((top - lightness) / step).rounded())
        // A tone nearly as light as the top (yellow) is the top itself, so
        // no level crowds it from above.
        while above > 0, (top - lightness) / Double(above) < step * 0.75 {
            above -= 1
        }
        let below = 6 - above
        let lighter = (0..<above).map { top - (top - lightness) * Double($0) / Double(above) }
        let darker = (0..<below).map { lightness - (lightness - bottom) * Double($0 + 1) / Double(below) }
        return (lighter + darker).map { tone.atLightness($0) }
    }
}

extension GraphEmphasis {
    /// Retro panels are dark in either appearance, so traces keep their
    /// tone; the grid is the panel's own (`RetroDisplay.ruling`).
    public static let retro = GraphEmphasis(lightTrace: 1, grid: 1, fill: 0.85, bands: 0.9)
    /// A Color display's: its lines carry the colour, lit, so the area
    /// under one is a faint wash.
    public static let vivid = GraphEmphasis(lightTrace: 1, grid: 1, fill: 0.4, bands: 0.9)
}

extension ColorContrast.RGB {
    /// How light this colour looks, 0 for black to 1 for white: OKLab
    /// lightness, which steps evenly to the eye.
    var lightness: Double {
        PerceptualColor.lab(self).lightness
    }

    /// This colour at `target` lightness, its hue kept: scaled down to
    /// darken it, mixed toward white to lighten it.
    func atLightness(_ target: Double) -> Self {
        let lighter = target > lightness
        func shade(_ amount: Double) -> Self {
            lighter ? ColorContrast.composite(.white, opacity: amount, over: self) : scaled(amount)
        }
        // Lightness rises steadily with either amount, so bisect for it.
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let amount = (low + high) / 2
            if shade(amount).lightness < target { low = amount } else { high = amount }
        }
        return shade(high)
    }
}
