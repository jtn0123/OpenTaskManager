import Foundation
@testable import OTMKit
import Testing

struct RetroDisplayTests {
    typealias RGB = ColorContrast.RGB
    typealias Role = GraphPalette.Role

    // MARK: Palette

    /// Live graphs draw on the dark panel whatever the appearance, so it's
    /// the dark shades that share a chart there; lines that share one still
    /// differ by brightness, not only by dashes. One display
    /// colour can't give seven resources seven colours, and needn't: each
    /// has graphs of its own, so only charts that mix lines are checked.
    @Test(arguments: RetroDisplay.Tint.allCases)
    func chartColoursStayApartOnThePanel(_ tint: RetroDisplay.Tint) {
        let palette = GraphPalette.retro(tint)
        var closest = (distance: Double.infinity, pair: "")
        for (chart, names) in GraphPaletteTests.charts where chart != "resources" {
            let shades = names.map { (name: $0, shade: GraphPaletteTests.swatch($0, in: palette).dark) }
            for (index, first) in shades.enumerated() {
                for second in shades[(index + 1)...] {
                    let distance = OKLab.distance(first.shade, second.shade)
                    if distance < closest.distance { closest = (distance, "\(chart): \(first.name)/\(second.name)") }
                }
            }
        }
        #expect(closest.distance >= 0.05, "\(tint): \(closest.pair) \(closest.distance)")
    }

    @Test(arguments: RetroDisplay.Tint.allCases)
    func everyRoleHasAShadeThatReads(_ tint: RetroDisplay.Tint) {
        let palette = GraphPalette.retro(tint)
        let panel = RetroDisplay(style: .dotMatrix, tint: tint, glow: .soft).panel
        for role in Role.allCases {
            #expect(ColorContrast.ratio(palette[role].dark, panel) >= 3, "\(tint) \(role) on the panel")
            #expect(ColorContrast.ratio(palette[role].light, .white) >= 4.5 - 0.01, "\(tint) \(role) on white")
        }
        for swatch in palette.series {
            #expect(ColorContrast.ratio(swatch.dark, panel) >= 3)
        }
        #expect(palette.emphasis == (tint.isMulticolor ? .vivid : .retro))
    }

    static let oneColor = RetroDisplay.Tint.allCases.filter { !$0.isMulticolor }

    @Test(arguments: oneColor)
    func theMainLinesAreTheTint(_ tint: RetroDisplay.Tint) {
        let palette = GraphPalette.retro(tint)
        #expect(palette[.cpu].tone == tint.tone)
        #expect(palette.series[0].tone == tint.tone)
    }

    @Test(arguments: RetroDisplay.Tint.allCases)
    func readoutsReadInBothAppearances(_ tint: RetroDisplay.Tint) {
        let display = RetroDisplay(style: .segments, tint: tint, glow: .off)
        #expect(ColorContrast.ratio(display.readout.light, .white) >= 4.5 - 0.01)
        #expect(ColorContrast.ratio(display.readout.dark, GraphPalette.darkBackground) >= 3)
        #expect(ColorContrast.ratio(tint.tone, display.panel) >= 6, "lit on unlit glass")
    }

    @Test func aOneColourPanelIsNearlyBlack() {
        for tint in Self.oneColor {
            let panel = RetroDisplay(style: .dotMatrix, tint: tint, glow: .soft).panel
            #expect(ColorContrast.luminance(panel) < 0.01)
        }
    }

    @Test func aColorPanelIsSmokedGlassTintedByItsLight() {
        let display = RetroDisplay(style: .dotMatrix, tint: .color, glow: .soft)
        for role in [Role.cpu, .memory, .disk, .network] {
            let light = GraphPalette.retro(.color)[role].dark
            let panel = display.panel(lit: light)
            // A shade under a dark window, its light still well clear of it.
            #expect(ColorContrast.luminance(panel) < ColorContrast.luminance(GraphPalette.darkBackground) * 1.25)
            #expect(ColorContrast.luminance(panel) > ColorContrast.luminance(RetroDisplay.glass))
            #expect(ColorContrast.ratio(light, panel) >= 3, "\(role)")
            #expect(PerceptualColor.lab(panel).chroma > PerceptualColor.lab(RetroDisplay.smokedGlass).chroma)
        }
    }

