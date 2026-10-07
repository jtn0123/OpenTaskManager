@testable import OTMKit
import Testing

struct ColorContrastTests {
    typealias RGB = ColorContrast.RGB

    private static let black = RGB(red: 0, green: 0, blue: 0)
    /// The data colours' dark-mode tones: GPU teal, power amber, memory purple, disk green.
    static let palette = [
        RGB(red: 0.10, green: 0.74, blue: 0.80),
        RGB(red: 0.95, green: 0.72, blue: 0.12),
        RGB(red: 0.64, green: 0.42, blue: 0.96),
        RGB(red: 0.20, green: 0.74, blue: 0.44),
    ]

    @Test func luminanceAndRatioMatchWCAG() {
        #expect(ColorContrast.luminance(.white) == 1)
        #expect(ColorContrast.luminance(Self.black) == 0)
        #expect(abs(ColorContrast.ratio(Self.black, .white) - 21) < 1e-9)
        #expect(ColorContrast.ratio(.white, Self.black) == ColorContrast.ratio(Self.black, .white), "order doesn't matter")
        #expect(ColorContrast.ratio(.white, .white) == 1)
        // #777777 on white is the textbook just-misses-AA grey, about 4.48:1.
        let grey = RGB(red: 0x77 / 255, green: 0x77 / 255, blue: 0x77 / 255)
        #expect(abs(ColorContrast.ratio(grey, .white) - 4.48) < 0.01)
    }

    @Test(arguments: palette)
    func deepensJustEnoughToReachTheContrast(color: RGB) {
        #expect(ColorContrast.ratio(color, .white) < 4.5, "the bright tones fail on white to begin with")
        let deep = ColorContrast.deepened(color, toContrast: 4.5)
        let ratio = ColorContrast.ratio(deep, .white)
        #expect(ratio >= 4.5)
        #expect(ratio < 4.55, "no darker than it needs to be")
    }

    @Test(arguments: palette)
    func keepsTheHue(color: RGB) {
        let deep = ColorContrast.deepened(color, toContrast: 4.5)
        let factor = deep.red / color.red
        #expect(factor > 0 && factor < 1)
        #expect(abs(deep.green - color.green * factor) < 1e-9)
        #expect(abs(deep.blue - color.blue * factor) < 1e-9)
    }

    @Test func leavesDarkEnoughColoursAlone() {
        let navy = RGB(red: 0.05, green: 0.10, blue: 0.45)
        #expect(ColorContrast.deepened(navy, toContrast: 4.5) == navy)
        #expect(ColorContrast.deepened(.white, toContrast: 1) == .white)
    }

    @Test func endsAtBlackWhenTheContrastIsOutOfReach() {
        let deep = ColorContrast.deepened(.white, toContrast: 30)
        #expect(ColorContrast.luminance(deep) < 1e-6)
    }

    /// The Storage treemap's tile fills: amber archives, light purple
    /// developer files, orange audio, cyan caches, and the Changes red.
    static let midTones = [
        RGB(red: 0.80, green: 0.62, blue: 0.10),
        RGB(red: 0.58, green: 0.40, blue: 0.94),
        RGB(red: 0.95, green: 0.52, blue: 0.18),
        RGB(red: 0.18, green: 0.65, blue: 0.82),
        RGB(red: 0.89, green: 0.35, blue: 0.27),
    ]

    @Test(arguments: midTones)
    func midTonesTakeDarkInk(color: RGB) {
        #expect(ColorContrast.ink(over: [color]) == .dark)
        // Dark ink is the better of the two, and reads at AA.
        #expect(ColorContrast.ratio(color, Self.black) > ColorContrast.ratio(color, .white))
        #expect(ColorContrast.ratio(color, Self.black) >= 4.5)
    }

    @Test func deepColoursTakeLightInk() {
        #expect(ColorContrast.ink(over: [RGB(red: 0.05, green: 0.10, blue: 0.45)]) == .light)
        #expect(ColorContrast.ink(over: [RGB(red: 0.45, green: 0.18, blue: 0.70)]) == .light)
        #expect(ColorContrast.ink(over: [Self.black]) == .light)
        #expect(ColorContrast.ink(over: [.white]) == .dark)
    }

    @Test func inksCrossWhereTheirContrastsMeet() {
        // Black and white tie at a luminance of √(1.05 × 0.05) − 0.05, about 0.179.
        let under = RGB(red: 0.44, green: 0.44, blue: 0.44)
        let over = RGB(red: 0.48, green: 0.48, blue: 0.48)
        #expect(ColorContrast.luminance(under) < 0.179 && ColorContrast.luminance(over) > 0.179)
        #expect(ColorContrast.ink(over: [under]) == .light)
        #expect(ColorContrast.ink(over: [over]) == .dark)
    }

    @Test func aLabelOverAGradientTakesTheInkWhoseWorstContrastIsBest() {
        let amber = RGB(red: 0.80, green: 0.62, blue: 0.10)
        // Faded into a dark card at the bottom: that end wants white.
        let faded = ColorContrast.composite(amber, opacity: 0.35, over: RGB(red: 0.10, green: 0.10, blue: 0.10))
        #expect(ColorContrast.ink(over: [amber]) == .dark)
        #expect(ColorContrast.ink(over: [faded]) == .light)
        let dark = min(ColorContrast.ratio(amber, Self.black), ColorContrast.ratio(faded, Self.black))
        let light = min(ColorContrast.ratio(amber, .white), ColorContrast.ratio(faded, .white))
        #expect(ColorContrast.ink(over: [amber, faded]) == (dark >= light ? .dark : .light))
        #expect(ColorContrast.ink(over: []) == .dark, "nothing under it: the default")
    }
}
