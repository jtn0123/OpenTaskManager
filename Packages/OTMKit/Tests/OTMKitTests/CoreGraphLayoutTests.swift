import Foundation
@testable import OTMKit
import Testing

struct CoreGraphLayoutTests {
    @Test(arguments: [546.0, 652.0])
    func defaultEighteenCoreTilesLeaveRoomForFigures(_ width: Double) {
        let layout = CoreGraphLayout(count: 18, width: width, availableHeight: 465, larger: false, groups: [12, 6])
        #expect(layout.grid == CoreAreaGrid(columns: 6, rows: 3))
        #expect(layout.height == 365)
        #expect(layout.grid.tileSize(width: width, height: layout.height).height == (365 - 12) / 3.0)
    }

    @Test(arguments: [2, 4, 6, 8, 10, 12, 18, 24, 32])
    func defaultCellsAreCappedWithoutLosingCores(_ count: Int) {
        let layout = CoreGraphLayout(count: count, width: 652, availableHeight: 465, larger: false)
        let tile = layout.grid.tileSize(width: 652, height: layout.height)
        #expect(tile.height <= 130)
        #expect(tile.height >= 64)
        #expect(layout.grid.rows * layout.grid.columns >= count)
        #expect(layout.height <= 365)
    }

    @Test func largerChoiceKeepsTheOriginalArea() {
        let compact = CoreGraphLayout(count: 8, width: 652, availableHeight: 465, larger: false, groups: [4, 4])
        let larger = CoreGraphLayout(count: 8, width: 652, availableHeight: 465, larger: true, groups: [4, 4])
        #expect(compact.height == 266)
        #expect(larger.height == 465)
        #expect(compact.grid == larger.grid)
    }

    @Test func spareRoomAllowsTallerTiles() {
        let layout = CoreGraphLayout(count: 8, width: 652, availableHeight: 860, larger: false, groups: [4, 4])
        #expect(layout.grid.tileSize(width: 652, height: layout.height).height <= 180)
        #expect(layout.height < 860)
    }

    @Test func missingOrShortProposalsKeepTilesReadable() {
        for height in [0.0, 30, .infinity, .nan] {
            let layout = CoreGraphLayout(count: 18, width: 0, availableHeight: height, larger: false)
            #expect(layout.height.isFinite)
            #expect(layout.grid.tileSize(width: 600, height: layout.height).height >= 64)
        }
    }
}
