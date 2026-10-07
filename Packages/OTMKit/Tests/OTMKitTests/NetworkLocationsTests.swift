import Darwin
import Foundation
@testable import OTMKit
import Testing

/// Network locations from SystemConfiguration's preferences, and mounted
/// shares from mount-table records, without touching this Mac's settings or
/// any server.
struct NetworkLocationsTests {
    private static let wifi = "F82BBE4E-2A7E-4D60-BDD8-3D83E7968C31"
    private static let usb = "6D34ABB2-3507-4ECE-8292-C9B8753E7F11"
    private static let bridge = "8D6EF9BC-F87F-4AED-A5DA-A0EE275C53CB"
    private static let hidden = "C926A5EB-1806-46B4-AB1A-E96EC280FF2E"
    private static let automatic = "157370FC-F903-4CB6-AE73-E88DD39D59D6"
    private static let office = "2A1D0D4C-90B2-4E61-9F51-7B0E5E6C4C10"

    private static func link(_ id: String) -> [String: Any] { ["__LINK__": "/NetworkServices/\(id)"] }

    /// Shaped like `preferences.plist`: Automatic orders all four services
    /// (one a hidden adapter macOS keeps for itself); Office links two with
    /// no order and Wi-Fi made inactive there.
    private static var sets: [String: Any] { [
        automatic: [
            "UserDefinedName": "Automatic",
            "Network": [
                "Global": ["IPv4": ["ServiceOrder": [usb, hidden, wifi, bridge]]],
                "Service": [wifi: link(wifi), usb: link(usb), bridge: link(bridge), hidden: link(hidden)],
            ],
        ],
        office: [
            "UserDefinedName": "Office",
            "Network": ["Service": [usb: link(usb), "OFFICE-WIFI": link("OFFICE-WIFI"), "GONE": link("GONE")]],
        ],
        "BROKEN": "not a set",
    ] }

    private static var services: [String: Any] { [
        wifi: ["UserDefinedName": "Wi-Fi", "Interface": ["DeviceName": "en0", "Hardware": "AirPort", "Type": "IEEE80211"]],
        usb: ["Interface": ["DeviceName": "en7", "UserDefinedName": "USB 10/100/1000 LAN"]],
        bridge: ["UserDefinedName": "Thunderbolt Bridge", "Interface": ["DeviceName": "bridge0"]],
        hidden: ["UserDefinedName": "Ethernet Adapter (en3)",
                 "Interface": ["DeviceName": "en3", "HiddenConfiguration": NSNumber(value: true)]],
        "OFFICE-WIFI": ["UserDefinedName": "Wi-Fi", "__INACTIVE__": NSNumber(value: 1), "Interface": ["DeviceName": "en0"]],
    ] }

    // MARK: - Locations

