import Foundation

/// The colours graphs draw with, as data: a swatch for each role (CPU,
/// memory, the parts of memory and of the power draw...) and the series
/// colours "by app" graphs hand out, for each preset Settings offers.
///
/// A swatch is a tone and two contrast floors. Dark mode draws the tone,
/// mixed toward white if it falls short of `darkContrast` against the dark
/// window; light mode draws it deepened until it reaches `lightContrast`
/// against white, since the bright tones that glow on a dark card wash out
/// as lines and text on a pale one. Fills and washes take the dark-mode
/// tone in both appearances, so they stay pastel. Colour is never the only
/// difference between two lines on a chart: they're also dashed or dotted,
/// filled or not, and named in a legend.
public struct GraphPalette: Sendable, Hashable {
    public typealias RGB = ColorContrast.RGB

    public enum Preset: String, CaseIterable, Sendable, Identifiable {
        /// The app's own colours: a hue for each resource.
        case standard
        /// Hues that people with red–green colour blindness still tell apart.
        case colorBlind
        /// Every line and label at 7:1 or more, in both appearances.
        case highContrast

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .standard: "Standard"
            case .colorBlind: "Color-blind friendly"
            case .highContrast: "High contrast"
            }
        }

        /// What the preset is for, in a sentence.
        public var summary: String {
            switch self {
            case .standard: "A color for each resource, deepened in light mode so lines and labels stay readable."
            case .colorBlind: "Blues, oranges and yellows that stay apart with red–green color blindness "
                + "(deuteranopia and protanopia), at different depths in light mode."
            case .highContrast: "The standard hues drawn darker in light mode and brighter in dark mode, "
                + "so every line reaches 7:1 against the window."
            }
        }
    }

    /// What a colour stands for.
    public enum Role: String, CaseIterable, Sendable {
        case cpu, memory, gpu, disk, network, power
        /// Disk writes and network sends, beside reads and receives.
        case diskSecondary, networkSecondary
        case thermal, fan
        /// Core types after the fastest.
        case slowerTier
        /// Everything not broken out on its own.
        case other
        // Memory composition and traffic.
        case wired, compressed, cached, swap, pageIn, pageOut
        // Power components and supply.
        case neuralEngine, dram, restOfSystem, charging, discharging
        // GPU engines and clock.
        case gpuRenderer, gpuTiler, gpuClock
        // Temperature sensors after the chip's.
        case storageSensor, batterySensor

        /// The resources Settings lets a user recolour one by one.
        public static let resources: [Role] = [.cpu, .memory, .gpu, .disk, .network, .power]

        /// The resource's name in Settings.
        public var title: String {
            switch self {
            case .cpu: "CPU"
            case .gpu: "GPU"
            default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }
    }

    public struct Swatch: Sendable, Hashable {
        public var tone: RGB
        /// The contrast the light-mode shade reaches against white.
        public var lightContrast: Double
        /// The contrast the dark-mode tone reaches against `GraphPalette.darkBackground`.
        public var darkContrast: Double

        public init(tone: RGB, lightContrast: Double, darkContrast: Double) {
            self.tone = tone
            self.lightContrast = lightContrast
            self.darkContrast = darkContrast
        }

        /// What dark mode draws, and what fills take in either appearance.
        public var dark: RGB {
            ColorContrast.brightened(tone, toContrast: darkContrast, against: GraphPalette.darkBackground)
        }

        /// What light mode draws lines and text in.
        public var light: RGB {
            ColorContrast.deepened(tone, toContrast: lightContrast)
        }
    }

    /// The window background in dark mode, #1E1E1E: what a dark-mode line
    /// has to stand out from. Light mode's is white.
    public static let darkBackground = RGB(0x1E1E1E)

    public private(set) var swatches: [Role: Swatch]
    /// The colours "by app" graphs give their apps, in turn.
    public let series: [Swatch]

    public subscript(role: Role) -> Swatch {
        swatches[role] ?? Swatch(tone: RGB(0x808080), lightContrast: 4.5, darkContrast: 3)
    }

    /// This palette with these roles' tones replaced (a user's picks in
    /// Settings). Each keeps its preset's contrast floors, so whatever the
    /// pick, its lines still read in both appearances.
    public func overriding(_ tones: [Role: RGB]) -> GraphPalette {
        var palette = self
        for (role, tone) in tones {
            palette.swatches[role]?.tone = tone
        }
        return palette
    }

    public static func preset(_ preset: Preset) -> GraphPalette {
        switch preset {
        case .standard: standard
        case .colorBlind: colorBlind
        case .highContrast: highContrast
        }
    }
}

