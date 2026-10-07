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
