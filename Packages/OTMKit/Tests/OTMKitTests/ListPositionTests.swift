@testable import OTMKit
import Testing

struct ListPositionTests {
    private let ids = ["a", "b", "c", "d"]

    @Test func findsTheNeighboursInTheMiddle() throws {
        let position = try #require(ListPosition(of: "c", in: ids))
        #expect(position.number == 3)
        #expect(position.count == 4)
        #expect(position.previous == "b")
        #expect(position.next == "d")
    }

    @Test func stopsAtBothEnds() throws {
        let first = try #require(ListPosition(of: "a", in: ids))
        #expect(first.number == 1)
        #expect(first.previous == nil)
        #expect(first.next == "b")
        let last = try #require(ListPosition(of: "d", in: ids))
        #expect(last.number == 4)
        #expect(last.previous == "c")
        #expect(last.next == nil)
    }

    @Test func aListOfOneHasNowhereToGo() throws {
        let only = try #require(ListPosition(of: "a", in: ["a"]))
        #expect(only.number == 1)
        #expect(only.count == 1)
        #expect(only.previous == nil)
        #expect(only.next == nil)
    }

    @Test func anItemTheListDoesNotShowHasNoPosition() {
        #expect(ListPosition(of: "z", in: ids) == nil)
        #expect(ListPosition(of: "a", in: [String]()) == nil)
    }

    @Test func theFirstOfRepeatsCounts() throws {
        let position = try #require(ListPosition(of: "b", in: ["a", "b", "c", "b"]))
        #expect(position.number == 2)
        #expect(position.next == "c")
    }
}
