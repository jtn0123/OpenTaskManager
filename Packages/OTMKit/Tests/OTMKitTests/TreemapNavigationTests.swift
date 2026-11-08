import CoreGraphics
@testable import OTMKit
import Testing

struct TreemapNavigationTests {
    private let grid = [
        TreemapNavigation.Tile(id: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
        TreemapNavigation.Tile(id: 2, rect: CGRect(x: 100, y: 0, width: 100, height: 100)),
        TreemapNavigation.Tile(id: 3, rect: CGRect(x: 0, y: 100, width: 100, height: 100)),
        TreemapNavigation.Tile(id: 4, rect: CGRect(x: 100, y: 100, width: 100, height: 100)),
    ]

    @Test func followsAllFourDirections() {
        #expect(TreemapNavigation.next(from: 1, direction: .right, tiles: grid) == 2)
        #expect(TreemapNavigation.next(from: 2, direction: .left, tiles: grid) == 1)
        #expect(TreemapNavigation.next(from: 1, direction: .down, tiles: grid) == 3)
        #expect(TreemapNavigation.next(from: 3, direction: .up, tiles: grid) == 1)
    }

    @Test func edgesKeepTheSelectionAndMissingSelectionsStartAtTheFirstTile() {
        #expect(TreemapNavigation.next(from: 1, direction: .left, tiles: grid) == 1)
        #expect(TreemapNavigation.next(from: 4, direction: .down, tiles: grid) == 4)
        #expect(TreemapNavigation.next(from: nil, direction: .right, tiles: grid) == 1)
        #expect(TreemapNavigation.next(from: 99, direction: .up, tiles: grid) == 1)
        #expect(TreemapNavigation.next(from: nil, direction: .down, tiles: []) == nil)
    }

    @Test func prefersAnAlignedNeighbourOverADiagonalOne() {
        let tiles = [
            TreemapNavigation.Tile(id: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            TreemapNavigation.Tile(id: 2, rect: CGRect(x: 12, y: 15, width: 5, height: 5)),
            TreemapNavigation.Tile(id: 3, rect: CGRect(x: 30, y: 0, width: 5, height: 10)),
        ]
        #expect(TreemapNavigation.next(from: 1, direction: .right, tiles: tiles) == 3)
        #expect(TreemapNavigation.next(from: 1, direction: .down, tiles: tiles) == 2)
    }

    @Test func subpixelTilesRemainReachableWithoutGrowingThem() {
        let tiles = [
            TreemapNavigation.Tile(id: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 10)),
            TreemapNavigation.Tile(id: 2, rect: CGRect(x: 100, y: 0, width: 0.1, height: 10)),
            TreemapNavigation.Tile(id: 3, rect: CGRect(x: 100.1, y: 0, width: 0.2, height: 10)),
        ]
        #expect(TreemapNavigation.next(from: 1, direction: .right, tiles: tiles) == 2)
        #expect(TreemapNavigation.next(from: 2, direction: .right, tiles: tiles) == 3)
        #expect(TreemapNavigation.next(from: 3, direction: .left, tiles: tiles) == 2)
    }

    @Test func tiesKeepLayoutOrderAndInvalidRegionsAreIgnored() {
        let tiles = [
            TreemapNavigation.Tile(id: 0, rect: .zero),
            TreemapNavigation.Tile(id: 1, rect: CGRect(x: 0, y: 10, width: 10, height: 10)),
            TreemapNavigation.Tile(id: 2, rect: CGRect(x: 10, y: 0, width: 10, height: 10)),
            TreemapNavigation.Tile(id: 3, rect: CGRect(x: 10, y: 20, width: 10, height: 10)),
            TreemapNavigation.Tile(id: 4, rect: .infinite),
        ]
        #expect(TreemapNavigation.next(from: nil, direction: .down, tiles: tiles) == 1)
        #expect(TreemapNavigation.next(from: 1, direction: .right, tiles: tiles) == 2)
    }

    @Test func usesTheNewGeometryAfterAResize() {
        let resized = [grid[0], TreemapNavigation.Tile(id: 2, rect: CGRect(x: 0, y: 100, width: 100, height: 100))]
        #expect(TreemapNavigation.next(from: 1, direction: .right, tiles: resized) == 1)
        #expect(TreemapNavigation.next(from: 1, direction: .down, tiles: resized) == 2)
    }

    @Test func reachesInnerTilesFromTheirFoldersHeader() {
        let tiles = [
            TreemapNavigation.Tile(id: 1, rect: CGRect(x: 0, y: 0, width: 200, height: 20)),
            TreemapNavigation.Tile(id: 2, rect: CGRect(x: 0, y: 20, width: 199.9, height: 80)),
            TreemapNavigation.Tile(id: 3, rect: CGRect(x: 199.9, y: 20, width: 0.1, height: 80)),
        ]
        #expect(TreemapNavigation.next(from: 1, direction: .down, tiles: tiles) == 2)
        #expect(TreemapNavigation.next(from: 2, direction: .right, tiles: tiles) == 3)
        #expect(TreemapNavigation.next(from: 3, direction: .up, tiles: tiles) == 1)
    }
}
