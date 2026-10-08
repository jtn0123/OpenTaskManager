import Foundation
@testable import OTMKit
import Testing

struct GraphPaletteTests {
    typealias RGB = ColorContrast.RGB
    typealias Role = GraphPalette.Role

    /// Colours that share a chart, so must be told apart: the second line
    /// of a pair, a stack's bands, a legend's swatches. "s0" to "s5" are the
    /// "by app" series colours, over "other" for everything else.
    static let charts: [String: [String]] = [
        "disk": ["disk", "diskSecondary"],
        "network": ["network", "networkSecondary"],
        "memory composition": ["wired", "memory", "compressed", "cached", "other"],
        "swap": ["swap", "compressed"],
        "paging": ["pageIn", "pageOut", "swap", "compressed"],
        "compressor": ["compressed", "cached"],
        "History memory": ["memory", "wired"],
        "power parts": ["cpu", "gpu", "neuralEngine", "dram", "restOfSystem"],
        "History power": ["power", "cpu", "gpu"],
        "power supply": ["power", "charging", "discharging"],
        "GPU engines": ["gpu", "gpuRenderer", "gpuTiler"],
        "GPU clock": ["gpuClock", "gpu", "power"],
        "core types": ["cpu", "slowerTier"],
        "sensors": ["thermal", "storageSensor", "batterySensor"],
        "by app": ["s0", "s1", "s2", "s3", "s4", "s5", "other"],
        "resources": ["cpu", "memory", "gpu", "disk", "network", "power", "thermal"],
    ]

    /// The smallest OKLab distance between two colours of a chart that
    /// counts as different at a glance: about what Okabe and Ito's own
    /// closest pair keeps under deuteranopia.
    static let apart = 0.07

    static func swatch(_ name: String, in palette: GraphPalette) -> GraphPalette.Swatch {
        if name.hasPrefix("s"), let index = Int(name.dropFirst()) { return palette.series[index] }
        guard let role = Role(rawValue: name) else { preconditionFailure("no role \(name)") }
        return palette[role]
    }

    /// The closest two colours of any chart, as `vision` sees them in `dark`
    /// or light mode, with the chart and colours' names: as text and legends
    /// draw them, or as `traces`, which light mode draws deeper.
    static func closest(_ palette: GraphPalette, vision: Vision, dark: Bool, traces: Bool = false) -> (distance: Double, pair: String) {
        var closest = (distance: Double.infinity, pair: "")
        for (chart, names) in charts {
            let seen = names.map { name -> (String, RGB) in
                let swatch = swatch(name, in: palette)
                let shade = dark ? swatch.dark : traces ? palette.emphasis.trace(swatch.light) : swatch.light
                return (name, vision.simulate(shade))
            }
            for (first, (a, colorA)) in seen.enumerated() {
                for (b, colorB) in seen[(first + 1)...] {
                    let distance = OKLab.distance(colorA, colorB)
                    if distance < closest.distance { closest = (distance, "\(chart): \(a)/\(b)") }
                }
            }
        }
        return closest
    }

    // MARK: Contrast

    @Test(arguments: GraphPalette.Preset.allCases)
    func everyColourReachesItsFloorsInBothAppearances(_ preset: GraphPalette.Preset) {
        let palette = GraphPalette.preset(preset)
        let floors = preset == .highContrast ? (light: 7.0, dark: 7.0) : (light: 4.5, dark: 3.0)
        let swatches = Role.allCases.map { ($0.rawValue, palette[$0]) } + palette.series.enumerated().map { ("s\($0)", $1) }
        for (name, swatch) in swatches {
            #expect(swatch.lightContrast >= floors.light && swatch.darkContrast >= floors.dark, "\(name)")
            #expect(ColorContrast.ratio(swatch.light, .white) >= swatch.lightContrast, "\(preset) \(name) light")
            #expect(ColorContrast.ratio(swatch.dark, GraphPalette.darkBackground) >= swatch.darkContrast, "\(preset) \(name) dark")
        }
    }

    @Test(arguments: GraphPalette.Preset.allCases)
    func everyRoleHasAColourOfItsOwn(_ preset: GraphPalette.Preset) {
        let palette = GraphPalette.preset(preset)
        #expect(Set(palette.swatches.keys) == Set(Role.allCases))
        #expect(palette.series.count == 6)
    }

    // MARK: Standard

    @Test func standardKeepsTheAppsColours() {
        let palette = GraphPalette.preset(.standard)
        #expect(palette[.cpu].tone == RGB(red: 0.24, green: 0.56, blue: 1.00))
        #expect(palette[.network].tone == RGB(red: 0.98, green: 0.55, blue: 0.20))
        #expect(palette.series[0].tone == RGB(red: 0.26, green: 0.58, blue: 1.00))
        for role in Role.allCases {
            // Every tone clears 3:1 on the dark window, so dark mode draws it as it is...
            #expect(palette[role].dark == palette[role].tone, "\(role)")
            // ...and light mode deepens it to WCAG AA, as `Theme.data` always has.
            #expect(palette[role].light == ColorContrast.deepened(palette[role].tone, toContrast: 4.5), "\(role)")
        }
    }

