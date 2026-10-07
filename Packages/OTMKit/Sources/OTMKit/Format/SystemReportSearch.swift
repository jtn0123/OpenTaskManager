import Foundation

/// The groups the System page's jump bar offers, each one or more of its
/// cards. In the order the first card of each comes on the page.
public enum SystemCategory: String, CaseIterable, Sendable, Identifiable {
    case hardware, displays, storage, network, security, devices, battery, software

    public var id: Self { self }

    public var title: String {
        switch self {
        case .hardware: "Hardware"
        case .displays: "Displays"
        case .storage: "Storage"
        case .network: "Network"
        case .security: "Security"
        case .devices: "Devices"
        case .battery: "Battery"
        case .software: "Software"
        }
    }

    public init(_ kind: InfoSection.Kind) {
        self = switch kind {
        case .processor, .memory, .graphics, .controllers: .hardware
        case .displays: .displays
        case .storage: .storage
        case .network, .networkConfiguration, .networkVolumes: .network
        case .firewall, .security: .security
        case .usb, .thunderbolt, .bluetooth, .audio: .devices
        case .battery: .battery
        case .software: .software
        }
    }

    /// The categories these cards fall into, each once, in the order its
    /// first card comes: a Mac without a battery gets no Battery.
    public static func present(in kinds: [InfoSection.Kind]) -> [SystemCategory] {
        var categories: [SystemCategory] = []
        for kind in kinds where !categories.contains(SystemCategory(kind)) {
            categories.append(SystemCategory(kind))
        }
        return categories
    }
}

/// A search of the System page: the cards and rows that hold every word
/// typed, in any order, ignoring case, accents and hyphens ("wifi" finds
/// Wi-Fi). A word may be in the row itself or in what it sits under, its
/// heading (a port, a drive, a device) and its card's title and category,
/// so "wi-fi ipv6" finds the Wi-Fi port's IPv6 row and no other port's.
/// A card whose title or category holds them all is shown whole, as is a
/// group whose heading does; otherwise a card shows just its matching rows
/// under their headings, and a device whose facts match is opened. Hidden
/// identifiers (serial numbers, MAC addresses) are matched by their labels
/// alone, so a search can't tell what they are.
public struct SystemReportSearch: Sendable, Equatable {
    /// Something the search found, which the page can scroll to and mark.
    public enum Match: Hashable, Sendable {
        /// The summary at the top of the page (the Mac's name and model).
        case overview
        /// A whole card, whose title or category matched.
        case card(InfoSection.Kind)
        /// One of a card's rows, by its index among the section's rows: a
        /// heading when the heading matched, for its whole group.
        case row(InfoSection.Kind, Int)

        public var kind: InfoSection.Kind? {
            switch self {
            case .overview: nil
            case let .card(kind), let .row(kind, _): kind
            }
        }
    }

    /// What a card shows while searching.
    public struct Card: Sendable, Equatable {
        public let kind: InfoSection.Kind
        /// The rows shown, by index among the section's rows, in order.
        public let rows: [Int]
        /// Device headings opened, so a matching fact behind one shows.
        public let opens: Set<Int>
    }

    /// The words searched for, folded for matching; none when the field is empty.
    public let terms: [String]
    /// The cards with something found, in page order.
    public let cards: [Card]
    /// What was found, in page order: the page steps through these.
    public let matches: [Match]

    /// Whether there's a search at all, rather than an empty field.
    public var isActive: Bool { !terms.isEmpty }

    public func card(_ kind: InfoSection.Kind) -> Card? {
        cards.first { $0.kind == kind }
    }

