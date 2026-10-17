import Foundation
@testable import OTMKit
import Testing

struct RetroDisplayTests {
    typealias RGB = ColorContrast.RGB
    typealias Role = GraphPalette.Role

    // MARK: Palette

    /// Live graphs draw on the dark panel whatever the appearance, so it's
    /// the dark shades that share a chart there; lines that share one still
    /// differ by depth and a turn of hue, not only by dashes. One display
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
        #expect(palette.emphasis == .retro)
    }

    @Test(arguments: RetroDisplay.Tint.allCases)
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

    @Test func thePanelIsNearlyBlack() {
        for tint in RetroDisplay.Tint.allCases {
            let panel = RetroDisplay(style: .dotMatrix, tint: tint, glow: .soft).panel
            #expect(ColorContrast.luminance(panel) < 0.01)
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

    // MARK: Hue

    @Test func turningMovesTheHueAndKeepsTheRest() {
        let red = RGB(red: 1, green: 0, blue: 0)
        let green = red.turned(by: 120)
        #expect(abs(green.red) < 1e-9 && abs(green.green - 1) < 1e-9 && abs(green.blue) < 1e-9)
        let amber = RetroDisplay.Tint.amber.tone
        let round = amber.turned(by: 360)
        #expect(abs(round.red - amber.red) < 1e-9 && abs(round.green - amber.green) < 1e-9 && abs(round.blue - amber.blue) < 1e-9)
        let back = amber.turned(by: 40).turned(by: -40)
        #expect(abs(back.red - amber.red) < 1e-9 && abs(back.green - amber.green) < 1e-9 && abs(back.blue - amber.blue) < 1e-9)
        let grey = RGB(red: 0.5, green: 0.5, blue: 0.5)
        #expect(grey.turned(by: 90) == grey)
    }

    @Test func aGreyWarmsAndCoolsByMixing() {
        let white = RetroDisplay.Tint.white.tone
        let warm = white.warmed(true), cool = white.warmed(false)
        #expect(warm.red > warm.blue)
        #expect(cool.blue > cool.red)
        #expect(OKLab.distance(warm, cool) > 0.05)
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
