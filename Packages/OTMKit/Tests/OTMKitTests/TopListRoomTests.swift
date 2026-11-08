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

    @Test func theRoomHoldsItsRowsLessTheIdleLine() {
        #expect(TopListRoom.entries(rows: 3, limit: 6) == 2)
        #expect(TopListRoom.entries(rows: 1, limit: 6) == 0)
        #expect(TopListRoom.entries(rows: 0, limit: 6) == 0)
        #expect(TopListRoom.entries(rows: 6, limit: 6) == 6)
        // The room a list needs holds it: five entries and the idle line fill
        // the six rows a full list takes.
        for listed in 0...6 {
            #expect(TopListRoom.entries(rows: TopListRoom.needed(listed: listed, limit: 6), limit: 6) == (listed == 5 ? 6 : listed))
        }
    }

    @Test func growsForRowsThatLastAndShrinksOnlyAfterTheHold() {
        var room = TopListRoom(limit: 6, hold: 30)
        // The first update takes its room at once.
        #expect(room.update(listed: 2, at: 0) == 2)
        #expect(room.rows == 3)
        // More busy apps: rows and room for them once a second update has them too.
        #expect(room.update(listed: 5, at: 1) == 2)
        #expect(room.rows == 3)
        #expect(room.update(listed: 5, at: 2) == 5)
        #expect(room.rows == 6)
        // Fewer: the room stays while the busier updates are within the hold...
        #expect(room.update(listed: 1, at: 3) == 1)
        #expect(room.update(listed: 1, at: 31) == 1)
        #expect(room.rows == 6)
        // ...then shrinks to the most needed since.
        #expect(room.update(listed: 1, at: 32) == 1)
        #expect(room.rows == 2)
        #expect(room.shown == 1)
    }

    @Test func anEntryBusyForOneUpdateGetsNeitherARowNorRoom() {
        var room = TopListRoom(limit: 6, hold: 30)
        room.update(listed: 2, at: 0)
        // A third app busy for one update, then idle again: the card stays as it was.
        #expect(room.update(listed: 3, at: 1) == 2)
        #expect(room.update(listed: 2, at: 2) == 2)
        #expect(room.rows == 3)
        // Apps that flicker in every other update never last two.
        for time in 3...12 {
            #expect(room.update(listed: time.isMultiple(of: 2) ? 2 : 4, at: Double(time)) == 2)
        }
        #expect(room.rows == 3)
        // Two that stay busy get their rows on the second update...
        #expect(room.update(listed: 4, at: 13) == 2)
        #expect(room.update(listed: 4, at: 14) == 4)
        #expect(room.rows == 5)
        // ...and within the room kept for them, rows show at once.
        #expect(room.update(listed: 1, at: 15) == 1)
        #expect(room.update(listed: 4, at: 16) == 4)
    }

    @Test func drawingTheSameSampleAgainIsntAnotherUpdate() {
        var room = TopListRoom(limit: 6, hold: 30)
        room.update(listed: 1, at: 0)
        // The card's body runs twice for the sample taken at 1 s: one update still.
        #expect(room.update(listed: 4, at: 1) == 1)
        #expect(room.update(listed: 4, at: 1) == 1)
        #expect(room.rows == 2)
        #expect(room.update(listed: 4, at: 2) == 4)
    }

    @Test func aClockThatGoesBackStartsOver() {
        var room = TopListRoom(limit: 6, hold: 30)
        room.update(listed: 5, at: 100)
        #expect(room.update(listed: 1, at: 50) == 1)
        #expect(room.rows == 2)
    }

    @Test func shrinksToTheMostNeededWithinTheHold() {
        var room = TopListRoom(limit: 6, hold: 10)
        room.update(listed: 6, at: 0)
        room.update(listed: 3, at: 5)
        room.update(listed: 1, at: 8)
        // The full list has left the hold; three listed at 5 s still count.
        room.update(listed: 1, at: 10)
        #expect(room.rows == 4)
        room.update(listed: 1, at: 15)
        #expect(room.rows == 2)
    }

    @Test func neverPassesTheLimit() {
        var room = TopListRoom(limit: 6)
        #expect(room.update(listed: 40, at: 0) == 6)
        #expect(room.rows == 6)
        var single = TopListRoom(limit: 0, hold: -5)
        #expect(single.limit == 1)
        #expect(single.update(listed: 3, at: 0) == 1)
        #expect(single.rows == 1)
    }
}
