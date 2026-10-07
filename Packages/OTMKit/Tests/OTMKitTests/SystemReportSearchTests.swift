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