    /// `overview` is the summary's rows (`SystemReport.overview`). With
    /// `includesIdentifiers` off, sensitive rows match by label only.
    public init(_ sections: [InfoSection], query: String, overview: [InfoRow] = [], includesIdentifiers: Bool = false) {
        let terms = Self.terms(query)
        self.terms = terms
        guard !terms.isEmpty else {
            cards = []
            matches = []
            return
        }
        func holdsAll(_ texts: [String]) -> Bool {
            terms.allSatisfy { term in texts.contains { $0.contains(term) } }
        }
        var cards: [Card] = []
        var matches: [Match] = []
        if !overview.isEmpty, holdsAll(overview.flatMap { Self.texts($0, includesIdentifiers: includesIdentifiers) }) {
            matches.append(.overview)
        }
        for section in sections {
            let title = [Self.fold(SystemCategory(section.kind).title), Self.fold(section.title)]
            if holdsAll(title) {
                cards.append(Card(kind: section.kind, rows: Array(section.rows.indices), opens: []))
                matches.append(.card(section.kind))
                continue
            }
            let found = Self.search(section, under: title, includesIdentifiers: includesIdentifiers, holdsAll: holdsAll)
            if !found.shown.isEmpty {
                cards.append(Card(kind: section.kind, rows: found.shown, opens: found.opens))
                matches += found.matched.map { .row(section.kind, $0) }
            }
        }
        self.cards = cards
        self.matches = matches
    }

    /// What one card's search found, by row index.
    private struct Found {
        var shown: [Int] = []
        var matched: [Int] = []
        var opens = Set<Int>()
    }

    /// One card's rows: a heading that matches brings its whole group;
    /// otherwise each row matches with its heading's words to help it.
    private static func search(_ section: InfoSection, under title: [String], includesIdentifiers: Bool,
                               holdsAll: ([String]) -> Bool) -> Found {
        let rows = section.rows
        let isDeviceCard = section.hasDetails
        // The heading each row sits under. On a device card only a device's
        // own facts do; the card's other rows (a Bluetooth status) don't.
        var owner: [Int?] = []
        var heading: Int?
        for (index, row) in rows.enumerated() {
            if row.isHeading {
                heading = index
                owner.append(nil)
            } else {
                owner.append(isDeviceCard && !row.isDetail ? nil : heading)
            }
        }
        var context: [Int: [String]] = [:]
        var headingMatches = Set<Int>()
        for (index, row) in rows.enumerated() where row.isHeading {
            let words = title + texts(row, includesIdentifiers: includesIdentifiers)
            context[index] = words
            if holdsAll(words) { headingMatches.insert(index) }
        }
        // Rows that match, and the headings with a matching row under them.
        var hits = Set<Int>()
        var holdsHit = Set<Int>()
        for (index, row) in rows.enumerated() where !row.isHeading {
            let above = owner[index].flatMap { context[$0] } ?? title
            if holdsAll(above + texts(row, includesIdentifiers: includesIdentifiers)) {
                hits.insert(index)
                if let group = owner[index] { holdsHit.insert(group) }
            }
        }
        var found = Found()
        for index in rows.indices {
            if rows[index].isHeading {
                if headingMatches.contains(index) {
                    found.shown.append(index)
                    found.matched.append(index)
                } else if holdsHit.contains(index) {
                    found.shown.append(index)
                    if isDeviceCard { found.opens.insert(index) }
                }
            } else if let group = owner[index], headingMatches.contains(group) {
                found.shown.append(index)
            } else if hits.contains(index) {
                found.shown.append(index)
                found.matched.append(index)
            }
        }
        return found
    }

    /// The words of a query, folded as `fold` does.
    public static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// Lower case without accents or hyphens, so "Wi-Fi", "wifi" and "WIFI"
    /// all meet. The highlights (`highlights(of:in:)`) fold through the same
    /// `FoldedText`, so they mark exactly what was matched.
    static func fold(_ text: String) -> String {
        String(FoldedText(text).characters)
    }

    /// The row's own words: its label, value and state, without the value
    /// of an identifier the page is hiding.
    private static func texts(_ row: InfoRow, includesIdentifiers: Bool) -> [String] {
        var texts = [fold(row.label)]
        if !row.isSensitive || includesIdentifiers { texts.append(fold(row.value)) }
        if let state = row.state { texts.append(fold(state)) }
        return texts
    }
}

// MARK: - Highlights

extension SystemReportSearch {
    /// Where the search's words are in `text`, for the page to mark them.
    public func highlights(in text: String) -> [Range<String.Index>] {
        Self.highlights(of: terms, in: text)
    }