    @Test func aColorPanelsRulingReadsWhateverItsColour() {
        let color = RetroDisplay(style: .dotMatrix, tint: .color, glow: .soft)
        let blue = color.ruling(lit: RGB(0x067CFF)), green = color.ruling(lit: RGB(0x30D058))
        // Near white either way, so a blue panel's grid shows as a green one's does.
        #expect(abs(ColorContrast.luminance(blue.ink) - ColorContrast.luminance(green.ink)) < 0.12)
        #expect(blue.minorGrid < blue.grid && blue.grid <= blue.majorGrid)
        #expect(blue.edge > RetroDisplay(style: .dotMatrix, tint: .green, glow: .soft).ruling(lit: RGB(0x30D058)).edge)
        // One colour's grid stays its tint.
        let amber = RetroDisplay(style: .dotMatrix, tint: .amber, glow: .soft)
        #expect(amber.ruling(lit: RetroDisplay.Tint.amber.tone).ink == RetroDisplay.Tint.amber.tone)
    }

    @Test func aColorDisplaysGlowIsTighterAndBrighter() {
        for glow in RetroDisplay.Glow.allCases {
            let color = RetroDisplay(style: .dotMatrix, tint: .color, glow: glow).bloom
            let green = RetroDisplay(style: .dotMatrix, tint: .green, glow: glow).bloom
            #expect(color.opacity >= green.opacity && color.spread < green.spread)
            #expect(color.opacity < 0.5)
        }
    }

    @Test func anInstrumentPanelIsFloodedWithItsLight() {
        let plain = RetroDisplay(style: .dotMatrix, tint: .color, glow: .soft)
        let instrument = RetroDisplay(style: .dotMatrix, tint: .color, glow: .soft, instrument: true)
        for role in [Role.cpu, .memory, .disk, .network] {
            let light = GraphPalette.retro(.color, instrument: true)[role].dark
            let panel = instrument.panel(lit: light)
            // Far more of its colour than smoked glass takes, still dark enough that its line reads.
            #expect(PerceptualColor.lab(panel).chroma > PerceptualColor.lab(plain.panel(lit: light)).chroma * 2, "\(role)")
            #expect(ColorContrast.luminance(panel) < ColorContrast.luminance(GraphPalette.darkBackground) * 1.5, "\(role)")
            #expect(ColorContrast.ratio(light, panel) >= 3, "\(role)")
            // Ruled in its own colour, the many rows of a fine grid fainter than its quarters.
            let ruling = instrument.ruling(lit: light)
            #expect(ruling.ink == light)
            #expect(ruling.minorGrid < ruling.grid && ruling.grid < ruling.majorGrid)
            #expect(ruling.edge > plain.ruling(lit: light).edge)
        }
        #expect(instrument.bloom.opacity > plain.bloom.opacity && instrument.bloom.opacity < 0.6)
        #expect(GraphPalette.retro(.color, instrument: true).emphasis == .instrument)
        #expect(GraphEmphasis.instrument.fill > GraphEmphasis.vivid.fill)
    }