    @Test func locationsListTheOneInUseFirstWithItsServices() {
        let locations = NetworkLocation.parse(currentSet: "/Sets/\(Self.automatic)", sets: Self.sets, services: Self.services)
        #expect(locations.map(\.name) == ["Automatic", "Office"])
        #expect(locations.map(\.isCurrent) == [true, false])
        // In the set's order, without the hidden adapter.
        #expect(locations[0].services == [
            .init(name: "USB 10/100/1000 LAN", interface: "en7", isEnabled: true),
            .init(name: "Wi-Fi", interface: "en0", isEnabled: true),
            .init(name: "Thunderbolt Bridge", interface: "bridge0", isEnabled: true),
        ])
        // Unordered services follow by ID; a link to nothing is dropped.
        #expect(locations[1].services == [
            .init(name: "USB 10/100/1000 LAN", interface: "en7", isEnabled: true),
            .init(name: "Wi-Fi", interface: "en0", isEnabled: false),
        ])
        #expect(locations[1].id == Self.office)
    }

    @Test func locationsWithoutACurrentOneSortByName() {
        let sets: [String: Any] = ["B": ["UserDefinedName": "Travel"], "A": ["UserDefinedName": "Home"], "C": [String: Any]()]
        let locations = NetworkLocation.parse(currentSet: nil, sets: sets, services: [:])
        #expect(locations.map(\.name) == ["Home", "Travel", "Untitled"])
        #expect(locations.allSatisfy { !$0.isCurrent && $0.services.isEmpty })
        #expect(NetworkLocation.parse(currentSet: "/Sets/A", sets: [:], services: [:]).isEmpty)
    }

    @Test func locationRowsNameTheOneInUseAndTheOthers() {
        let locations = NetworkLocation.parse(currentSet: "/Sets/\(Self.automatic)", sets: Self.sets, services: Self.services)
        let rows = SystemReport.locationRows(locations)
        #expect(rows.map(\.label) == ["Location", "Other location"])
        #expect(rows.map(\.value) == ["Automatic (in use)", "Office: USB 10/100/1000 LAN, Wi-Fi (inactive)"])

        let only = SystemReport.locationRows([locations[0]])
        #expect(only.map(\.value) == ["Automatic (the only one)"])

        let empty = NetworkLocation(id: "E", name: "Empty", isCurrent: false, services: [])
        let several = SystemReport.locationRows([locations[1], empty])
        #expect(several.map(\.label) == ["Location", "Other locations"])
        #expect(several.map(\.value) == ["None chosen", "Office: USB 10/100/1000 LAN, Wi-Fi (inactive)\nEmpty: no services"])

        let unread = SystemReport.locationRows([])
        #expect(unread.map(\.value) == ["Couldn't read"] && unread[0].status == .unknown)
    }

    // MARK: - Volumes

    @Test func sourcesSplitIntoServerShareAndAccount() {
        func parts(_ source: String) -> [String?] {
            let origin = NetworkVolume.parseSource(source)
            return [origin.server, origin.share, origin.account]
        }
        #expect(parts("//jamie@nas.home.arpa/Media") == ["nas.home.arpa", "Media", "jamie"])
        // A password never survives, and a domain stays with the account.
        #expect(parts("//WORKGROUP;jamie:hunter2@nas._smb._tcp.local/Photos%20Library") == [
            "nas._smb._tcp.local", "Photos Library", "WORKGROUP;jamie",
        ])
        #expect(parts("//GUEST:@printer.local/Public") == ["printer.local", "Public", "GUEST"])
        #expect(parts("//nas.local") == ["nas.local", nil, nil])
        #expect(parts("10.0.0.20:/export/builds") == ["10.0.0.20", "/export/builds", nil])
        #expect(parts("[fd00::20]:/export") == ["fd00::20", "/export", nil])
        #expect(parts("https://dav.example.com/remote.php/dav") == ["dav.example.com", "/remote.php/dav", nil])
        #expect(parts("http://jamie:secret@localhost:8089/") == ["localhost", nil, "jamie"])
        #expect(parts("map auto_home") == [nil, nil, nil])
    }

    @Test func mountRecordsBecomeVolumes() throws {
        typealias Record = NetworkVolume.MountRecord
        let smb = try #require(NetworkVolume.parse(Record(
            fileSystemType: "smbfs", source: "//jamie@nas.home.arpa/Media", mountPoint: "/Volumes/Media",
            flags: UInt32(MNT_NOSUID | MNT_NODEV), blocks: 1_000_000, availableBlocks: 250_000, blockSize: 4096
        )))
        #expect(smb.kind == .smb && smb.name == "Media" && smb.id == "/Volumes/Media")
        #expect(smb.server == "nas.home.arpa" && smb.share == "Media" && smb.account == "jamie")
        #expect(smb.totalBytes == 4_096_000_000 && smb.availableBytes == 1_024_000_000)
        #expect(!smb.isReadOnly && !smb.isAutomounted && !smb.isHidden)

        let nfs = try #require(NetworkVolume.parse(Record(
            fileSystemType: "nfs", source: "10.0.0.20:/export/builds", mountPoint: "/System/Volumes/Data/net/builds",
            flags: UInt32(MNT_RDONLY | MNT_AUTOMOUNTED | MNT_DONTBROWSE), blockSize: 512
        )))
        #expect(nfs.kind == .nfs && nfs.name == "builds")
        // No blocks: the server hasn't said.
        #expect(nfs.totalBytes == nil && nfs.availableBytes == nil)
        #expect(nfs.isReadOnly && nfs.isAutomounted && nfs.isHidden)

        let huge = NetworkVolume.parse(Record(fileSystemType: "webdav", source: "https://dav.example.com/files",
                                              mountPoint: "/Volumes/files", blocks: .max, availableBlocks: 1, blockSize: 4096))
        #expect(huge?.kind == .webdav && huge?.totalBytes == nil && huge?.availableBytes == 4096)

        for local in ["apfs", "autofs", "devfs", "msdos", "nullfs"] {
            #expect(NetworkVolume.parse(Record(fileSystemType: local, source: "/dev/disk3s1", mountPoint: "/", blocks: 1,
                                               availableBlocks: 1, blockSize: 1)) == nil, "\(local)")
        }
        #expect(NetworkVolume.Kind(fileSystemType: "cifs") == .smb)
        #expect(NetworkVolume.Kind(fileSystemType: "afpfs")?.title == "AFP")
        #expect(NetworkVolume.Kind(fileSystemType: "ftp")?.title == "FTP")
    }

    @Test func aVolumeIsNamedLikeFinderNamesIt() {
        func volume(_ mountPoint: String, share: String?) -> NetworkVolume {
            NetworkVolume(kind: .smb, server: nil, share: share, account: nil, mountPoint: mountPoint, totalBytes: nil, availableBytes: nil)
        }
        #expect(volume("/Volumes/Media-1", share: "Media").name == "Media-1")
        #expect(volume("/", share: "/export/home").name == "home")
        #expect(volume("/", share: nil).name == "/")
    }

    @Test func volumeRowsKeepServersOutOfReportsAndAccountsHidden() {
        #expect(SystemReport.volumeRows([]).map(\.value) == ["None mounted"])
        let rows = SystemReport.volumeRows(NetworkFixture.volumes)
        #expect(rows.filter(\.isHeading).map(\.label) == ["Media", "builds"])
        #expect(rows.filter(\.isHeading).map(\.headingNote) == ["SMB", "NFS, read-only"])
        #expect(rows.map(\.label) == [
            "Media", "Server", "Share", "Mounted at", "Space", "Account",
            "builds", "Server", "Share", "Mounted at", "Space", "Options",
        ])
        #expect(rows.filter(\.isAddress).map(\.value) == ["nas.home.arpa", "Media", "10.0.0.20", "/export/builds", "/Users/jamie/builds"])
        #expect(rows.filter(\.isSensitive).map(\.value) == ["jamie"])
        #expect(rows[4].value == SystemFacts.decimalBytes(1_250_000_000_000) + " free of " + SystemFacts.decimalBytes(4_000_000_000_000))
        #expect(rows[10].value == "Not reported by the server")
        #expect(rows[11].value == "mounted on demand, hidden from Finder")

        let unknown = SystemReport.volumeRows([NetworkVolume(kind: .afp, server: nil, share: nil, account: nil, mountPoint: "/Volumes/x",
                                                             totalBytes: nil, availableBytes: nil)])
        #expect(unknown.map(\.label) == ["x", "Server", "Mounted at", "Space"])
        #expect(unknown[1].value == "Not recorded" && !unknown[1].isAddress)
    }

    @Test func theVolumesCardOnlyExplainsItselfWithSharesToExplain() {
        var configuration = NetworkFixture.configuration
        let card = SystemReport.networkSections([], configuration).first { $0.kind == .networkVolumes }
        #expect(card?.title == "Network Volumes")
        #expect(card?.note?.hasPrefix("Read from this Mac's mount table") == true)
        configuration.volumes = []
        let empty = SystemReport.networkSections([], configuration).first { $0.kind == .networkVolumes }
        #expect(empty?.note == nil && empty?.rows.map(\.label) == ["Shares"])
    }
}
