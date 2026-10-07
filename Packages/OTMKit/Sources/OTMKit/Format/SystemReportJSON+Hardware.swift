import Foundation

/// The report's `firewall` and `hardwareDetails`, and the network
/// configuration's `locations` and `volumes`. File servers, shares,
/// accounts, serial numbers and smart-card tokens are identifiers: `null`
/// unless they're included.
extension SystemReportJSON {
    // MARK: - Network locations and volumes

    struct NetworkLocationJSON: Encodable {
        let name: String
        /// The location System Settings uses now.
        let isCurrent: Bool
        let services: [Service]

        struct Service: Encodable {
            let name: String
            @Nullable var interface: String?
            let isEnabled: Bool

            init(_ service: NetworkLocation.Service) {
                name = service.name
                interface = service.interface
                isEnabled = service.isEnabled
            }
        }

        init(_ location: NetworkLocation) {
            name = location.name
            isCurrent = location.isCurrent
            services = location.services.map(Service.init)
        }
    }

    struct NetworkVolumeJSON: Encodable {
        let name: String
        /// "smb", "nfs", "afp", "webdav" or "ftp".
        let kind: NetworkVolume.Kind
        @Nullable var server: String?
        @Nullable var share: String?
        @Nullable var account: String?
        /// Null when it's inside a home folder, whose path names the user.
        @Nullable var mountPoint: String?
        /// The server's last answer, as the kernel holds it; null when it has none.
        @Nullable var totalBytes: UInt64?
        @Nullable var availableBytes: UInt64?
        let isReadOnly: Bool
        let isAutomounted: Bool
        let isHiddenFromFinder: Bool

        init(_ volume: NetworkVolume, keep: Bool) {
            name = volume.name
            kind = volume.kind
            server = keep ? volume.server : nil
            share = keep ? volume.share : nil
            account = keep ? volume.account : nil
            mountPoint = keep || !volume.mountPoint.hasPrefix("/Users/") ? volume.mountPoint : nil
            totalBytes = volume.totalBytes
            availableBytes = volume.availableBytes
            isReadOnly = volume.isReadOnly
            isAutomounted = volume.isAutomounted
            isHiddenFromFinder = volume.isHidden
        }
    }

    // MARK: - Firewall

    /// Policy only. Each fact is null when no tool returned it.
    struct Firewall: Encodable {
        /// "off", "on" or "blockAll".
        @Nullable var mode: FirewallStatus.Mode?
        @Nullable var stealthMode: Bool?
        @Nullable var logging: Bool?
        @Nullable var allowsBuiltInSignedSoftware: Bool?
        @Nullable var allowsDownloadedSignedSoftware: Bool?
        @Nullable var appRules: [Rule]?
        @Nullable var serviceRules: [Rule]?
        /// The tools that answered: "systemProfiler", "socketFilter".
        let sources: [FirewallStatus.Source]
        /// What an unprivileged read can't include.
        let notRead = ["packetFilterRules"]

        struct Rule: Encodable {
            let name: String
            /// "allow", "block" or "allowLocal".
            let policy: FirewallStatus.Policy
        }

        init(_ status: FirewallStatus) {
            mode = status.mode
            stealthMode = status.stealthMode
            logging = status.logging
            allowsBuiltInSignedSoftware = status.allowsBuiltInSigned
            allowsDownloadedSignedSoftware = status.allowsDownloadedSigned
            appRules = status.apps?.map { Rule(name: $0.name, policy: $0.policy) }
            serviceRules = status.services?.map { Rule(name: $0.name, policy: $0.policy) }
            sources = status.sources
        }
    }

    // MARK: - Hardware details

    /// Each part is null when its report couldn't be read.
    struct HardwareDetails: Encodable {
        let collectedAt: Date
        @Nullable var memory: Memory?
        @Nullable var storageControllers: [Controller]?
        @Nullable var cardReaders: [CardReaderJSON]?
        @Nullable var smartCards: SmartCards?

        init(_ inventory: HardwareInventory, collectedAt: Date, keep: Bool) {
            self.collectedAt = collectedAt
            memory = inventory.memory.value.map { Memory($0, keep: keep) }
            storageControllers = inventory.storageControllers.value?.map { Controller($0, keep: keep) }
            cardReaders = inventory.cardReaders.value?.map { CardReaderJSON($0, keep: keep) }
            smartCards = inventory.smartCards.value.map { SmartCards($0, keep: keep) }
        }
    }

    struct Memory: Encodable {
        /// As reported ("LPDDR5"); null when macOS doesn't say.
        @Nullable var type: String?
        @Nullable var manufacturer: String?
        /// As reported: "48 GB".
        @Nullable var size: String?
        @Nullable var isUpgradeable: Bool?
        @Nullable var ecc: String?
        /// Slots, on a Mac that has them; empty on Apple silicon.
        let modules: [Module]

        struct Module: Encodable {
            let slot: String
            let isEmpty: Bool
            @Nullable var size: String?
            @Nullable var type: String?
            @Nullable var speed: String?
            @Nullable var manufacturer: String?
            @Nullable var partNumber: String?
            @Nullable var serialNumber: String?
            @Nullable var status: String?