// MARK: - Presets

extension GraphPalette {
    /// Builds a palette from tones, each with the preset's floors unless
    /// given its own light-mode depth.
    private init(tones: [Role: RGB], series: [RGB], light: Double, dark: Double, depths: [Role: Double] = [:],
                 seriesDepths: [Double] = [], brighter: [Role: Double] = [:]) {
        swatches = tones.reduce(into: [:]) { result, entry in
            result[entry.key] = Swatch(tone: entry.value, lightContrast: depths[entry.key] ?? light,
                                       darkContrast: brighter[entry.key] ?? dark)
        }
        self.series = series.enumerated().map { index, tone in
            Swatch(tone: tone, lightContrast: seriesDepths.indices.contains(index) ? seriesDepths[index] : light, darkContrast: dark)
        }
    }

    /// The app's colours since its first release. Every tone already clears
    /// 3:1 on the dark window, so dark mode draws them as they are.
    private static let standardTones: [Role: RGB] = [
        .cpu: RGB(red: 0.24, green: 0.56, blue: 1.00),
        .memory: RGB(red: 0.64, green: 0.42, blue: 0.96),
        .gpu: RGB(red: 0.10, green: 0.74, blue: 0.80),
        .disk: RGB(red: 0.20, green: 0.74, blue: 0.44),
        .network: RGB(red: 0.98, green: 0.55, blue: 0.20),
        .power: RGB(red: 0.95, green: 0.72, blue: 0.12),
        .diskSecondary: RGB(red: 0.55, green: 0.86, blue: 0.40),
        .networkSecondary: RGB(red: 0.98, green: 0.80, blue: 0.30),
        .thermal: RGB(red: 1.00, green: 0.42, blue: 0.30),
        .fan: RGB(red: 0.38, green: 0.78, blue: 0.98),
        .slowerTier: RGB(red: 0.22, green: 0.82, blue: 0.86),
        .other: RGB(red: 0.50, green: 0.50, blue: 0.50),
        .wired: RGB(red: 0.93, green: 0.36, blue: 0.62),
        .compressed: RGB(red: 0.98, green: 0.62, blue: 0.24),
        .cached: RGB(red: 0.32, green: 0.70, blue: 0.86),
        .swap: RGB(red: 0.96, green: 0.42, blue: 0.36),
        .pageIn: RGB(red: 0.32, green: 0.70, blue: 0.86),
        .pageOut: RGB(red: 0.64, green: 0.42, blue: 0.96),
        .neuralEngine: RGB(red: 0.90, green: 0.40, blue: 0.86),
        .dram: RGB(red: 0.62, green: 0.50, blue: 0.98),
        .restOfSystem: RGB(red: 0.62, green: 0.58, blue: 0.48),
        .charging: RGB(red: 0.30, green: 0.85, blue: 0.45),
        .discharging: RGB(red: 0.98, green: 0.45, blue: 0.35),
        .gpuRenderer: RGB(red: 0.58, green: 0.92, blue: 0.96),
        .gpuTiler: RGB(red: 0.36, green: 0.62, blue: 1.00),
        .gpuClock: RGB(red: 0.45, green: 0.95, blue: 0.75),
        .storageSensor: RGB(red: 0.30, green: 0.80, blue: 0.62),
        .batterySensor: RGB(red: 0.98, green: 0.78, blue: 0.26),
    ]

