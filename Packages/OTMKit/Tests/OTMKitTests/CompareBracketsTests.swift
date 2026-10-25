@testable import OTMKit
import Testing

struct CompareBracketsTests {
    /// A's or B's labels: letter and times, shorter times, the letter alone.
    private let labels = [110.0, 70, 16]

    @Test func labelsInsideWithTheWidestThatFits() {
        let placed = CompareBrackets.place([CompareBrackets.Bracket(lower: 300, upper: 450, labels: labels),
                                            CompareBrackets.Bracket(lower: 120, upper: 210, labels: labels)], width: 600)
        #expect(placed.map(\.label) == [0, 1])
        #expect(placed.map(\.labelX) == [306, 126])
        // Apart from each other, so both on the top row.
        #expect(placed.map(\.row) == [0, 0])
        #expect(CompareBrackets.rows(placed) == 1)
    }

    @Test func aBracketTooShortForItsTimesHasItsShortestTimesCentredOverIt() {
        let alone = CompareBrackets.place([CompareBrackets.Bracket(lower: 200, upper: 210, labels: labels)], width: 600)
        #expect(alone[0].label == 1)
        #expect(alone[0].labelX == 170)
        // The letter alone would fit within it, but the times are what it's for.
        let short = CompareBrackets.place([CompareBrackets.Bracket(lower: 200, upper: 260, labels: labels)], width: 600)
        #expect(short[0].label == 1)
        #expect(short[0].labelX == 195)
        // Kept within the lane at either end.
        let ends = CompareBrackets.place([CompareBrackets.Bracket(lower: 0, upper: 4, labels: labels),
                                          CompareBrackets.Bracket(lower: 596, upper: 600, labels: labels)], width: 600)
        #expect(ends.map(\.label) == [1, 1])
        #expect(ends.map(\.labelX) == [0, 530])
        // Between two neighbours, only as far as halfway to each, short of
        // their sides: from 108 to 127, room for the letter centred over it.
        let squeezed = CompareBrackets.place([CompareBrackets.Bracket(lower: 0, upper: 100, labels: labels),
                                              CompareBrackets.Bracket(lower: 140, upper: 300, labels: labels),
                                              CompareBrackets.Bracket(lower: 110, upper: 120, labels: labels)], width: 600)
        #expect(squeezed.map(\.row) == [0, 0, 0])
        #expect(squeezed.map(\.label) == [1, 0, 2])
        #expect(squeezed[2].labelX == 108)
        // The letter sits inside a bracket long enough for it.
        let letter = CompareBrackets.place([CompareBrackets.Bracket(lower: 0, upper: 100, labels: labels),
                                            CompareBrackets.Bracket(lower: 140, upper: 300, labels: labels),
                                            CompareBrackets.Bracket(lower: 104, upper: 136, labels: labels)], width: 600)
        #expect(letter[2].label == 2)
        #expect(letter[2].labelX == 110)
    }

    @Test func aStretchBesideTheOtherSharesItsRow() {
        // A, and B the same length just before it, meet at 300.
        let placed = CompareBrackets.place([CompareBrackets.Bracket(lower: 300, upper: 450, labels: labels),
                                            CompareBrackets.Bracket(lower: 150, upper: 300, labels: labels)], width: 600)
        #expect(placed.map(\.row) == [0, 0])
        #expect(placed.map(\.label) == [0, 0])
        #expect(placed.map(\.labelX) == [306, 156])
    }

    @Test func overlappingStretchesTakeTwoRows() {
        let placed = CompareBrackets.place([CompareBrackets.Bracket(lower: 300, upper: 450, labels: labels),
                                            CompareBrackets.Bracket(lower: 400, upper: 560, labels: labels)], width: 600)
        #expect(placed.map(\.row) == [0, 1])
        #expect(CompareBrackets.rows(placed) == 2)
    }

    @Test func aStretchWithNoRoomBesideTheOtherMovesDown() {
        // A sliver of A at the lane's end, B the same length just before it:
        // side by side, A would have no room even for its letter.
        let placed = CompareBrackets.place([CompareBrackets.Bracket(lower: 596, upper: 600, labels: labels),
                                            CompareBrackets.Bracket(lower: 592, upper: 596, labels: labels)], width: 600)
        #expect(placed.map(\.row) == [0, 1])
        // Each then has its row to itself, and its times.
        #expect(placed.map(\.label) == [1, 1])
        #expect(placed.map(\.labelX) == [530, 530])
    }

    @Test func keepsBracketsWithinTheLaneAndLongEnoughToSee() {
        let placed = CompareBrackets.place([CompareBrackets.Bracket(lower: -80, upper: 2, labels: labels),
                                            CompareBrackets.Bracket(lower: 650, upper: 500, labels: labels)], width: 600)
        #expect(placed[0].lower == 0)
        #expect(placed[0].upper == 4)
        // Ends given backwards are put in order, and cut at the lane's end.
        #expect(placed[1].lower == 500)
        #expect(placed[1].upper == 600)
        #expect(placed[1].label == 1)
        #expect(CompareBrackets.place([CompareBrackets.Bracket(lower: 10, upper: 90, labels: [])], width: 600)[0].label == 0)
    }

    @Test func dropsTheDayPeriodFromATimePattern() {
        #expect(CompareBrackets.withoutDayPeriod("h:mm a") == "h:mm")
        #expect(CompareBrackets.withoutDayPeriod("h:mm\u{202F}a") == "h:mm")
        #expect(CompareBrackets.withoutDayPeriod("a h:mm") == "h:mm")
        #expect(CompareBrackets.withoutDayPeriod("Bh:mm") == "h:mm")
        #expect(CompareBrackets.withoutDayPeriod("h:mm:ss a") == "h:mm:ss")
        #expect(CompareBrackets.withoutDayPeriod("HH:mm") == "HH:mm")
        // Quoted text stays.
        #expect(CompareBrackets.withoutDayPeriod("HH 'a' mm") == "HH 'a' mm")
    }
}
