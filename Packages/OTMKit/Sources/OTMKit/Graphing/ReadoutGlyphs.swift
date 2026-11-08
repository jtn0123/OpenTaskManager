import Foundation

/// The figures a retro display draws (`RetroDisplay.Style`), as data: which
/// dots of a five-by-seven grid each character lights, or which of seven
/// bars. Only the characters live figures are built from are here (digits,
/// points, signs and %); units stay in type beside them.
public enum ReadoutGlyphs {
    /// Rows of a dot-matrix character, top first.
    public static let rows = 7

    /// A character's lit dots, a row a string from the top, "#" lit and "."
    /// dark; each string is as long as the character is wide in dots. Nil
    /// for a character drawn as type.
    public static func dots(for character: Character) -> [String]? {
        dotPatterns[character]
    }

    /// A character's columns of dots, before the one-dot gap after it.
    public static func dotColumns(for character: Character) -> Int? {
        dotPatterns[character]?.first?.count
    }

    /// Whether `row` and `column` (both from the top left) are lit.
    public static func isLit(_ character: Character, row: Int, column: Int) -> Bool {
        guard let pattern = dotPatterns[character], pattern.indices.contains(row) else { return false }
        let line = Array(pattern[row])
        return line.indices.contains(column) && line[column] == "#"
    }

    /// The seven bars of a figure, and its point.
    public struct Segments: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let top = Segments(rawValue: 1 << 0)
        public static let upperRight = Segments(rawValue: 1 << 1)
        public static let lowerRight = Segments(rawValue: 1 << 2)
        public static let bottom = Segments(rawValue: 1 << 3)
        public static let lowerLeft = Segments(rawValue: 1 << 4)
        public static let upperLeft = Segments(rawValue: 1 << 5)
        public static let middle = Segments(rawValue: 1 << 6)

        /// All seven bars: what an unlit figure shows faintly.
        public static let all: Segments = [.top, .upperRight, .lowerRight, .bottom, .lowerLeft, .upperLeft, .middle]
    }

    /// How a segment display shows a character.
    public enum SegmentForm: Sendable, Hashable {
        /// A figure cell, its lit bars.
        case figure(Segments)
        /// A point (or a comma, with a tail) on its own narrow cell.
        case point(comma: Bool)
        /// A plus: the middle bar crossed by a short upright one.
        case plus
        /// A percent sign: two small boxes and a slash.
        case percent
    }

    public static func segmentForm(for character: Character) -> SegmentForm? {
        switch character {
        case ".": .point(comma: false)
        case ",": .point(comma: true)
        case "-", "−": .figure(.middle)
        case "+": .plus
        case "%": .percent
        default: digitSegments[character].map(SegmentForm.figure)
        }
    }

    /// Characters drawn as dots or bars rather than type.
    public static let drawn: Set<Character> = Set(dotPatterns.keys)

    /// A title's character as five-by-seven dots, as an instrument's strip
    /// spells it (`RetroDisplay.instrument`): capitals, and the figures five
    /// wide. Nil for anything else, a space included, which leaves its
    /// cell unlit. Titles only: figures' units stay type.
    public static func titleDots(for character: Character) -> [String]? {
        if let letter = letterPatterns[character] { return letter }
        guard let figure = dotPatterns[character], figure.first?.count == 5 else { return nil }
        return figure
    }

    private static let digitSegments: [Character: Segments] = [
        "0": [.top, .upperRight, .lowerRight, .bottom, .lowerLeft, .upperLeft],
        "1": [.upperRight, .lowerRight],
        "2": [.top, .upperRight, .middle, .lowerLeft, .bottom],
        "3": [.top, .upperRight, .middle, .lowerRight, .bottom],
        "4": [.upperLeft, .middle, .upperRight, .lowerRight],
        "5": [.top, .upperLeft, .middle, .lowerRight, .bottom],
        "6": [.top, .upperLeft, .middle, .lowerLeft, .lowerRight, .bottom],
        "7": [.top, .upperRight, .lowerRight],
        "8": .all,
        "9": [.top, .upperLeft, .upperRight, .middle, .lowerRight, .bottom],
    ]

    // Drawn for this app: plain shapes, every figure five dots wide so a
    // changing number never shifts the figures after it.
    private static let dotPatterns: [Character: [String]] = [
        "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": [".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        ".": [".", ".", ".", ".", ".", ".", "#"],
        ",": ["..", "..", "..", "..", "..", ".#", "#."],
        "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        "−": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
        "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
    ]

    // Drawn for this app as the figures are: plain capitals, five dots wide.
    private static let letterPatterns: [Character: [String]] = [
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "J": ["..###", "...#.", "...#.", "...#.", "#..#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    ]
}
