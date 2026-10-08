@testable import OTMKit
import Testing

struct CoreAreaGridTests {
    /// The CPU page's main graph area in a 1180-point window.
    private func grid(_ count: Int, groups: [Int] = [], width: Double = 652, height: Double = 465) -> CoreAreaGrid {
        CoreAreaGrid.best(count: count, width: width, height: height, groups: groups)
    }

    @Test func eighteenCoresAreSixByThree() {
        #expect(grid(18, groups: [12, 6]) == CoreAreaGrid(columns: 6, rows: 3))
        // In an 820-point window too, rather than a row of strips.
        #expect(grid(18, groups: [12, 6], width: 546) == CoreAreaGrid(columns: 6, rows: 3))
    }

    @Test func sixCoresAreThreeByTwo() {
        #expect(grid(6) == CoreAreaGrid(columns: 3, rows: 2))
    }

    @Test func commonChipsFillTheirGrid() {
        #expect(grid(8, groups: [4, 4]) == CoreAreaGrid(columns: 4, rows: 2))
        #expect(grid(12, groups: [8, 4]) == CoreAreaGrid(columns: 4, rows: 3))
        #expect(grid(10, groups: [8, 2]) == CoreAreaGrid(columns: 5, rows: 2))
        #expect(grid(14, groups: [10, 4]) == CoreAreaGrid(columns: 5, rows: 3))
        #expect(grid(24, groups: [16, 8]) == CoreAreaGrid(columns: 6, rows: 4))
        #expect(grid(32, groups: [24, 8]) == CoreAreaGrid(columns: 8, rows: 4))
    }

    @Test func fewCoresStaySideBySide() {
        #expect(grid(2) == CoreAreaGrid(columns: 2, rows: 1))
        #expect(grid(4) == CoreAreaGrid(columns: 2, rows: 2))
        #expect(grid(1) == CoreAreaGrid(columns: 1, rows: 1))
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
            #expect(CoreAreaGrid.usableAspects.contains(tile.width / tile.height), "\(count) cores")
        }
    }

    @Test func noRoomStillGivesAGrid() {
        #expect(grid(6, width: 0, height: 0) == CoreAreaGrid(columns: 6, rows: 1))
        #expect(CoreAreaGrid(columns: 0, rows: 0) == CoreAreaGrid(columns: 1, rows: 1))
    }

    @Test func tileSizeLeavesTheSpacing() {
        let tile = CoreAreaGrid(columns: 6, rows: 3).tileSize(width: 652, height: 465, spacing: 6)
        #expect(tile.width == (652 - 30) / 6.0)
        #expect(tile.height == (465 - 12) / 3.0)
    }

    @Test func gridGrowsToKeepTilesReadable() {
        let layout = CoreAreaGrid(columns: 6, rows: 3)
        #expect(layout.height(atLeast: 465, minimumTile: 56) == 465)
        #expect(layout.height(atLeast: 100, minimumTile: 56) == 3 * 56 + 2 * 6)
    }
}