            init(_ module: MemoryDetails.Module, keep: Bool) {
                slot = module.slot
                isEmpty = module.isEmpty
                size = module.size
                type = module.type
                speed = module.speed
                manufacturer = module.manufacturer
                partNumber = module.partNumber
                serialNumber = keep ? module.serialNumber : nil
                status = module.status
            }
        }

        init(_ memory: MemoryDetails, keep: Bool) {
            type = memory.type
            manufacturer = memory.manufacturer
            size = memory.size
            isUpgradeable = memory.isUpgradeable
            ecc = memory.ecc
            modules = memory.modules.map { Module($0, keep: keep) }
        }
    }

    struct Controller: Encodable {
        let bus: StorageController.Bus
        let name: String
        @Nullable var vendor: String?
        @Nullable var linkWidth: String?
        @Nullable var linkSpeed: String?
        let drives: [Drive]

        struct Drive: Encodable {
            let name: String
            @Nullable var bsdName: String?
            @Nullable var model: String?
            @Nullable var revision: String?
            @Nullable var serialNumber: String?
            @Nullable var sizeBytes: UInt64?
            @Nullable var smartStatus: String?
            @Nullable var supportsTRIM: Bool?
            @Nullable var medium: String?
            @Nullable var isRemovable: Bool?
            @Nullable var isDetachable: Bool?

            init(_ drive: StorageController.Drive, keep: Bool) {
                name = drive.name
                bsdName = drive.bsdName
                model = drive.model
                revision = drive.revision
                serialNumber = keep ? drive.serialNumber : nil
                sizeBytes = drive.sizeBytes
                smartStatus = drive.smartStatus
                supportsTRIM = drive.supportsTRIM
                medium = drive.medium
                isRemovable = drive.isRemovable
                isDetachable = drive.isDetachable
            }
        }

        init(_ controller: StorageController, keep: Bool) {
            bus = controller.bus
            name = controller.name
            vendor = controller.vendor
            linkWidth = controller.linkWidth
            linkSpeed = controller.linkSpeed
            drives = controller.drives.map { Drive($0, keep: keep) }
        }
    }

    struct CardReaderJSON: Encodable {
        let isBuiltIn: Bool
        @Nullable var vendorID: String?
        @Nullable var deviceID: String?
        @Nullable var linkSpeed: String?
        let cards: [Card]

        struct Card: Encodable {
            let name: String
            @Nullable var productName: String?
            @Nullable var sizeBytes: UInt64?
            @Nullable var serialNumber: String?

            init(_ card: CardReader.Card, keep: Bool) {
                name = card.name
                productName = card.productName
                sizeBytes = card.sizeBytes
                serialNumber = keep ? card.serialNumber : nil
            }
        }

        init(_ reader: CardReader, keep: Bool) {
            isBuiltIn = reader.isBuiltIn
            vendorID = reader.vendorID
            deviceID = reader.deviceID
            linkSpeed = reader.linkSpeed
            cards = reader.cards.map { Card($0, keep: keep) }
        }
    }

    struct SmartCards: Encodable {
        let readers: [Reader]
        let readerDrivers: [Driver]
        let cardDrivers: [Driver]
        /// How many cards are present, and their drivers' IDs.
        let cardCount: Int
        let cardKinds: [String]
        /// The cards' token IDs, which identify them.
        @Nullable var cardTokens: [String]?
        /// USB devices with a smart-card interface; null when the I/O Registry wasn't read.
        @Nullable var usbDevices: [String]?

        struct Reader: Encodable {
            let name: String
            let hasCard: Bool
        }

        struct Driver: Encodable {
            let id: String
            @Nullable var version: String?

            init(_ driver: SmartCardReport.Driver) {
                id = driver.id
                version = driver.version
            }
        }

        init(_ report: SmartCardReport, keep: Bool) {
            readers = report.readers.map { Reader(name: $0.name, hasCard: $0.hasCard) }
            readerDrivers = report.readerDrivers.map(Driver.init)
            cardDrivers = report.tokenDrivers.map(Driver.init)
            cardCount = report.tokens.count
            cardKinds = Array(Set(report.tokens.map(SmartCardReport.tokenKind))).sorted()
            cardTokens = keep ? report.tokens : nil
            usbDevices = report.usbDevices
        }
    }

    /// The hardware details alone, for `otm hardware --json`.
    struct HardwareOnly: Encodable {
        let format = SystemReportDocument.format
        let schemaVersion = SystemReportDocument.schemaVersion
        let collectedAt: Date
        let includesIdentifiers: Bool
        let hardwareDetails: HardwareDetails
    }
}

extension SystemReportDocument {
    /// The report's `hardwareDetails` alone, with the same header, as `otm hardware --json` prints it.
    public static func hardwareJSON(_ hardware: HardwareInventory, includeIdentifiers keep: Bool, collectedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(SystemReportJSON.HardwareOnly(
            collectedAt: collectedAt, includesIdentifiers: keep,
            hardwareDetails: SystemReportJSON.HardwareDetails(hardware, collectedAt: collectedAt, keep: keep)
        ))
    }
}
