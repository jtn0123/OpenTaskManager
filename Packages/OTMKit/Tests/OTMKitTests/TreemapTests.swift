import CoreGraphics
@testable import OTMKit
import Testing

private func area(_ rect: CGRect) -> Double {
    Double(rect.width * rect.height)
}

/// Every pair overlaps by no more than rounding.
private func overlaps(_ rects: [CGRect]) -> Bool {
    for first in rects.indices {
        for second in rects.indices where second > first {
            let shared = rects[first].intersection(rects[second])
            if !shared.isNull, area(shared) > 1e-6 { return true }
        }
    }
    return false
}

/// The worst width-to-height ratio, always ≥ 1.
private func aspect(_ rect: CGRect) -> Double {
    Double(max(rect.width / rect.height, rect.height / rect.width))
}

struct TreemapTests {
    /// The worked example from the squarified treemap paper.
    static let classic: [Double] = [6, 6, 4, 3, 2, 2, 1]
    static let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

    @Test func tilesFillTheBoundsExactly() {
        let rects = Treemap.squarify(Self.classic, in: Self.bounds)
        #expect(rects.count == Self.classic.count)
        let total = rects.map(area).reduce(0, +)
        #expect(abs(total - area(Self.bounds)) < 1e-6)
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        #expect(abs(union.minX - Self.bounds.minX) < 1e-9 && abs(union.minY - Self.bounds.minY) < 1e-9)
        #expect(abs(union.maxX - Self.bounds.maxX) < 1e-9 && abs(union.maxY - Self.bounds.maxY) < 1e-9)
    }

    @Test func areasAreProportionalToValues() {
        let rects = Treemap.squarify(Self.classic, in: Self.bounds)
        let perUnit = area(Self.bounds) / Self.classic.reduce(0, +)
        for (value, rect) in zip(Self.classic, rects) {
            #expect(abs(area(rect) - value * perUnit) < 1e-6 * perUnit)
        }
    }

    @Test func tilesDontOverlapAndStayInside() {
        let values = (1...60).map { Double(($0 * 37) % 23 + 1) }
        let bounds = CGRect(x: 12, y: 30, width: 517, height: 311)
        let rects = Treemap.squarify(values, in: bounds)
        #expect(!overlaps(rects))
        for rect in rects {
            #expect(rect.minX >= bounds.minX - 1e-9 && rect.maxX <= bounds.maxX + 1e-9)
            #expect(rect.minY >= bounds.minY - 1e-9 && rect.maxY <= bounds.maxY + 1e-9)
        }
    }

    @Test func largestStartsTopLeftWhateverTheInputOrder() {
        let values: [Double] = [2, 9, 1, 4, 4, 7]
        let rects = Treemap.squarify(values, in: Self.bounds)
        #expect(rects[1].origin == Self.bounds.origin)
        // Bigger values never get smaller tiles, and results come back in the input's order.
        let byValue = values.indices.sorted { values[$0] > values[$1] }
        for (larger, smaller) in zip(byValue, byValue.dropFirst()) {
            #expect(area(rects[larger]) >= area(rects[smaller]) - 1e-6)
        }
    }

    @Test func keepsTilesCloseToSquare() {
        let rects = Treemap.squarify(Self.classic, in: Self.bounds)
        #expect(rects.map(aspect).max()! < 3)
        let equal = Treemap.squarify(Array(repeating: 1, count: 100), in: CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(equal.map(aspect).max()! <= 2)
    }

    @Test func oneValueFillsEverything() {
        #expect(Treemap.squarify([42], in: Self.bounds) == [Self.bounds])
    }

    @Test func emptyAndInvalidValuesGetNoArea() {
        #expect(Treemap.squarify([], in: Self.bounds).isEmpty)
        let rects = Treemap.squarify([5, 0, -3, .nan, 5], in: Self.bounds)
        #expect(rects[1].isEmpty && rects[2].isEmpty && rects[3].isEmpty)
        #expect(abs(area(rects[0]) + area(rects[4]) - area(Self.bounds)) < 1e-6)
        #expect(Treemap.squarify([1, 2], in: .zero).allSatisfy { $0.isEmpty })
    }
}

struct LargestKeptTests {
    @Test func keepsTheLargestAndHandsBackTheRest() {
        var kept = LargestKept<String>(limit: 3)
        #expect(kept.insert("a", key: 5) == nil)
        #expect(kept.insert("b", key: 1) == nil)
        #expect(kept.insert("c", key: 9) == nil)
        // Full: a bigger one pushes out the smallest, a smaller one bounces off.
        #expect(kept.insert("d", key: 7) == "b")
        #expect(kept.insert("e", key: 2) == "e")
        #expect(!kept.accepts(5))
        #expect(kept.accepts(6))
        #expect(kept.sortedDescending() == ["c", "d", "a"])
    }