    @Test func instrumentPanelsAreColorsAlone() {
        #expect(RetroDisplay(style: .dotMatrix, tint: .color, glow: .soft, instrument: true).isInstrument)
        #expect(RetroDisplay(style: .segments, tint: .color, glow: .off, instrument: true).isInstrument)
        #expect(!RetroDisplay(style: .dotMatrix, tint: .color, glow: .soft).isInstrument)
        #expect(!RetroDisplay(style: .off, tint: .color, glow: .soft, instrument: true).isInstrument)
        // One colour's panels keep their look, asked or not.
        for tint in Self.oneColor {
            let asked = RetroDisplay(style: .dotMatrix, tint: tint, glow: .soft, instrument: true)
            let plain = RetroDisplay(style: .dotMatrix, tint: tint, glow: .soft)
            #expect(!asked.isInstrument, "\(tint)")
            #expect(asked.panel == plain.panel && asked.ruling(lit: tint.tone) == plain.ruling(lit: tint.tone), "\(tint)")
            #expect(asked.bloom == plain.bloom, "\(tint)")
            #expect(GraphPalette.retro(tint, instrument: true) == GraphPalette.retro(tint), "\(tint)")
        }
    }

    @Test func onlyOffIsOff() {
        #expect(!RetroDisplay(style: .off, tint: .amber, glow: .strong).isOn)
        #expect(RetroDisplay(style: .dotMatrix, tint: .amber, glow: .off).isOn)
        #expect(RetroDisplay(style: .segments, tint: .amber, glow: .off).isOn)
    }

    @Test func unlitPartsAreFaintAndFainterOnAPaleWindow() {
        let dark = RetroDisplay.unlitOpacity(dark: true), light = RetroDisplay.unlitOpacity(dark: false)
        #expect(light > 0 && light < dark && dark <= 0.12)
    }

    @Test func glowGrowsAndStaysInsideAFigure() {
        let glows = RetroDisplay.Glow.allCases
        #expect(glows.map(\.readoutBlur) == glows.map(\.readoutBlur).sorted())
        #expect(glows.map(\.bloom) == glows.map(\.bloom).sorted())
        #expect(RetroDisplay.Glow.off.readoutBlur == 0 && RetroDisplay.Glow.off.bloom == 0)
        #expect(glows.allSatisfy { $0.readoutBlur < 1 })
    }

    // MARK: Levels

    /// A colour's hue in degrees, or nil for a grey.
    static func hue(_ color: RGB) -> Double? {
        let high = max(color.red, color.green, color.blue), low = min(color.red, color.green, color.blue)
        guard high - low > 0.0001 else { return nil }
        let chroma = high - low
        let sector = high == color.red ? ((color.green - color.blue) / chroma + 6).truncatingRemainder(dividingBy: 6)
            : high == color.green ? (color.blue - color.red) / chroma + 2 : (color.red - color.green) / chroma + 4
        return sector * 60
    }

    @Test(arguments: oneColor)
    func everyShadeIsTheTintsHue(_ tint: RetroDisplay.Tint) throws {
        let palette = GraphPalette.retro(tint)
        let hue = try #require(Self.hue(tint.tone))
        for swatch in Role.allCases.map({ palette[$0] }) + palette.series {
            let shade = try #require(Self.hue(swatch.tone))
            #expect(abs(shade - hue) < 0.01, "\(tint) \(swatch.tone.hex)")
        }
    }

    @Test(arguments: RetroDisplay.Tint.allCases)
    func levelsStepEvenlyFromNearWhiteToDim(_ tint: RetroDisplay.Tint) {
        let levels = RetroDisplay.levels(of: tint.tone)
        let lightness = ([tint.tone] + levels).map(\.lightness).sorted(by: >)
        #expect(levels.count == 6)
        #expect(abs((lightness.first ?? 0) - RetroDisplay.lightnessRange.top) < 0.001 || tint.tone.lightness > 0.9)
        #expect(abs((lightness.last ?? 0) - RetroDisplay.lightnessRange.bottom) < 0.001)
        // No two levels nearer than a step and a half of the even spread would be.
        let even = (RetroDisplay.lightnessRange.top - RetroDisplay.lightnessRange.bottom) / 6
        for (brighter, dimmer) in zip(lightness, lightness.dropFirst()) {
            #expect(brighter - dimmer > even / 1.5, "\(tint)")
        }
    }

