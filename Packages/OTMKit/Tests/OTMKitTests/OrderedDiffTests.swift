@testable import OTMKit
import Testing

struct OrderedDiffTests {
    @Test func identicalListsNeedNothing() {
        #expect(OrderedDiff.changes(from: [1, 2, 3], to: [1, 2, 3]).isEmpty)
    }

    @Test func singleMoveForOneRisingRow() {
        let changes = OrderedDiff.changes(from: [1, 2, 3, 4], to: [4, 1, 2, 3])
        #expect(changes == .init(removals: [], steps: [.move(from: 3, to: 0)]))
    }

    @Test func singleMoveForOneSinkingRow() {
        let changes = OrderedDiff.changes(from: [1, 2, 3, 4, 5, 6], to: [2, 3, 4, 5, 6, 1])
        #expect(changes.steps.count == 1)
        #expect(OrderedDiff.apply(changes, to: [1, 2, 3, 4, 5, 6], insertingFrom: [2, 3, 4, 5, 6, 1]) == [2, 3, 4, 5, 6, 1])
    }

    @Test func movesAreBoundedByTwicePerDisplacedRow() {
        // Two rows swap places across a long list; everything else stays.
        let old = Array(0..<100)
        var new = old
        new.swapAt(3, 80)
        #expect(OrderedDiff.changes(from: old, to: new).steps.count <= 4)
    }

    @Test func longestIncreasingSubsequence() {
        #expect(OrderedDiff.longestIncreasingSubsequence([]) == [])
        #expect(OrderedDiff.longestIncreasingSubsequence([3, 1, 2, 5, 4]).count == 3)
        #expect(OrderedDiff.longestIncreasingSubsequence([5, 4, 3]).count == 1)
    }

    @Test func removalsComeFirstThenInserts() {
        let changes = OrderedDiff.changes(from: [1, 2, 3], to: [1, 9, 3])
        #expect(changes == .init(removals: [1], steps: [.insert(at: 1)]))
    }

    @Test(arguments: [
        ([Int](), [1, 2]),
        ([1, 2], []),
        ([1, 2, 3, 4, 5], [5, 4, 3, 2, 1]),
        ([1, 2, 3, 4], [2, 3, 4, 1]),
        ([1, 2, 3, 4, 5, 6], [7, 6, 2, 8, 1]),
        ([10, 20, 30], [30, 40, 10, 50, 20]),
    ])
    func replayingTheChangesGivesTheNewOrder(old: [Int], new: [Int]) {
        let changes = OrderedDiff.changes(from: old, to: new)
        #expect(OrderedDiff.apply(changes, to: old, insertingFrom: new) == new)
    }

    @Test func randomReorderingsReplayCorrectly() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let old = Array((0..<Int.random(in: 0...30, using: &generator)).shuffled(using: &generator))
            let survivors = old.filter { _ in Bool.random(using: &generator) }
            let new = (survivors + (100..<(100 + Int.random(in: 0...5, using: &generator)))).shuffled(using: &generator)
            let changes = OrderedDiff.changes(from: old, to: new)
            #expect(OrderedDiff.apply(changes, to: old, insertingFrom: new) == new)
        }
    }
}
