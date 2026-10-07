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
}
