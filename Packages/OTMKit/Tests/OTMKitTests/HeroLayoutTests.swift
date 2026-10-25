@testable import OTMKit
import Testing

struct HeroHeightTests {
    @Test func fillsThePaneLessWhatShowsAroundIt() {
        #expect(HeroHeight.graph(visible: 708, reserved: 243) == 465)
    }

    @Test func staysWithinItsBounds() {
        #expect(HeroHeight.graph(visible: 300, reserved: 243) == HeroHeight.minimum)
        #expect(HeroHeight.graph(visible: 2000, reserved: 100) == HeroHeight.maximum)
        #expect(HeroHeight.graph(visible: 0, reserved: 100) == HeroHeight.minimum)
        #expect(HeroHeight.graph(visible: .infinity, reserved: 100) == HeroHeight.minimum)
    }
}

struct LevelSegmentsTests {
    @Test func segmentsFillTheWidth() {
        // 7.5 points a segment, the last without its gap.
        #expect(LevelSegments.count(width: 300) == 40)
        #expect(LevelSegments.count(width: 297.5) == 40)
        #expect(LevelSegments.count(width: 297) == 39)
    }

    @Test func neverFewerThanTen() {
        #expect(LevelSegments.count(width: 20) == 10)
        #expect(LevelSegments.count(width: 0) == 10)
        #expect(LevelSegments.count(width: .nan) == 10)
    }

    @Test func aLightLoadStillLightsOne() {
        #expect(LevelSegments.lit(0.001, of: 40) == 1)
        #expect(LevelSegments.lit(0, of: 40) == 0)
        #expect(LevelSegments.lit(-1, of: 40) == 0)
        #expect(LevelSegments.lit(.nan, of: 40) == 0)
    }

    @Test func onlyAFullReadingLightsAll() {
        #expect(LevelSegments.lit(0.999, of: 40) == 39)
        #expect(LevelSegments.lit(1, of: 40) == 40)
        #expect(LevelSegments.lit(3, of: 40) == 40)
        #expect(LevelSegments.lit(0.5, of: 40) == 20)
    }
}

struct ThermalLevelTests {
    @Test func levelsStepEvenlyToCritical() {
        #expect(ThermalState.nominal.level == 0)
        #expect(ThermalState.fair.level < ThermalState.serious.level)
        #expect(ThermalState.critical.level == 1)
    }
}

struct FigureColumnsTests {
    @Test func asManyAsFitNeverMoreThanTheFigures() {
        // 128-point figures 16 apart: 4 fit in 560, each 128 wide.
        let four = FigureColumns.fit(width: 560, count: 8, minimum: 128, spacing: 16)
        #expect(four.count == 4)
        #expect(four.width == 128)
        #expect(FigureColumns.fit(width: 560, count: 3, minimum: 128, spacing: 16).count == 3)
        #expect(FigureColumns.fit(width: 100, count: 3, minimum: 128, spacing: 16).count == 1)
    }

    @Test func aShortRowKeepsAFullRowsWidths() {
        // Two figures in room for four keep a quarter each, not a half.
        let short = FigureColumns.fit(width: 560, count: 2, minimum: 128, spacing: 16)
        #expect(short.count == 2)
        #expect(short.width == 128)
    }

    @Test func anUnboundedWidthTakesTheIdeal() {
        let ideal = FigureColumns.idealWidth(count: 5, minimum: 128, spacing: 16)
        #expect(ideal == 704)
        #expect(FigureColumns.fit(width: .infinity, count: 5, minimum: 128, spacing: 16).count == 5)
        #expect(FigureColumns.fit(width: .nan, count: 5, minimum: 128, spacing: 16).count == 5)
        #expect(FigureColumns.fit(width: -10, count: 5, minimum: 128, spacing: 16).width == 128)
        #expect(FigureColumns.fit(width: .infinity, count: 0, minimum: 128, spacing: 16).count == 1)
    }
}

struct FineGridSpacingTests {
    @Test func rowsSplitThePlotBetweenItsInsets() {
        #expect(FineGridSpacing.row(height: 400, inset: 4, rows: 8) == 49)
        #expect(FineGridSpacing.row(height: 6, inset: 4, rows: 8) == 0)
        #expect(FineGridSpacing.row(height: 400, inset: 4, rows: 0) == 0)
        #expect(FineGridSpacing.row(height: .nan, inset: 4, rows: 8) == 0)
    }

    @Test func columnsAreAboutAsFarApartAsTheRows() {
        // Rows 48 points apart over samples 8 apart: a column every 6 samples.
        #expect(FineGridSpacing.columnSamples(rowStep: 48, sampleStep: 8) == 6)
        // A long window's samples half a point apart: every 96.
        #expect(FineGridSpacing.columnSamples(rowStep: 48, sampleStep: 0.5) == 96)
        // Samples wider than a row: every one.
        #expect(FineGridSpacing.columnSamples(rowStep: 48, sampleStep: 100) == 1)
    }

    @Test func columnsNeverCloserThanTheMinimum() {
        // Rows 5 apart would crowd the columns: 12 points is 6 samples of 2.
        #expect(FineGridSpacing.columnSamples(rowStep: 5, sampleStep: 2) == 6)
        // No rows at all: still 12 points, rounded up to whole samples.
        #expect(FineGridSpacing.columnSamples(rowStep: 0, sampleStep: 5) == 3)
    }

    @Test func anUnusableStepGivesEverySample() {
        #expect(FineGridSpacing.columnSamples(rowStep: 48, sampleStep: 0) == 1)
        #expect(FineGridSpacing.columnSamples(rowStep: 48, sampleStep: .nan) == 1)
        #expect(FineGridSpacing.columnSamples(rowStep: .infinity, sampleStep: 4) == 3)
    }
}
