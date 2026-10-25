@testable import OTMKit
import Testing

struct SeriesSlotsTests {
    @Test func theFirstAppsTakeSlotsInRankOrder() {
        var homes = SeriesHomes<Int>()
        var slots = SeriesSlots<Int>(count: 6)
        #expect(slots.assign([10, 20, 30, 40, 50], homes: &homes) == [0, 1, 2, 3, 4])
    }

    @Test func anAppKeepsItsSlotWhenTheRankingChanges() {
        var homes = SeriesHomes<Int>()
        var slots = SeriesSlots<Int>(count: 6)
        _ = slots.assign([10, 20, 30], homes: &homes)
        #expect(slots.assign([30, 10, 20], homes: &homes) == [2, 0, 1])
        #expect(slots.assign([20, 30, 10], homes: &homes) == [1, 2, 0])
    }

    @Test func aNewcomerTakesItsHomeWhenFreeAndOtherwiseTheFirstFreeSlot() {
        var homes = SeriesHomes<Int>()
        var slots = SeriesSlots<Int>(count: 3)
        _ = slots.assign([1, 2, 3], homes: &homes)
        // 4's home is slot 0 (the fourth app of the session, round three
        // colours), which 1 still holds, so it gets slot 1, which 2 left.
        #expect(slots.assign([1, 4, 3], homes: &homes) == [0, 1, 2])
        // 5's home, slot 1, is 4's now; 1 has gone, so slot 0 is free.
        #expect(slots.assign([4, 5, 3], homes: &homes) == [1, 0, 2])
        // A new app whose home is free takes it.
        #expect(slots.assign([6, 4, 5], homes: &homes) == [2, 1, 0])
    }

    @Test func anAppThatComesBackTakesItsHomeSlot() {
        var homes = SeriesHomes<Int>()
        var slots = SeriesSlots<Int>(count: 6)
        _ = slots.assign([10, 20, 30], homes: &homes)
        _ = slots.assign([10, 30], homes: &homes)
        #expect(slots.assign([20, 10, 30], homes: &homes) == [1, 0, 2])
    }

    @Test func graphsShareHomes() {
        var homes = SeriesHomes<Int>()
        var cpu = SeriesSlots<Int>(count: 6)
        var memory = SeriesSlots<Int>(count: 6)
        #expect(cpu.assign([10, 20, 30], homes: &homes) == [0, 1, 2])
        // The memory graph ranks them differently, and each keeps its colour.
        #expect(memory.assign([30, 10, 40], homes: &homes) == [2, 0, 3])
    }

    @Test func slotsStayDistinctUpToTheCountAndThenRepeat() {
        var homes = SeriesHomes<Int>()
        var slots = SeriesSlots<Int>(count: 3)
        #expect(slots.assign([1, 2, 3, 4, 5], homes: &homes) == [0, 1, 2, 0, 1])
        // Apps held further down give way to the first three, which stay apart.
        let reordered = slots.assign([4, 5, 1, 2, 3], homes: &homes)
        #expect(Set(reordered.prefix(3)).count == 3)
        #expect(reordered.allSatisfy { (0..<3).contains($0) })
        #expect(Array(reordered.prefix(2)) == [0, 1], "4 and 5 keep the slots they had")
    }

    @Test func aRepeatedIDStillGetsASlotEachTime() {
        var homes = SeriesHomes<Int>()
        var slots = SeriesSlots<Int>(count: 3)
        let shown = slots.assign([7, 7, 8], homes: &homes)
        #expect(Set(shown).count == 3)
        #expect(slots.assign([8, 7], homes: &homes).count == 2)
    }

    @Test func theSameAppsGetTheSameAnswer() {
        var homes = SeriesHomes<Int>()
        var slots = SeriesSlots<Int>(count: 6)
        let first = slots.assign([3, 1, 2], homes: &homes)
        #expect(slots.assign([3, 1, 2], homes: &homes) == first)
    }

    @Test func homesForgetEveryAppPastTheLimit() {
        var homes = SeriesHomes<Int>(limit: 3)
        #expect([1, 2, 3].map { homes.slot(for: $0, count: 6) } == [0, 1, 2])
        #expect(homes.slot(for: 2, count: 6) == 1)
        // A fourth app clears them and starts again from slot 0.
        #expect(homes.slot(for: 4, count: 6) == 0)
        #expect(homes.slot(for: 1, count: 6) == 1)
    }
}