    @Test func aShadeLandsOnItsLightness() {
        let amber = RetroDisplay.Tint.amber.tone
        for target in [0.55, 0.7, 0.9, 0.97] {
            #expect(abs(amber.atLightness(target).lightness - target) < 0.001)
        }
        #expect(abs(RGB.white.lightness - 1) < 0.001 && abs(RGB.black.lightness) < 0.001)
    }

    // MARK: Color

    @Test func colorKeepsEachResourcesOwnColourMadeVivid() {
        let palette = GraphPalette.retro(.color)
        let standard = GraphPalette.preset(.standard)
        #expect(palette.emphasis == .vivid)
        for role in Role.allCases {
            let vivid = PerceptualColor.lab(palette[role].tone), plain = PerceptualColor.lab(standard[role].tone)
            guard plain.chroma > 0.04 else {
                #expect(palette[role].tone == standard[role].tone, "\(role) stays grey")
                continue
            }
            let depth = plain.lightness - vivid.lightness
            #expect(abs(depth - GraphPalette.vividDepth) < 0.001 || abs(depth) < 0.001, "\(role) deeper, or as light")
            #expect(vivid.chroma >= plain.chroma - 0.001, "\(role) as vivid or more")
            #expect(abs(atan2(vivid.b, vivid.a) - atan2(plain.b, plain.a)) < 0.02, "\(role) keeps its hue")
            // Already 3:1 on the dark window, so drawn as it is there.
            #expect(palette[role].dark == palette[role].tone, "\(role)")
        }
    }

    @Test func colorChartsStayApartAndSoDoTheResources() {
        let palette = GraphPalette.retro(.color)
        let closest = GraphPaletteTests.closest(palette, vision: .typical, dark: true)
        #expect(closest.distance >= GraphPaletteTests.apart, "\(closest.pair) \(closest.distance)")
    }

    @Test func colorFollowsTheUsersOwnColours() {
        let mine = RGB(0xFF00AA)
        let palette = GraphPalette.retro(.color, base: GraphPalette.preset(.standard).overriding([.cpu: mine]))
        let lab = PerceptualColor.lab(palette[.cpu].tone), own = PerceptualColor.lab(mine)
        #expect(abs(atan2(lab.b, lab.a) - atan2(own.b, own.a)) < 0.02)
    }

    @Test func aPanelTakesATraceOfItsLight() {
        let display = RetroDisplay(style: .dotMatrix, tint: .green, glow: .soft)
        let green = display.panel(lit: RetroDisplay.Tint.green.tone)
        #expect(green.green > green.red && ColorContrast.luminance(green) < 0.01)
        let color = RetroDisplay(style: .dotMatrix, tint: .color, glow: .soft)
        #expect(color.panel == color.panel(lit: RetroDisplay.Tint.color.tone))
    }

    @Test func theMostVividColourStaysInsideSRGB() throws {
        for tone in [RGB(0x3D8FFF), RGB(0x33BD70), RGB(0xA36BF5)] {
            let lab = PerceptualColor.lab(tone)
            let vivid = PerceptualColor.mostVivid(tone, atLightness: lab.lightness)
            let back = try #require(PerceptualColor.rgb(PerceptualColor.lab(vivid)))
            #expect(abs(back.red - vivid.red) < 1e-4 && abs(back.green - vivid.green) < 1e-4 && abs(back.blue - vivid.blue) < 1e-4)
            #expect([vivid.red, vivid.green, vivid.blue].contains { $0 < 0.01 || $0 > 0.99 }, "at the gamut's edge")
        }
        let grey = RGB(red: 0.5, green: 0.5, blue: 0.5)
        #expect(PerceptualColor.mostVivid(grey, atLightness: 0.4) == grey)
    }

    // MARK: Figures