    @Test func zeroLimitKeepsNothing() {
        var kept = LargestKept<Int>(limit: 0)
        #expect(kept.insert(1, key: 100) == 1)
        #expect(kept.count == 0)
    }
}

struct TreemapLabelTests {
    @Test func headerDropsTheSizeBeforeTheName() {
        #expect(TreemapLabel.header(name: 60, size: 40, spacing: 5, room: 120) == .nameAndSize)
        #expect(TreemapLabel.header(name: 60, size: 40, spacing: 5, room: 105) == .nameAndSize)
        #expect(TreemapLabel.header(name: 60, size: 40, spacing: 5, room: 104) == .name)
        #expect(TreemapLabel.header(name: 60, size: 40, spacing: 5, room: 60) == .name)
        // "Applications" in a narrow strip: no "Ap…ns", nothing at all.
        #expect(TreemapLabel.header(name: 60, size: 40, spacing: 5, room: 59) == .none)
    }

    @Test func tileNeedsTheWholeNameAndALineForIt() {
        let line = 13.0
        #expect(TreemapLabel.tile(name: 50, size: 40, lineHeight: line, room: CGSize(width: 80, height: 30)) == .nameAndSize)
        #expect(TreemapLabel.tile(name: 50, size: 40, lineHeight: line, room: CGSize(width: 80, height: 20)) == .name,
                "no room for the second line")
        #expect(TreemapLabel.tile(name: 50, size: 60, lineHeight: line, room: CGSize(width: 55, height: 30)) == .name,
                "the size is wider than the tile")
        #expect(TreemapLabel.tile(name: 50, size: 40, lineHeight: line, room: CGSize(width: 49, height: 30)) == .none)
        #expect(TreemapLabel.tile(name: 50, size: 40, lineHeight: line, room: CGSize(width: 80, height: 12)) == .none)
    }

    @Test func shortNamesDropOnlyTheExtension() {
        #expect(TreemapLabel.shortName("Holiday-2026.mov") == "Holiday-2026")
        #expect(TreemapLabel.shortName("Sketchpad.app") == "Sketchpad")
        #expect(TreemapLabel.shortName("archive.tar.gz") == "archive.tar")
        #expect(TreemapLabel.shortName("Movies") == nil)
        #expect(TreemapLabel.shortName(".gitignore") == nil)
    }

    @Test func tileFallsBackToTheShortNameOnlyWhenItShowsMore() {
        let line = 13.0
        let room = CGSize(width: 80, height: 30)
        // The whole name fits with its size: keep it.
        #expect(TreemapLabel.tile(name: 70, shortName: 40, size: 40, lineHeight: line, room: room) == (.nameAndSize, false))
        // Too wide whole; the short one fits with the size.
        #expect(TreemapLabel.tile(name: 95, shortName: 60, size: 40, lineHeight: line, room: room) == (.nameAndSize, true))
        // Only one line of room: the whole name if it fits, the short one if only that does.
        let low = CGSize(width: 80, height: 20)
        #expect(TreemapLabel.tile(name: 70, shortName: 40, size: 40, lineHeight: line, room: low) == (.name, false))
        #expect(TreemapLabel.tile(name: 95, shortName: 60, size: 40, lineHeight: line, room: low) == (.name, true))
        // Neither fits, or there's no short form: nothing, never a cut name.
        #expect(TreemapLabel.tile(name: 95, shortName: 85, size: 40, lineHeight: line, room: room) == (.none, false))
        #expect(TreemapLabel.tile(name: 95, shortName: nil, size: 40, lineHeight: line, room: room) == (.none, false))
    }

    static let bounds = CGSize(width: 400, height: 300)
    static let tag = CGSize(width: 120, height: 40)

    @Test func tagSitsUnderItsTileWhenThereIsRoom() {
        let tile = CGRect(x: 20, y: 10, width: 100, height: 80)
        #expect(TreemapLabel.tagOrigin(size: Self.tag, tile: tile, bounds: Self.bounds) == CGPoint(x: 20, y: 96))
    }

    @Test func tagGoesAboveATileAtTheBottom() {
        let tile = CGRect(x: 20, y: 200, width: 100, height: 100)
        #expect(TreemapLabel.tagOrigin(size: Self.tag, tile: tile, bounds: Self.bounds) == CGPoint(x: 20, y: 154))
    }

    @Test func tagGoesInsideATileAsTallAsTheTreemap() {
        let tile = CGRect(x: 0, y: 0, width: 200, height: 300)
        #expect(TreemapLabel.tagOrigin(size: Self.tag, tile: tile, bounds: Self.bounds) == CGPoint(x: 6, y: 6))
    }

    @Test func tagKeepsClearOfTheHoldingFoldersName() {
        // A folder tile at the bottom, its name strip on top, with the
        // outlined item inside it just under the strip.
        let heading = CGRect(x: 0, y: 160, width: 200, height: 20)
        let inner = CGRect(x: 3, y: 180, width: 100, height: 117)
        // Above the item would cover the folder's name, so it goes over the name instead.
        #expect(TreemapLabel.tagOrigin(size: Self.tag, tile: inner, bounds: Self.bounds, heading: heading) == CGPoint(x: 3, y: 114))
        // An item further down the folder leaves room for the tag between it and the name.
        let lower = CGRect(x: 3, y: 240, width: 100, height: 57)
        #expect(TreemapLabel.tagOrigin(size: Self.tag, tile: lower, bounds: Self.bounds, heading: heading) == CGPoint(x: 3, y: 194))
        // Without the name to avoid, it sits right above the item, as before.
        #expect(TreemapLabel.tagOrigin(size: Self.tag, tile: inner, bounds: Self.bounds) == CGPoint(x: 3, y: 134))
    }

    @Test func tagInsideAFolderGoesUnderItsName() {
        // A folder as tall as the treemap: no room above or below, so the
        // tag goes inside, under the name strip rather than over it.
        let tile = CGRect(x: 0, y: 0, width: 200, height: 300)
        let heading = CGRect(x: 0, y: 0, width: 200, height: 20)
        #expect(TreemapLabel.tagOrigin(size: Self.tag, tile: tile, bounds: Self.bounds, heading: heading) == CGPoint(x: 6, y: 26))
        // An item inside it at the top: over the name there's no room either.
        let inner = CGRect(x: 3, y: 20, width: 194, height: 277)
        #expect(TreemapLabel.tagOrigin(size: Self.tag, tile: inner, bounds: Self.bounds, heading: heading) == CGPoint(x: 9, y: 26))
    }

    @Test func tagNeverPokesOutSideways() {
        let tile = CGRect(x: 360, y: 10, width: 40, height: 40)
        let origin = TreemapLabel.tagOrigin(size: Self.tag, tile: tile, bounds: Self.bounds)
        #expect(origin.x == Self.bounds.width - Self.tag.width)
        // A tag wider than the treemap starts at its left edge.
        let wide = TreemapLabel.tagOrigin(size: CGSize(width: 500, height: 40), tile: tile, bounds: Self.bounds)
        #expect(wide.x == 0)
    }
}
