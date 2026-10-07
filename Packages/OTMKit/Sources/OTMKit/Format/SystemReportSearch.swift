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

    /// Lower case without accents or hyphens, so "Wi-Fi", "wifi" and "WIFI" all meet.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: "")
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

extension SystemReport {
    /// What the summary at the top of the System page says that no card
    /// does, for its search: the Mac's name and model, and its identifiers.
    public static func overview(_ hardware: MacHardware) -> [InfoRow] {
        [InfoRow("Model", hardware.displayName), InfoRow("Model identifier", hardware.modelIdentifier)] + identifiers(hardware)
    }
}
