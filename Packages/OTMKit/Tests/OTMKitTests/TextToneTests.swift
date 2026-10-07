@testable import OTMKit
import Testing

struct TextToneTests {
    typealias RGB = ColorContrast.RGB

    /// The tints the app washes cards with (their dark-mode tones, which the
    /// washes use in both appearances): CPU, memory, disk, network, GPU,
    /// power, thermal, fan, the "by app" series, the System page's displays,
    /// battery, software and security, the Users page's system accounts, and
    /// the grey of an untinted card.
    static let tints = [
        RGB(red: 0.24, green: 0.56, blue: 1.00), RGB(red: 0.64, green: 0.42, blue: 0.96),
        RGB(red: 0.20, green: 0.74, blue: 0.44), RGB(red: 0.98, green: 0.55, blue: 0.20),
        RGB(red: 0.10, green: 0.74, blue: 0.80), RGB(red: 0.95, green: 0.72, blue: 0.12),
        RGB(red: 1.00, green: 0.42, blue: 0.30), RGB(red: 0.38, green: 0.78, blue: 0.98),
        RGB(red: 0.16, green: 0.80, blue: 0.70), RGB(red: 0.94, green: 0.40, blue: 0.62),
        RGB(red: 0.62, green: 0.82, blue: 0.30), RGB(red: 0.36, green: 0.62, blue: 0.98),
        RGB(red: 0.30, green: 0.80, blue: 0.40), RGB(red: 0.52, green: 0.50, blue: 0.96),
        RGB(red: 0.24, green: 0.74, blue: 0.56), RGB(red: 0.56, green: 0.60, blue: 0.68),
        RGB(red: 0.50, green: 0.50, blue: 0.50),
    ]

    /// How strongly a card lays its tint over the window, at its top edge.
    static let cardWash = 0.16

    /// Window backgrounds in each appearance, from white and the light window
    /// grey to the dark control and window greys.
    static func windows(dark: Bool) -> [RGB] {
        let greys = dark ? [0.118, 0.196] : [1, 0.925]
        return greys.map { RGB(red: $0, green: $0, blue: $0) }
    }

    static func cards(dark: Bool) -> [RGB] {
        windows(dark: dark).flatMap { window in
            tints.map { ColorContrast.composite($0, opacity: cardWash, over: window) }
        }
    }

    @Test(arguments: [false, true])
    func secondaryTextReachesAAOnEveryCard(dark: Bool) {
        for card in Self.cards(dark: dark) {
            #expect(TextTone.contrast(.secondary, dark: dark, on: card) >= 4.5, "card \(card)")
        }
    }

    @Test(arguments: [false, true])
    func tertiaryTextStaysLegible(dark: Bool) {
        for card in Self.cards(dark: dark) {
            #expect(TextTone.contrast(.tertiary, dark: dark, on: card) >= 3, "card \(card)")
        }
    }

    @Test(arguments: [false, true])
    func theSystemSecondaryLabelFallsShort(dark: Bool) {
        // Why the app has its own tone: 50% black and 55% white miss AA on some cards.
        let system = dark ? 0.55 : 0.5
        let ink = dark ? RGB.white : RGB.black
        let worst = Self.cards(dark: dark).map { card in
            ColorContrast.ratio(ColorContrast.composite(ink, opacity: system, over: card), card)
        }.min() ?? 0
        #expect(worst < 4.5)
    }

    @Test(arguments: [false, true])
    func keepsTheHierarchy(dark: Bool) {
        let primary = 0.85
        let secondary = TextTone.opacity(.secondary, dark: dark)
        let tertiary = TextTone.opacity(.tertiary, dark: dark)
        #expect(primary - secondary >= 0.15, "secondary text still reads as secondary")
        #expect(secondary - tertiary >= 0.15)
    }

    @Test func compositesLikeAlphaBlending() {
        let red = RGB(red: 1, green: 0, blue: 0)
        #expect(ColorContrast.composite(red, opacity: 1, over: .white) == red)
        #expect(ColorContrast.composite(red, opacity: 0, over: .white) == .white)
        #expect(ColorContrast.composite(.black, opacity: 0.5, over: .white) == RGB(red: 0.5, green: 0.5, blue: 0.5))
        #expect(ColorContrast.composite(.black, opacity: 2, over: .white) == .black, "opacity is clamped")
    }
}
