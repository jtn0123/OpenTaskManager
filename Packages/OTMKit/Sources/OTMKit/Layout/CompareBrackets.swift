import Foundation

/// Where the History page's compare lane draws the A and B brackets over its
/// timeline, and which of each one's labels it shows.
///
/// Brackets are placed in order, A first, each on the first row where it
/// runs into none placed before (brackets that only touch, as A and the
/// same length before it do, share a row) and where every bracket on that
/// row still has room for its last label. Its labels run widest first: the
/// letter with the start and end times, then shorter forms, and last the
/// letter alone. A bracket wears the widest with times that fits within it,
/// just inside its start. One too short for any wears its shortest with
/// times centred over it, if that fits its room (its share of its row: up
/// to halfway to its neighbours and short of their sides by half the inset,
/// or to the lane's ends), so the times still show; failing that, the
/// letter alone.
public enum CompareBrackets {
    /// A stretch to bracket, across the lane in points.
    public struct Bracket: Sendable, Equatable {
        public let lower: Double
        public let upper: Double
        /// Its labels' widths, widest first.
        public let labels: [Double]

        public init(lower: Double, upper: Double, labels: [Double]) {
            self.lower = min(lower, upper)
            self.upper = max(lower, upper)
            self.labels = labels
        }
    }

    public struct Placement: Sendable, Equatable {
        /// The bracket's ends, kept within the lane and at least `minimumLength` apart.
        public let lower: Double
        public let upper: Double
        /// Which of its labels shows.
        public let label: Int
        /// Where that label's leading edge sits.
        public let labelX: Double
        /// 0 for the top row, then 1, 2.
        public let row: Int
    }

    /// How far two brackets may overlap and still share a row: a shared edge.
    static let touching = 1.0

    /// Places `brackets` across a lane `width` points wide; see the type's notes.
    public static func place(_ brackets: [Bracket], width: Double, inset: Double = 6, minimumLength: Double = 4) -> [Placement] {
        let lane = Lane(spans: brackets.map { bracket in
            var lower = min(max(bracket.lower, 0), width)
            var upper = min(max(bracket.upper, 0), width)
            if upper - lower < minimumLength {
                upper = min(lower + minimumLength, width)
                lower = max(upper - minimumLength, 0)
            }
            return lower...upper
        }, letters: brackets.map { $0.labels.last ?? 0 }, width: width, inset: inset)
        var rows: [Int] = []
        for index in brackets.indices {
            var row = 0
            while !lane.fits(index, onRow: row, rows: rows) {
                row += 1
            }
            rows.append(row)
        }
        return brackets.indices.map { index in
            let span = lane.spans[index]
            let room = lane.room(index, rows: rows)
            let labels = brackets[index].labels
            let fitsInside = { (labelWidth: Double) in labelWidth + 2 * inset <= span.upperBound - span.lowerBound }
            // All but the last, which is the letter alone.
            let times = labels.indices.dropLast()
            let label = if let widest = times.first(where: { fitsInside(labels[$0]) }) {
                widest
            } else if let shortest = times.last, labels[shortest] <= room.upperBound - room.lowerBound {
                shortest
            } else {
                max(labels.count - 1, 0)
            }
            let labelWidth = labels.indices.contains(label) ? labels[label] : 0
            let labelX = if fitsInside(labelWidth) {
                span.lowerBound + inset
            } else {
                min(max((span.lowerBound + span.upperBound - labelWidth) / 2, room.lowerBound),
                    max(room.upperBound - labelWidth, room.lowerBound))
            }
            return Placement(lower: span.lowerBound, upper: span.upperBound, label: label, labelX: labelX, row: rows[index])
        }
    }

    /// How many rows `placements` take: at least one.
    public static func rows(_ placements: [Placement]) -> Int {
        (placements.map(\.row).max() ?? 0) + 1
    }

    /// The brackets' ends once kept within the lane, and their last labels' widths.
    private struct Lane {
        let spans: [ClosedRange<Double>]
        let letters: [Double]
        let width: Double
        let inset: Double

        /// Whether the bracket at `index` can join `row`, given those before
        /// it in `rows`: an empty row always takes it.
        func fits(_ index: Int, onRow row: Int, rows: [Int]) -> Bool {
            let others = rows.indices.filter { rows[$0] == row }
            if others.isEmpty { return true }
            if others.contains(where: { overlap(spans[$0], spans[index]) > touching }) { return false }
            let trial = rows + [row]
            return (others + [index]).allSatisfy { member in
                let room = room(member, rows: trial)
                return room.upperBound - room.lowerBound >= letters[member]
            }
        }

        /// The share of its row the bracket at `index` may label within.
        func room(_ index: Int, rows: [Int]) -> ClosedRange<Double> {
            let span = spans[index]
            let neighbours = rows.indices.filter { $0 != index && rows[$0] == rows[index] }.map { spans[$0] }
            let before = neighbours.filter { $0.lowerBound < span.lowerBound }.map(\.upperBound).max()
            let after = neighbours.filter { $0.lowerBound >= span.lowerBound }.map(\.lowerBound).min()
            let lower = before.map { ($0 + span.lowerBound) / 2 + inset / 2 } ?? 0
            let upper = after.map { (span.upperBound + $0) / 2 - inset / 2 } ?? width
            // Squeezed to nothing between neighbours close on either side.
            return lower...max(lower, upper)
        }

        private func overlap(_ first: ClosedRange<Double>, _ second: ClosedRange<Double>) -> Double {
            min(first.upperBound, second.upperBound) - max(first.lowerBound, second.lowerBound)
        }
    }

    /// A time pattern from `DateFormatter.dateFormat(fromTemplate:)` without
    /// its day period, for a label short enough to fit a bracket: "h:mm a"
    /// becomes "h:mm", "a h:mm" "h:mm"; a 24-hour "HH:mm" is kept. Quoted
    /// text is left alone. (Asking `Date.FormatStyle` to omit the day period
    /// pads the hour to two digits instead, "07:31".)
    public static func withoutDayPeriod(_ pattern: String) -> String {
        var result = ""
        var quoted = false
        for character in pattern {
            if character == "'" { quoted.toggle() }
            if !quoted, character == "a" || character == "b" || character == "B" { continue }
            result.append(character)
        }
        // The spaces the day period stood beside, ordinary or narrow.
        let spaces = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{202F}\u{00A0}"))
        return result.trimmingCharacters(in: spaces)
    }
}