    @Test func standardMergesForRedGreenColourBlindness() {
        // Why there's a colour-blind preset: the first and last app colours,
        // blue and purple, are one colour with protanopia, and CPU blue and
        // memory purple close to one with deuteranopia.
        let palette = GraphPalette.preset(.standard)
        let first = palette.series[0].dark, last = palette.series[5].dark
        #expect(OKLab.distance(Vision.protanopia.simulate(first), Vision.protanopia.simulate(last)) < 0.02)
        let cpu = palette[.cpu].dark, memory = palette[.memory].dark
        #expect(OKLab.distance(Vision.deuteranopia.simulate(cpu), Vision.deuteranopia.simulate(memory)) < 0.03)
        #expect(Self.closest(palette, vision: .protanopia, dark: true).distance < Self.apart)
    }

    // MARK: Colour-blind friendly

    @Test(arguments: Vision.allCases, [true, false])
    func colourBlindColoursStayApart(_ vision: Vision, dark: Bool) {
        let closest = Self.closest(GraphPalette.preset(.colorBlind), vision: vision, dark: dark)
        #expect(closest.distance >= Self.apart, "\(vision) \(dark ? "dark" : "light"): \(closest.pair) \(closest.distance)")
    }

    @Test func colourBlindDarkModeDrawsOkabeItosHues() {
        let palette = GraphPalette.preset(.colorBlind)
        let hues: Set<RGB> = [RGB(0x56B4E9), RGB(0x0072B2), RGB(0xE69F00), RGB(0xF0E442), RGB(0xD55E00), RGB(0xCC79A7), RGB(0x009E73)]
        #expect(Set(Role.resources.map { palette[$0].dark }).isSubset(of: hues))
        #expect(Set(palette.series.map(\.dark)) == hues.subtracting([RGB(0x009E73)]))
    }

    // MARK: High contrast

    @Test(arguments: [true, false])
    func highContrastColoursStayApart(dark: Bool) {
        let closest = Self.closest(GraphPalette.preset(.highContrast), vision: .typical, dark: dark)
        #expect(closest.distance >= Self.apart, "\(dark ? "dark" : "light"): \(closest.pair) \(closest.distance)")
    }

    @Test func highContrastKeepsTheStandardHues() {
        let standard = GraphPalette.preset(.standard), high = GraphPalette.preset(.highContrast)
        for role in Role.allCases {
            #expect(high[role].tone == standard[role].tone, "\(role)")
            #expect(ColorContrast.luminance(high[role].light) <= ColorContrast.luminance(standard[role].light), "\(role) deeper")
            #expect(ColorContrast.luminance(high[role].dark) >= ColorContrast.luminance(standard[role].dark), "\(role) brighter")
        }
    }

    // MARK: Emphasis

    @Test(arguments: GraphPalette.Preset.allCases)
    func tracesAreAsDeepOrDeeperInTheSameHue(_ preset: GraphPalette.Preset) {
        let palette = GraphPalette.preset(preset)
        let swatches = Role.allCases.map { ($0.rawValue, palette[$0]) } + palette.series.enumerated().map { ("s\($0)", $1) }
        for (name, swatch) in swatches {
            let light = swatch.light, trace = palette.emphasis.trace(light)
            #expect(ColorContrast.ratio(trace, .white) >= ColorContrast.ratio(light, .white), "\(preset) \(name)")
            // Every component scaled alike: the hue and saturation stay.
            #expect(abs(trace.red * light.green - trace.green * light.red) < 1e-9, "\(preset) \(name)")
            #expect(abs(trace.blue * light.green - trace.green * light.blue) < 1e-9, "\(preset) \(name)")
        }
    }

    @Test func standardTracesGoFromAAToAboutFiveAndAHalfToOne() {
        let palette = GraphPalette.preset(.standard)
        for role in Role.resources {
            let ratio = ColorContrast.ratio(palette.emphasis.trace(palette[role].light), .white)
            #expect(ratio > 5.3 && ratio < 5.9, "\(role) \(ratio)")
        }
    }

    @Test(arguments: [GraphPalette.Preset.colorBlind, .highContrast])
    func tracesKeepTheirShadeWhereDeeperWouldMergeThem(_ preset: GraphPalette.Preset) {
        // High contrast's are 7:1 or deeper already; the colour-blind
        // palette's pairs sit at the edge of `apart` for protanopes.
        let palette = GraphPalette.preset(preset)
        for role in Role.allCases {
            #expect(palette.emphasis.trace(palette[role].light) == palette[role].light, "\(preset) \(role)")
        }
    }

