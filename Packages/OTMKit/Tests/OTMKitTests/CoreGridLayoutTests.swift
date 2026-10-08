@testable import OTMKit
import Testing

struct CoreGridLayoutTests {
    /// The CPU page's main graph area in a 1180-point window.
    private func grid(_ count: Int, groups: [Int] = [], width: Double = 652, height: Double = 465) -> CoreGridLayout {
        CoreGridLayout.best(count: count, width: width, height: height, groups: groups)
    }

    @Test func eighteenCoresAreSixByThree() {
        #expect(grid(18, groups: [12, 6]) == CoreGridLayout(columns: 6, rows: 3))
        // In an 820-point window too, rather than a row of strips.
        #expect(grid(18, groups: [12, 6], width: 546) == CoreGridLayout(columns: 6, rows: 3))
    }

    @Test func sixCoresAreThreeByTwo() {
        #expect(grid(6) == CoreGridLayout(columns: 3, rows: 2))
    }

    @Test func commonChipsFillTheirGrid() {
        #expect(grid(8, groups: [4, 4]) == CoreGridLayout(columns: 4, rows: 2))
        #expect(grid(12, groups: [8, 4]) == CoreGridLayout(columns: 4, rows: 3))
        #expect(grid(10, groups: [8, 2]) == CoreGridLayout(columns: 5, rows: 2))
        #expect(grid(14, groups: [10, 4]) == CoreGridLayout(columns: 5, rows: 3))
        #expect(grid(24, groups: [16, 8]) == CoreGridLayout(columns: 6, rows: 4))
        #expect(grid(32, groups: [24, 8]) == CoreGridLayout(columns: 8, rows: 4))
    }

    @Test func fewCoresStaySideBySide() {
        #expect(grid(2) == CoreGridLayout(columns: 2, rows: 1))
        #expect(grid(4) == CoreGridLayout(columns: 2, rows: 2))
        #expect(grid(1) == CoreGridLayout(columns: 1, rows: 1))
    }

    @Test func noEmptyCellsWhenAnEvenGridFits() {
        for count in [4, 6, 8, 10, 12, 16, 18, 20, 24] {
            #expect(grid(count).emptyCells(count: count) == 0, "\(count) cores")
        }
    }

    @Test func tilesKeepAUsableShape() {
        for count in 2...32 {
            let layout = grid(count)
            let tile = layout.tileSize(width: 652, height: 465)
            #expect(CoreGridLayout.usableAspects.contains(tile.width / tile.height), "\(count) cores")
        }
    }

    @Test func noRoomStillGivesAGrid() {
        #expect(grid(6, width: 0, height: 0) == CoreGridLayout(columns: 6, rows: 1))
        #expect(CoreGridLayout(columns: 0, rows: 0) == CoreGridLayout(columns: 1, rows: 1))
    }

    @Test func tileSizeLeavesTheSpacing() {
        let tile = CoreGridLayout(columns: 6, rows: 3).tileSize(width: 652, height: 465, spacing: 6)
        #expect(tile.width == (652 - 30) / 6.0)
        #expect(tile.height == (465 - 12) / 3.0)
    }

    @Test func gridGrowsToKeepTilesReadable() {
        let layout = CoreGridLayout(columns: 6, rows: 3)
        #expect(layout.height(atLeast: 465, minimumTile: 56) == 465)
        #expect(layout.height(atLeast: 100, minimumTile: 56) == 3 * 56 + 2 * 6)
    }
}

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