    /// Where any of `terms` is in `text`, matched as the search matches
    /// (ignoring case, accents and hyphens), as stretches of the text as
    /// shown, in order and never overlapping: "wifi" marks the whole of
    /// "Wi-Fi", hyphen and all, and "fi" just its "Fi".
    public static func highlights(of terms: [String], in text: String) -> [Range<String.Index>] {
        let needles = terms.map { Array(fold($0)) }.filter { !$0.isEmpty }
        guard !needles.isEmpty, !text.isEmpty else { return [] }
        let folded = FoldedText(text)
        let haystack = folded.characters
        // Each find as folded characters, start and end.
        var finds: [(start: Int, end: Int)] = []
        for needle in needles where needle.count <= haystack.count {
            for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
                if haystack[start..<(start + needle.count)].elementsEqual(needle) {
                    finds.append((start, start + needle.count))
                }
            }
        }
        // Back to the text as shown: from the first character a find came
        // from to the end of the last. Folding can make one character two
        // ("ß" is "ss"), so finds that met there are merged too.
        var ranges: [Range<String.Index>] = []
        for find in finds.sorted(by: { $0.start < $1.start }) {
            let lower = folded.origins[find.start]
            let upper = text.index(after: folded.origins[find.end - 1])
            if let last = ranges.last, lower <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                ranges.append(lower..<upper)
            }
        }
        return ranges
    }

    /// `highlights(of:in:)` for `text` laid out as `form`: the same text
    /// with line breaks put in (`AddressBreaks`), so a word found across a
    /// break is still marked, on both sides of it. Searched on `form` itself
    /// if it isn't one.
    public static func highlights(of terms: [String], in text: String, shownAs form: String) -> [Range<String.Index>] {
        guard form != text else { return highlights(of: terms, in: text) }
        // Where each of the text's characters is in the form.
        var places: [String.Index] = []
        var next = text.startIndex
        var index = form.startIndex
        while index < form.endIndex {
            if next < text.endIndex, form[index] == text[next] {
                places.append(index)
                next = text.index(after: next)
            } else if form[index] != "\n" {
                return highlights(of: terms, in: form)
            }
            index = form.index(after: index)
        }
        guard next == text.endIndex else { return highlights(of: terms, in: form) }
        var ranges: [Range<String.Index>] = []
        for range in highlights(of: terms, in: text) {
            let first = text.distance(from: text.startIndex, to: range.lowerBound)
            let count = text.distance(from: range.lowerBound, to: range.upperBound)
            // A stretch for each line it covers, leaving the breaks out.
            var start = places[first]
            for offset in first..<(first + count) {
                let place = places[offset]
                let end = form.index(after: place)
                if offset + 1 == first + count || places[offset + 1] != end {
                    ranges.append(start..<end)
                    if offset + 1 < first + count { start = places[offset + 1] }
                }
            }
        }
        return ranges
    }
}

/// Text folded for matching: lower case, without accents or hyphens, each
/// folded character noting the character of the text it came from. Folded
/// a character at a time, which comes to the same as folding the whole
/// text, so a find can be traced back to what's shown.
struct FoldedText {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// The folded text.
    let characters: [Character]
    /// For each of `characters`, where the character it came from is in the text.
    let origins: [String.Index]

    init(_ text: String) {
        var characters: [Character] = []
        var origins: [String.Index] = []
        characters.reserveCapacity(text.utf8.count)
        origins.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let ascii = character.asciiValue {
                // Plain ASCII folds to itself in lower case (and is most
                // of what the page shows), without a trip through Foundation.
                if ascii != 0x2D {
                    characters.append(ascii >= 0x41 && ascii <= 0x5A ? Character(Unicode.Scalar(ascii + 0x20)) : character)
                    origins.append(index)
                }
            } else {
                for folded in String(character).folding(options: Self.options, locale: nil) where folded != "-" {
                    characters.append(folded)
                    origins.append(index)
                }
            }
            index = text.index(after: index)
        }
        self.characters = characters
        self.origins = origins
    }
}

extension SystemReport {
    /// What the summary at the top of the System page says that no card
    /// does, for its search: the Mac's name and model, and its identifiers.
    public static func overview(_ hardware: MacHardware) -> [InfoRow] {
        [InfoRow("Model", hardware.displayName), InfoRow("Model identifier", hardware.modelIdentifier)] + identifiers(hardware)
    }
}
