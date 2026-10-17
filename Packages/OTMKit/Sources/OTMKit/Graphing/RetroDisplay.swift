import Foundation

/// The retro display look Settings offers: live graphs on dark display
/// panels in one colour, and figures drawn as lit dots or bars, the way
/// instrument panels and old terminals showed them, instead of as type.
/// Off by default. This is the data and the maths; the app draws it
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

    /// The colour the panels light up in.
    public enum Tint: String, CaseIterable, Sendable, Identifiable {
        case green, amber, cyan, red, yellow, white

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .green: "Green"
            case .amber: "Amber"
            case .cyan: "Cyan"
            case .red: "Red"
            case .yellow: "Yellow"
            case .white: "White"
            }
        }

        /// The lit colour, as the dark panel shows it.
        public var tone: RGB {
            switch self {
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

    /// The panel graphs draw on.
    public var panel: RGB {
        ColorContrast.composite(tint.tone, opacity: 0.05, over: Self.glass)
    }

    /// The panel's edge: the tint, faint.
    public static let edgeOpacity = 0.28
    /// A panel's grid lines, the tint at this opacity, and a fine grid's
    /// firmer rows at `majorGridOpacity`.
    public static let gridOpacity = 0.13
    public static let majorGridOpacity = 0.22
    /// Axis labels on a panel: the tint, a little dimmed, so the data comes first.
    public static let labelOpacity = 0.72
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
    /// Every role in the retro tint, so graphs read as one display's. Lines
    /// that share a chart differ by depth or by a turn of the tint's hue
    /// toward warm or cool (`warmed`), as well as by dashes and fills, which
    /// the graphs already give a pair's second line. "Everything else" is
    /// the tint dimmed.
    public static func retro(_ tint: RetroDisplay.Tint) -> GraphPalette {
        let tone = tint.tone
        let deep = tone.scaled(0.62)
        let dim = tone.scaled(0.4)
        let warmer = tone.warmed(true)
        let cooler = tone.warmed(false)
        let deepWarm = warmer.scaled(0.66)
        let deepCool = cooler.scaled(0.66)
        // Each resource's own page draws it in the tint; where lines share a
        // chart (a pair, a stack, the power parts) they take the warmer,
        // cooler or deeper shades, heat warmer, "the rest" dim.
        let tones: [Role: RGB] = [
            .cpu: tone, .memory: cooler, .gpu: warmer, .disk: tone, .network: tone, .power: cooler,
            .diskSecondary: warmer, .networkSecondary: warmer, .thermal: warmer, .fan: cooler, .slowerTier: cooler, .other: dim,
            .wired: warmer, .compressed: tone, .cached: deep, .swap: deep, .pageIn: warmer, .pageOut: cooler,
            .neuralEngine: cooler, .dram: deep, .restOfSystem: dim, .charging: tone, .discharging: warmer,
            .gpuRenderer: tone, .gpuTiler: cooler, .gpuClock: tone, .storageSensor: cooler, .batterySensor: tone,
        ]
        // Neighbours in a stack alternate bright and deep.
        let series = [tone, deepCool, warmer, deep, cooler, deepWarm]
        return GraphPalette(swatches: tones.mapValues { Swatch(tone: $0, lightContrast: 4.5, darkContrast: 3) },
                            series: series.map { Swatch(tone: $0, lightContrast: 4.5, darkContrast: 3) },
                            emphasis: .retro)
    }
}

extension GraphEmphasis {
    /// Retro panels are dark in either appearance, so traces keep their
    /// tone; the grid is the panel's own (`RetroDisplay.gridOpacity`).
    public static let retro = GraphEmphasis(lightTrace: 1, grid: 1, fill: 0.85, bands: 0.9)
}

extension ColorContrast.RGB {
    /// This colour moved `amount` (0...1) of the way to `other`.
    func mixed(with other: Self, by amount: Double) -> Self {
        Self(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
             blue: blue + (other.blue - blue) * amount)
    }

    /// The tint's warmer or cooler neighbour: its hue turned 45° toward red
    /// or toward blue, or for a near grey, mixed most of the way to a warm or
    /// a cool white, since a grey has no hue to turn.
    func warmed(_ warmer: Bool) -> Self {
        let chroma = max(red, green, blue) - min(red, green, blue)
        guard chroma > 0.15 else {
            return mixed(with: warmer ? Self(red: 1, green: 0.78, blue: 0.5) : Self(red: 0.55, green: 0.78, blue: 1), by: 0.65)
        }
        return turned(by: warmer ? -45 : 45)
    }

    /// This colour with its hue turned `degrees` round the colour wheel, its
    /// lightness and saturation kept. A grey stays grey.
    func turned(by degrees: Double) -> Self {
        let high = max(red, green, blue), low = min(red, green, blue)
        let chroma = high - low
        guard chroma > 0.0001 else { return self }
        var hue: Double
        if high == red {
            hue = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
        } else if high == green {
            hue = (blue - red) / chroma + 2
        } else {
            hue = (red - green) / chroma + 4
        }
        hue = (hue * 60 + degrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        func lifted(_ red: Double, _ green: Double, _ blue: Double) -> Self {
            Self(red: red + low, green: green + low, blue: blue + low)
        }
        return switch Int(sector) {
        case 0: lifted(chroma, second, 0)
        case 1: lifted(second, chroma, 0)
        case 2: lifted(0, chroma, second)
        case 3: lifted(0, second, chroma)
        case 4: lifted(second, 0, chroma)
        default: lifted(chroma, 0, second)
        }
    }
}