    private static let standardSeries = [
        RGB(red: 0.26, green: 0.58, blue: 1.00),
        RGB(red: 0.98, green: 0.58, blue: 0.22),
        RGB(red: 0.16, green: 0.80, blue: 0.70),
        RGB(red: 0.94, green: 0.40, blue: 0.62),
        RGB(red: 0.62, green: 0.82, blue: 0.30),
        RGB(red: 0.70, green: 0.52, blue: 0.98),
    ]

    /// Deepened to WCAG AA in light mode, since the same colours draw
    /// headings, legends and state labels; 3:1 on the dark window, the
    /// floor for lines and other graphics.
    static let standard = GraphPalette(tones: standardTones, series: standardSeries, light: 4.5, dark: 3)

    /// Built from Okabe and Ito's Color Universal Design hues (2008): sky
    /// blue, blue, orange, yellow, vermillion, reddish purple and bluish
    /// green. Protanopes and deuteranopes lose the red–green axis, which the
    /// standard palette leans on (its CPU blue and purple series, its network
    /// orange and power amber, merge for them), but keep lightness and the
    /// blue–yellow axis, along which these hues stay apart. Light mode can't
    /// use lightness the same way, since every shade must reach 4.5:1 on
    /// white, so each hue is deepened to its own depth there (4.5:1 to 10:1),
    /// and hues that share a chart differ in depth as well as hue. Shared
    /// charts pair a blue with an orange or yellow wherever they can: disk
    /// reads and writes, CPU and slower cores, page-ins and swap.
    static let colorBlind: GraphPalette = {
        let sky = RGB(0x56B4E9), blue = RGB(0x0072B2), orange = RGB(0xE69F00), yellow = RGB(0xF0E442)
        let vermillion = RGB(0xD55E00), purple = RGB(0xCC79A7), green = RGB(0x009E73)
        // A dim neutral for "everything else", under the hues around it.
        let grey = RGB(0x6E6E6E), beige = RGB(0xB5AC98)
        let depth: [RGB: Double] = [sky: 4.5, blue: 6.5, orange: 6.5, yellow: 4.5, vermillion: 10, purple: 8, green: 4.5,
                                    grey: 5.5, beige: 8]
        let tones: [Role: RGB] = [
            .cpu: sky, .memory: purple, .gpu: green, .disk: blue, .network: orange, .power: yellow,
            .diskSecondary: sky, .networkSecondary: yellow, .thermal: vermillion, .fan: sky, .slowerTier: orange, .other: grey,
            .wired: vermillion, .compressed: orange, .cached: sky, .swap: vermillion, .pageIn: sky, .pageOut: purple,
            .neuralEngine: yellow, .dram: blue, .restOfSystem: beige, .charging: blue, .discharging: vermillion,
            .gpuRenderer: sky, .gpuTiler: blue, .gpuClock: sky, .storageSensor: sky, .batterySensor: yellow,
        ]
        // Blues and yellows alternate up a stack of apps, so neighbours differ most.
        let series = [sky, orange, blue, yellow, vermillion, purple]
        return GraphPalette(tones: tones, series: series, light: 4.5, dark: 3, depths: tones.mapValues { depth[$0] ?? 4.5 },
                            seriesDepths: series.map { depth[$0] ?? 4.5 })
    }()

    /// The standard hues at WCAG AAA, 7:1, against white in light mode and
    /// against the dark window in dark mode. At that depth hues alone tell
    /// lines apart less well, so the second line of a pair (writes, sends,
    /// the renderer, the GPU clock) and a few colours that share charts
    /// with near hues are drawn deeper still in light mode, and the chip
    /// temperature brighter in dark mode.
    static let highContrast = GraphPalette(
        tones: standardTones, series: standardSeries, light: 7, dark: 7,
        depths: [.diskSecondary: 11, .networkSecondary: 11, .gpuRenderer: 11, .gpuClock: 11, .other: 10, .swap: 10,
                 .thermal: 10, .dram: 10, .power: 9],
        brighter: [.thermal: 9]
    )
}