    @Test(arguments: Vision.allCases)
    func colourBlindTracesStayApart(_ vision: Vision) {
        let closest = Self.closest(GraphPalette.preset(.colorBlind), vision: vision, dark: false, traces: true)
        #expect(closest.distance >= Self.apart, "\(vision): \(closest.pair) \(closest.distance)")
    }

    @Test func decorationFadesLessInHighContrast() {
        for preset in GraphPalette.Preset.allCases {
            let emphasis = GraphPalette.preset(preset).emphasis
            #expect(emphasis.grid < 1 && emphasis.fill < 1 && emphasis.bands < 1, "\(preset)")
            // A stack's bands are the readings, and fade less than a fill under a line.
            #expect(emphasis.fill < emphasis.bands, "\(preset)")
        }
        #expect(GraphPalette.preset(.highContrast).emphasis.grid > GraphPalette.preset(.standard).emphasis.grid)
        #expect(GraphEmphasis.traceWidth > 1)
    }

    // MARK: Overrides

    @Test func anOverrideKeepsThePresetsFloors() {
        let pale = RGB(0xFFF5A0), dim = RGB(0x202A60)
        let palette = GraphPalette.preset(.standard).overriding([.cpu: pale, .memory: dim])
        #expect(palette[.cpu].tone == pale)
        #expect(ColorContrast.ratio(palette[.cpu].light, .white) >= 4.5, "deepened for light mode")
        #expect(ColorContrast.ratio(palette[.memory].dark, GraphPalette.darkBackground) >= 3, "brightened for dark mode")
        #expect(palette[.gpu] == GraphPalette.preset(.standard)[.gpu], "the rest as they were")
        let high = GraphPalette.preset(.highContrast).overriding([.cpu: pale])
        #expect(ColorContrast.ratio(high[.cpu].light, .white) >= 7)
        #expect(high.emphasis == GraphEmphasis.highContrast, "and its emphasis")
    }

    @Test func presetsGoByTheirSavedNames() {
        for preset in GraphPalette.Preset.allCases {
            #expect(GraphPalette.Preset(rawValue: preset.rawValue) == preset)
            #expect(!preset.name.isEmpty && !preset.summary.isEmpty)
        }
        #expect(Role.resources.map(\.title) == ["CPU", "Memory", "GPU", "Disk", "Network", "Power"])
    }
}

// MARK: - Colour vision

/// How a colour looks with each kind of colour vision: Machado, Oliveira
/// and Fernandes's simulation (2009) of complete protanopia and
/// deuteranopia, applied in linear RGB.
enum Vision: CaseIterable, CustomStringConvertible {
    case typical, protanopia, deuteranopia

    var description: String {
        switch self {
        case .typical: "typical"
        case .protanopia: "protanopia"
        case .deuteranopia: "deuteranopia"
        }
    }

    private var matrix: [[Double]]? {
        switch self {
        case .typical: nil
        case .protanopia: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
        case .deuteranopia: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
        }
    }

    func simulate(_ color: ColorContrast.RGB) -> ColorContrast.RGB {
        guard let matrix else { return color }
        let linear = [color.red, color.green, color.blue].map(OKLab.linear)
        let seen = matrix.map { row in zip(row, linear).reduce(0) { $0 + $1.0 * $1.1 } }.map(OKLab.encoded)
        return ColorContrast.RGB(red: seen[0], green: seen[1], blue: seen[2])
    }
}

/// Björn Ottosson's OKLab, a perceptual colour space: Euclidean distance in
/// it tracks how different two colours look.
enum OKLab {
    static func linear(_ component: Double) -> Double {
        let value = min(max(component, 0), 1)
        return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ component: Double) -> Double {
        let value = min(max(component, 0), 1)
        return value <= 0.003_130_8 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// Lightness, then the green–red and blue–yellow axes.
    static func lab(_ color: ColorContrast.RGB) -> [Double] {
        let (red, green, blue) = (linear(color.red), linear(color.green), linear(color.blue))
        // The cone responses, long, medium and short, compressed.
        let long = cbrt(0.412_221_470_8 * red + 0.536_332_536_3 * green + 0.051_445_992_9 * blue)
        let medium = cbrt(0.211_903_498_2 * red + 0.680_699_545_1 * green + 0.107_396_956_6 * blue)
        let short = cbrt(0.088_302_461_9 * red + 0.281_718_837_6 * green + 0.629_978_700_5 * blue)
        return [0.210_454_255_3 * long + 0.793_617_785_0 * medium - 0.004_072_046_8 * short,
                1.977_998_495_1 * long - 2.428_592_205_0 * medium + 0.450_593_709_9 * short,
                0.025_904_037_1 * long + 0.782_771_766_2 * medium - 0.808_675_766_0 * short]
    }

    static func distance(_ first: ColorContrast.RGB, _ second: ColorContrast.RGB) -> Double {
        zip(lab(first), lab(second)).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }
}
