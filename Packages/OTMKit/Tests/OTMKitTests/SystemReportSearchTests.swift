import Foundation
@testable import OTMKit
import Testing

struct SystemReportSearchTests {
    /// A few cards shaped like the page's: plain rows, ports under headings,
    /// and a device card whose facts sit behind each device.
    private let sections = [
        InfoSection(kind: .processor, title: "Processor", rows: [InfoRow("Chip", "Apple M5 Pro"), InfoRow("Cores", "18 cores")]),
        InfoSection(kind: .displays, title: "Displays", rows: [
            InfoRow("Built-in Display", "built-in, main", isHeading: true),
            InfoRow("Resolution", "3456 × 2234"),
        ]),
        InfoSection(kind: .network, title: "Network", rows: [
            InfoRow("Wi-Fi", "en0", isHeading: true, state: "primary", interface: "en0"),
            InfoRow("Status", "Connected", status: .good),
            InfoRow("IPv6", "2001:db8::5/64", isCode: true, isAddress: true),
            InfoRow("Hardware address", "a4:83:e7:0b:12:9c", isSensitive: true, isCode: true),
            InfoRow("Ethernet", "en1", isHeading: true, interface: "en1"),
            InfoRow("Status", "Connected", status: .good),
            InfoRow("IPv6", "fd6c::1/64", isCode: true, isAddress: true),
        ]),
        InfoSection(kind: .networkConfiguration, title: "Network Configuration", rows: [
            InfoRow("Primary", "Ethernet (en1)"),
        ]),
        InfoSection(kind: .firewall, title: "Firewall", rows: [InfoRow("Application firewall", "Off")]),
        InfoSection(kind: .bluetooth, title: "Bluetooth", rows: [
            InfoRow("Status", "On"),
            InfoRow("Magic Keyboard", "", isHeading: true, state: "battery 80%"),
            InfoRow("Maker", "Apple", isDetail: true),
            InfoRow("Address", "11:22:33:44:55:66", isSensitive: true, isCode: true, isDetail: true),
            InfoRow("Chipset", "BCM_4388"),
        ]),
        InfoSection(kind: .software, title: "Software", rows: [InfoRow("macOS", "27.2 (26B5101f)")]),
        InfoSection(kind: .security, title: "Security", rows: [InfoRow("FileVault", "On", status: .good)]),
    ]

    private let overview = SystemReport.overview(MacHardware(
        modelIdentifier: "Mac17,8", marketingName: "MacBook Pro (16-inch, M5 Pro)", chip: "Apple M5 Pro", physicalMemory: 48 << 30,
        pageSize: 16_384, kind: .laptop, serialNumber: "SERIAL123", hardwareUUID: "UUID-456"
    ))

    @Test func categoriesFollowTheCards() {
        #expect(SystemCategory.present(in: sections.map(\.kind)) == [.hardware, .displays, .network, .security, .devices, .software])
        #expect(SystemCategory(.controllers) == .hardware)
        #expect(SystemCategory(.networkVolumes) == .network)
        #expect(SystemCategory(.audio) == .devices)
        // One per kind, so the jump bar can't miss a card.
        #expect(Set(InfoSection.Kind.allCases.map(SystemCategory.init)) == Set(SystemCategory.allCases))
    }

    @Test func anEmptyFieldFindsNothingAndShowsEverything() {
        let search = SystemReportSearch(sections, query: "   ")
        #expect(!search.isActive)
        #expect(search.cards.isEmpty)
        #expect(search.matches.isEmpty)
    }

    @Test func aRowBringsItsHeading() throws {
        let search = SystemReportSearch(sections, query: "resolution")
        #expect(search.cards.map(\.kind) == [.displays])
        #expect(try #require(search.card(.displays)).rows == [0, 1])
        #expect(search.matches == [.row(.displays, 1)])
    }

    @Test func wordsMayComeFromTheHeadingAbove() throws {
        // Both ports have an IPv6 row; only Wi-Fi's has both words.
        let both = SystemReportSearch(sections, query: "ipv6")
        #expect(both.matches == [.row(.network, 2), .row(.network, 6)])
        #expect(try #require(both.card(.network)).rows == [0, 2, 4, 6])

        let wifi = SystemReportSearch(sections, query: "wifi IPV6")
        #expect(wifi.matches == [.row(.network, 2)])
        #expect(try #require(wifi.card(.network)).rows == [0, 2])
    }