    @Test func everyDotCharacterIsSevenRowsOfOneWidth() throws {
        for character in ReadoutGlyphs.drawn {
            let rows = try #require(ReadoutGlyphs.dots(for: character))
            #expect(rows.count == ReadoutGlyphs.rows, "\(character)")
            #expect(Set(rows.map(\.count)).count == 1, "\(character)")
            #expect(rows.allSatisfy { $0.allSatisfy { $0 == "#" || $0 == "." } }, "\(character)")
            #expect(rows.contains { $0.contains("#") }, "\(character) lights something")
        }
    }

    @Test func figuresAreFiveDotsWideAndAllDifferent() {
        let digits = Array("0123456789")
        #expect(digits.allSatisfy { ReadoutGlyphs.dotColumns(for: $0) == 5 })
        let patterns = digits.compactMap { ReadoutGlyphs.dots(for: $0) }
        #expect(Set(patterns).count == digits.count)
        #expect(ReadoutGlyphs.dotColumns(for: ".") == 1)
        #expect(ReadoutGlyphs.dotColumns(for: "%") == 5)
        #expect(ReadoutGlyphs.dots(for: "M") == nil)
    }

    @Test func liveFiguresAreAllDrawn() {
        // What `GlyphCache` splits off a figure one character at a time.
        #expect(ReadoutGlyphs.drawn == Set("0123456789.,-+−%"))
        for character in ReadoutGlyphs.drawn {
            #expect(ReadoutGlyphs.segmentForm(for: character) != nil, "\(character)")
        }
    }

    @Test func titlesSpellInCapitalsAndFigures() throws {
        for character in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            let rows = try #require(ReadoutGlyphs.titleDots(for: character), "\(character)")
            #expect(rows.count == ReadoutGlyphs.rows && rows.allSatisfy { $0.count == 5 }, "\(character)")
            #expect(rows.allSatisfy { $0.allSatisfy { $0 == "#" || $0 == "." } }, "\(character)")
        }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").compactMap { ReadoutGlyphs.titleDots(for: $0) }
        // All different, though O and the figure 0 share a shape, as a plain display's do.
        #expect(Set(letters).count == 26)
        // A space, lower case and narrow marks leave a cell unlit.
        for character in " a.," as String {
            #expect(ReadoutGlyphs.titleDots(for: character) == nil, "\(character)")
        }
        // Figures' units stay type.
        #expect(!ReadoutGlyphs.drawn.contains("B"))
    }

    @Test func dotsAreReadByRowAndColumn() {
        #expect(ReadoutGlyphs.isLit("1", row: 0, column: 2))
        #expect(!ReadoutGlyphs.isLit("1", row: 0, column: 0))
        #expect(ReadoutGlyphs.isLit(".", row: 6, column: 0))
        #expect(!ReadoutGlyphs.isLit(".", row: 7, column: 0))
        #expect(!ReadoutGlyphs.isLit("7", row: 0, column: 5))
        #expect(!ReadoutGlyphs.isLit("x", row: 0, column: 0))
    }

    @Test func segmentFiguresLightTheUsualBars() {
        typealias Segments = ReadoutGlyphs.Segments
        func bars(_ character: Character) -> Segments? {
            if case .figure(let segments) = ReadoutGlyphs.segmentForm(for: character) { return segments }
            return nil
        }
        #expect(bars("8") == .all)
        #expect(bars("1") == [.upperRight, .lowerRight])
        #expect(bars("0")?.contains(.middle) == false)
        #expect(bars("-") == .middle)
        #expect(bars("−") == .middle)
        let digits = Array("0123456789").compactMap(bars)
        #expect(Set(digits).count == 10)
        #expect(ReadoutGlyphs.segmentForm(for: ".") == .point(comma: false))
        #expect(ReadoutGlyphs.segmentForm(for: ",") == .point(comma: true))
        #expect(ReadoutGlyphs.segmentForm(for: "%") == .percent)
        #expect(ReadoutGlyphs.segmentForm(for: "+") == .plus)
        #expect(ReadoutGlyphs.segmentForm(for: "G") == nil)
    }
}
