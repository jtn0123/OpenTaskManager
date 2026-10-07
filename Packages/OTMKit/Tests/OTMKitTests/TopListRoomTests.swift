import Foundation
@testable import OTMKit
import Testing

struct TopListRoomTests {
    @Test func listsOnlyFiguresThatDontReadAsZero() {
        let figures = ["3.3%", "0.6%", "0.2%", "0.0%", "0.0%", "0.0%"]
        #expect(TopListRoom.listed(figures, zero: "0.0%", limit: 6) == 3)
        #expect(TopListRoom.listed(figures, zero: "0.0%", limit: 2) == 2)
        #expect(TopListRoom.listed(["0.0%", "0.0%"], zero: "0.0%", limit: 6) == 0)
        #expect(TopListRoom.listed([String](), zero: "0 W", limit: 6) == 0)
        // Memory never reads as zero, so the list fills.
        #expect(TopListRoom.listed(["248 MB", "246 MB", "149 MB", "111 MB", "85.6 MB", "85.2 MB", "80 MB"], zero: "0 B", limit: 6) == 6)
    }

    @Test func formatsNoMoreFiguresThanItNeeds() {
        var formatted = 0
        let figures = [5.0, 1.0, 0.01, 0.0, 0.0].lazy.map { value -> String in
            formatted += 1
            return Format.fixed(value, 1) + "%"
        }
        #expect(TopListRoom.listed(figures, zero: "0.0%", limit: 6) == 2)
        // The two listed and the first that reads as zero.
        #expect(formatted == 3)
    }

    @Test func theIdleLineTakesARowUntilTheListIsFull() {
        #expect(TopListRoom.needed(listed: 0, limit: 6) == 1)
        #expect(TopListRoom.needed(listed: 2, limit: 6) == 3)
        #expect(TopListRoom.needed(listed: 5, limit: 6) == 6)
        #expect(TopListRoom.needed(listed: 6, limit: 6) == 6)
    }

    @Test func theIdleLineIsShorterThanARow() {
        // Nothing listed: the idle line alone.
        #expect(TopListRoom.height(rows: 1, limit: 6, row: 22, idleLine: 17, spacing: 4) == 17)
        #expect(TopListRoom.height(rows: 0, limit: 6, row: 22, idleLine: 17, spacing: 4) == 17)
        // Two rows and the line under them.
        #expect(TopListRoom.height(rows: 3, limit: 6, row: 22, idleLine: 17, spacing: 4) == 22 + 4 + 22 + 4 + 17)
        // A full list has no idle line.
        #expect(TopListRoom.height(rows: 6, limit: 6, row: 22, idleLine: 17, spacing: 4) == 6 * 22 + 5 * 4)
        #expect(TopListRoom.height(rows: 9, limit: 6, row: 22, idleLine: 17, spacing: 4) == 6 * 22 + 5 * 4)
        // Room held for five entries and the line is less than six rows'.
        #expect(TopListRoom.height(rows: 6, limit: 7, row: 22, idleLine: 17, spacing: 4)
            < TopListRoom.height(rows: 6, limit: 6, row: 22, idleLine: 17, spacing: 4))
    }

    @Test func growsAtOnceAndShrinksOnlyAfterTheHold() {
        var room = TopListRoom(limit: 6, hold: 30)
        #expect(room.update(listed: 2, at: 0) == 3)
        // More busy apps: room for them straight away.
        #expect(room.update(listed: 5, at: 1) == 6)
        // Fewer: the room stays while the busier sample is within the hold...
        #expect(room.update(listed: 1, at: 2) == 6)
        #expect(room.update(listed: 1, at: 30) == 6)
        // ...then shrinks to the most needed since.
        #expect(room.update(listed: 1, at: 31) == 2)
        #expect(room.rows == 2)
    }

    @Test func shrinksToTheMostNeededWithinTheHold() {
        var room = TopListRoom(limit: 6, hold: 10)
        room.update(listed: 6, at: 0)
        room.update(listed: 3, at: 5)
        room.update(listed: 1, at: 8)
        // The full list has left the hold; three listed at 5 s still count.
        #expect(room.update(listed: 1, at: 10) == 4)
        #expect(room.update(listed: 1, at: 15) == 2)
    }

    @Test func neverPassesTheLimit() {
        var room = TopListRoom(limit: 6)
        #expect(room.update(listed: 40, at: 0) == 6)
        var single = TopListRoom(limit: 0, hold: -5)
        #expect(single.limit == 1)
        #expect(single.update(listed: 3, at: 0) == 1)
    }
}