    @Test func aMatchingHeadingBringsItsWholeGroup() throws {
        let search = SystemReportSearch(sections, query: "en1")
        let network = try #require(search.card(.network))
        #expect(network.rows == [4, 5, 6])
        // The configuration's "Ethernet (en1)" is a match of its own.
        #expect(search.matches == [.row(.network, 4), .row(.networkConfiguration, 0)])
    }

    @Test func aMatchingTitleOrCategoryBringsTheWholeCard() throws {
        let network = SystemReportSearch(sections, query: "Network")
        #expect(network.matches == [.card(.network), .card(.networkConfiguration)])
        #expect(try #require(network.card(.network)).rows == Array(0..<7))

        let devices = SystemReportSearch(sections, query: "devices")
        #expect(devices.matches == [.card(.bluetooth)])
        let security = SystemReportSearch(sections, query: "security")
        #expect(security.matches == [.card(.firewall), .card(.security)])
    }

    @Test func aDeviceOpensToShowAMatchingFact() throws {
        let search = SystemReportSearch(sections, query: "maker apple")
        let bluetooth = try #require(search.card(.bluetooth))
        #expect(bluetooth.rows == [1, 2])
        #expect(bluetooth.opens == [1])
        #expect(search.matches == [.row(.bluetooth, 2)])
        // The card's own rows aren't the device's, so its name doesn't bring them.
        let keyboard = SystemReportSearch(sections, query: "keyboard")
        #expect(try #require(keyboard.card(.bluetooth)).rows == [1, 2, 3])
        #expect(try #require(keyboard.card(.bluetooth)).opens.isEmpty)
        #expect(keyboard.matches == [.row(.bluetooth, 1)])
    }

    @Test func ignoresCaseAccentsAndHyphens() {
        #expect(SystemReportSearch(sections, query: "WI-FI").matches == [.row(.network, 0)])
        #expect(SystemReportSearch(sections, query: "fílevault").matches == [.row(.security, 0)])
        #expect(SystemReportSearch(sections, query: "builtin display").card(.displays)?.rows == [0, 1])
    }

    @Test func hiddenIdentifiersMatchByLabelOnly() {
        let hidden = SystemReportSearch(sections, query: "a4:83", overview: overview)
        #expect(hidden.matches.isEmpty)
        #expect(SystemReportSearch(sections, query: "SERIAL123", overview: overview).matches.isEmpty)
        #expect(SystemReportSearch(sections, query: "hardware address").matches == [.row(.network, 3)])

        let shown = SystemReportSearch(sections, query: "a4:83", overview: overview, includesIdentifiers: true)
        #expect(shown.matches == [.row(.network, 3)])
        #expect(SystemReportSearch(sections, query: "serial123", overview: overview, includesIdentifiers: true).matches == [.overview])
    }

    @Test func theOverviewMatchesTheMacsNameAndModel() {
        let search = SystemReportSearch(sections, query: "macbook mac17", overview: overview)
        #expect(search.matches == [.overview])
        #expect(search.cards.isEmpty)
        #expect(search.isActive)
    }

    @Test func nothingFoundLeavesNoCards() {
        let search = SystemReportSearch(sections, query: "ipv6 bluetooth zebra")
        #expect(search.isActive)
        #expect(search.cards.isEmpty)
        #expect(search.matches.isEmpty)
    }

    // MARK: Highlights

    /// The marked stretches of `text`, as text.
    private func marked(_ query: String, in text: String) -> [String] {
        SystemReportSearch.highlights(of: SystemReportSearch.terms(query), in: text).map { String(text[$0]) }
    }

    @Test func highlightsFoldAsTheSearchDoes() {
        #expect(marked("wifi", in: "Wi-Fi") == ["Wi-Fi"])
        #expect(marked("WI-FI", in: "Wi-Fi") == ["Wi-Fi"])
        #expect(marked("fi", in: "Wi-Fi") == ["Fi"])
        #expect(marked("filevault", in: "FíleVault") == ["FíleVault"])
        #expect(marked("ipv6", in: "IPv4 by DHCP, IPv6 automatic") == ["IPv6"])
        #expect(marked("ＩＰｖ６", in: "IPv6") == ["IPv6"])
        #expect(marked("builtin", in: "Built-in Display") == ["Built-in"])
    }

    @Test func highlightsMarkEveryFindOfEveryWord() {
        #expect(marked("en", in: "Ethernet (en1) · open") == ["en", "en"])
        #expect(marked("wifi ipv6", in: "Wi-Fi IPv6") == ["Wi-Fi", "IPv6"])
        // Overlapping or touching finds come out as one stretch.
        #expect(marked("ip pv6", in: "IPv6") == ["IPv6"])
        #expect(marked("aa", in: "aaaa") == ["aaaa"])
    }

