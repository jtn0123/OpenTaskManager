@testable import OTMKit
import Testing

struct ColumnFitTests {
    private typealias Column = ColumnFit.Column<String>

    /// Name fills the slack from 200; PID and CPU always stay; Disk, Power
    /// and User give way in that order of importance. 590 in all.
    private let columns: [Column] = [
        Column(id: "name", width: 200, priority: nil),
        Column(id: "pid", width: 60, priority: nil),
        Column(id: "cpu", width: 70, priority: nil),
        Column(id: "power", width: 70, priority: 2),
        Column(id: "disk", width: 90, priority: 3),
        Column(id: "user", width: 100, priority: 1),
    ]

    @Test func keepsEveryColumnWhenThereIsRoom() {
        #expect(ColumnFit.hidden(columns, available: 800).isEmpty)
        #expect(ColumnFit.hidden(columns, available: 590).isEmpty)
    }

    @Test func dropsTheLowestPriorityFirst() {
        // 589 is a point short: User goes, though Power alone would have made room.
        #expect(ColumnFit.hidden(columns, available: 589) == ["user"])
        #expect(ColumnFit.hidden(columns, available: 490) == ["user"])
        #expect(ColumnFit.hidden(columns, available: 489) == ["user", "power"])
    }

    @Test func aColumnNeverOutlastsOneThatOutranksIt() {
        // Without Disk there'd be room for User again, but User ranks lower.
        #expect(ColumnFit.hidden(columns, available: 400) == ["user", "power", "disk"])
    }

    @Test func columnsThatAlwaysStayAreKeptEvenWhenTheyOverflow() {
        #expect(ColumnFit.hidden(columns, available: 330) == ["user", "power", "disk"])
        #expect(ColumnFit.hidden(columns, available: 100) == ["user", "power", "disk"])
    }

    @Test func equalPrioritiesGiveWayFromTheRight() {
        let even = [
            Column(id: "name", width: 100, priority: nil),
            Column(id: "a", width: 50, priority: 1),
            Column(id: "b", width: 50, priority: 1),
        ]
        #expect(ColumnFit.hidden(even, available: 160) == ["b"])
        #expect(ColumnFit.hidden(even, available: 140) == ["a", "b"])
    }

    @Test func minimumWidthCountsOnlyTheColumnsThatStay() {
        #expect(ColumnFit.minimumWidth(columns) == 330)
        #expect(ColumnFit.minimumWidth([Column]()) == 0)
    }

    @Test func theMinimumWidthAlwaysFitsWithoutAnythingThatGivesWay() {
        let minimum = ColumnFit.minimumWidth(columns)
        #expect(ColumnFit.hidden(columns, available: minimum) == ["user", "power", "disk"])
    }
}