    @Test func aCharacterThatFoldsToTwoIsMarkedWhole() {
        #expect(marked("strasse", in: "Straße 5") == ["Straße"])
        #expect(marked("s", in: "Straße") == ["S", "ß"])
    }

    @Test func nothingToMarkWithoutWordsOrFinds() {
        #expect(marked("", in: "Wi-Fi").isEmpty)
        #expect(marked("-", in: "Wi-Fi").isEmpty, "a hyphen alone folds away, as in the search")
        #expect(marked("zebra", in: "Wi-Fi").isEmpty)
        #expect(marked("wifi", in: "").isEmpty)
        #expect(SystemReportSearch(sections, query: "").highlights(in: "Wi-Fi").isEmpty)
        let wifi = "Wi-Fi"
        #expect(SystemReportSearch(sections, query: "wifi").highlights(in: wifi).map { wifi[$0] } == ["Wi-Fi"])
    }

    @Test func highlightsAgreeWithTheSearch() {
        // Every row's text is marked exactly when the search would find the word in it.
        let words = ["wifi", "ipv6", "en1", "64", "apple", "on", "connected", "e7", "×", "file", "chip", "-", "5d"]
        for row in sections.flatMap(\.rows) {
            for text in [row.label, row.value, row.state ?? ""] {
                for word in words {
                    let found = SystemReportSearch.terms(word).contains { SystemReportSearch.fold(text).contains($0) }
                    #expect(marked(word, in: text).isEmpty == !found, "\(word) in \(text)")
                }
            }
        }
    }

    @Test func foldingACharacterAtATimeMatchesFoldingTheWhole() {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let samples = (0..<128).map { String(Character(Unicode.Scalar(UInt8($0)))) }
            + ["Wi-Fi", "FíleVault", "Straße", "ＩＰｖ６", "İstanbul", "ﬁle", "3456 × 2234", "cafe\u{301}", "line\r\nbreak"]
        for sample in samples {
            let whole = sample.folding(options: options, locale: nil).replacingOccurrences(of: "-", with: "")
            #expect(SystemReportSearch.fold(sample) == whole, "\(sample.debugDescription)")
        }
    }

    @Test func highlightsFollowAnAddressBrokenOverLines() throws {
        let text = "fd6c:adbe:19d6:5d7"
        let form = "fd6c:adbe:\n19d6:5d7"
        let terms = SystemReportSearch.terms("adbe:19d6")
        // Found across the break, and marked on both sides of it.
        #expect(SystemReportSearch.highlights(of: terms, in: text, shownAs: form).map { String(form[$0]) } == ["adbe:", "19d6"])
        #expect(SystemReportSearch.highlights(of: SystemReportSearch.terms("5d7"), in: text, shownAs: form).map { String(form[$0]) } == ["5d7"])
        #expect(SystemReportSearch.highlights(of: terms, in: text, shownAs: text).map { String(text[$0]) } == ["adbe:19d6"])
        // A form that isn't the text with breaks put in is searched itself.
        #expect(SystemReportSearch.highlights(of: terms, in: text, shownAs: "adbe:19d6 elsewhere").count == 1)

        // A real form from AddressBreaks.
        let address = "2001:db8:85a3:8d3:1319:8a2e:370:7348/64"
        let broken = try #require(AddressBreaks.forms(address).first)
        let marks = SystemReportSearch.highlights(of: SystemReportSearch.terms(address), in: address, shownAs: broken)
        #expect(marks.map { String(broken[$0]) }.joined() == address)
        #expect(marks.count == broken.split(separator: "\n").count)
    }

    @Test func blocksKeepTheirPlaceInTheCard() throws {
        let bluetooth = try #require(sections.first { $0.kind == .bluetooth })
        #expect(bluetooth.blockIndices() == [.rows([0]), .device(1, details: [2, 3]), .rows([4])])
        #expect(bluetooth.blockIndices(showing: [1, 3]) == [.device(1, details: [3])])
        #expect(bluetooth.blocks == [
            .rows([InfoRow("Status", "On")]),
            .device(InfoRow("Magic Keyboard", "", isHeading: true, state: "battery 80%"), details: [
                InfoRow("Maker", "Apple", isDetail: true),
                InfoRow("Address", "11:22:33:44:55:66", isSensitive: true, isCode: true, isDetail: true),
            ]),
            .rows([InfoRow("Chipset", "BCM_4388")]),
        ])
    }
}
