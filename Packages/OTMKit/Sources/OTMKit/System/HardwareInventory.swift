import Foundation
import IOKit

/// Memory as `system_profiler SPMemoryDataType` reports it. On Apple
/// silicon that's the unified memory's type and maker, and no slots: it's
/// part of the chip's package. An Intel Mac lists each slot. A fact macOS
/// doesn't report (a virtual machine says "Unknown") is nil, never filled
/// in from the chip's name.
public struct MemoryDetails: Sendable, Hashable {
    public struct Module: Sendable, Hashable {
        /// "DIMM0/0", "BANK 0/ChannelA-DIMM0".
        public var slot: String
        /// As reported: "8 GB".
        public var size: String?
        public var type: String?
        /// "2667 MHz".
        public var speed: String?
        public var manufacturer: String?
        public var partNumber: String?
        /// Identifies the module, so the machine.
        public var serialNumber: String?
        /// Nothing in the slot.
        public var isEmpty: Bool
        /// "OK", "Mapped Out" (turned off after errors); nil when not reported.
        public var status: String?

        public init(slot: String, size: String? = nil, type: String? = nil, speed: String? = nil, manufacturer: String? = nil,
                    partNumber: String? = nil, serialNumber: String? = nil, isEmpty: Bool = false, status: String? = nil) {
            self.slot = slot
            self.size = size
            self.type = type
            self.speed = speed
            self.manufacturer = manufacturer
            self.partNumber = partNumber
            self.serialNumber = serialNumber
            self.isEmpty = isEmpty
            self.status = status
        }
    }

    /// "LPDDR5", "DDR4".
    public var type: String?
    /// "Micron", "Samsung", or a JEDEC code ("0x80CE") on some Intel Macs.
    public var manufacturer: String?
    /// As reported: "48 GB".
    public var size: String?
    /// Only Macs with slots say.
    public var isUpgradeable: Bool?
    /// "Enabled", "Disabled", "Errors"; only Macs with ECC memory say.
    public var ecc: String?
    /// Empty on Apple silicon.
    public var modules: [Module]

    public init(type: String? = nil, manufacturer: String? = nil, size: String? = nil, isUpgradeable: Bool? = nil, ecc: String? = nil,
                modules: [Module] = []) {
        self.type = type
        self.manufacturer = manufacturer
        self.size = size
        self.isUpgradeable = isUpgradeable
        self.ecc = ecc
        self.modules = modules
    }

    /// The type every filled slot shares, when the report gives none of its own.
    public var reportedType: String? {
        type ?? Self.shared(modules.filter { !$0.isEmpty }.map(\.type))
    }

    public var reportedManufacturer: String? {
        manufacturer ?? Self.shared(modules.filter { !$0.isEmpty }.map(\.manufacturer))
    }

    private static func shared(_ values: [String?]) -> String? {
        let set = Set(values)
        guard set.count == 1, let only = set.first else { return nil }
        return only
    }
}

/// A storage controller and the drives behind it, from `system_profiler`'s
/// NVMe, SATA, SAS, parallel SCSI and Fibre Channel reports.
public struct StorageController: Sendable, Hashable {
    public enum Bus: String, Sendable, Codable, CaseIterable {
        case nvme, sata, sas, parallelSCSI, fibreChannel

        public var title: String {
            switch self {
            case .nvme: "NVMe"
            case .sata: "SATA"
            case .sas: "SAS"
            case .parallelSCSI: "Parallel SCSI"
            case .fibreChannel: "Fibre Channel"
            }
        }

        /// Its `system_profiler` data type.
        public var dataType: String {
            switch self {
            case .nvme: "SPNVMeDataType"
            case .sata: "SPSerialATADataType"
            case .sas: "SPSASDataType"
            case .parallelSCSI: "SPParallelSCSIDataType"
            case .fibreChannel: "SPFibreChannelDataType"
            }
        }

        /// The prefix of its report's own keys ("spnvme_trim_support").
        var prefix: String {
            switch self {
            case .nvme: "spnvme"
            case .sata: "spsata"
            case .sas: "spsas"
            case .parallelSCSI: "spparallelscsi"
            case .fibreChannel: "spfibrechannel"
            }
        }
    }

    public struct Drive: Sendable, Hashable {
        public var name: String
        /// "disk0"; nil when the drive has no disk node.
        public var bsdName: String?
        public var model: String?
        /// Firmware revision.
        public var revision: String?
        /// Identifies the drive, so the machine.
        public var serialNumber: String?
        public var sizeBytes: UInt64?
        /// "Verified", "Failing"; nil when the drive doesn't report SMART status.
        public var smartStatus: String?
        public var supportsTRIM: Bool?
        /// "Solid State", "Rotational".
        public var medium: String?
        public var isRemovable: Bool?
        public var isDetachable: Bool?

        public init(name: String, bsdName: String? = nil, model: String? = nil, revision: String? = nil, serialNumber: String? = nil,
                    sizeBytes: UInt64? = nil, smartStatus: String? = nil, supportsTRIM: Bool? = nil, medium: String? = nil,
                    isRemovable: Bool? = nil, isDetachable: Bool? = nil) {
            self.name = name
            self.bsdName = bsdName
            self.model = model
            self.revision = revision
            self.serialNumber = serialNumber
            self.sizeBytes = sizeBytes
            self.smartStatus = smartStatus
            self.supportsTRIM = supportsTRIM
            self.medium = medium
            self.isRemovable = isRemovable
            self.isDetachable = isDetachable
        }

        /// SMART status is good: anything but "Verified" deserves a look.
        public var isVerified: Bool? {
            smartStatus.map { $0.caseInsensitiveCompare("Verified") == .orderedSame }
        }
    }

    public var bus: Bus
    /// "Apple SSD Controller", "Intel 6 Series Chipset".
    public var name: String
    public var vendor: String?
    /// The PCIe link: "x4", "8.0 GT/s"; SATA's negotiated speed in `linkSpeed`.
    public var linkWidth: String?
    public var linkSpeed: String?
    public var drives: [Drive]

    public init(bus: Bus, name: String, vendor: String? = nil, linkWidth: String? = nil, linkSpeed: String? = nil, drives: [Drive] = []) {
        self.bus = bus
        self.name = name
        self.vendor = vendor
        self.linkWidth = linkWidth
        self.linkSpeed = linkSpeed
        self.drives = drives
    }

    /// "x4 at 8.0 GT/s", "6 Gigabit".
    public var link: String? {
        switch (linkWidth, linkSpeed) {
        case let (width?, speed?): "\(width) at \(speed)"
        case let (width?, nil): width
        case let (nil, speed?): speed
        case (nil, nil): nil
        }
    }
}

/// An SD card reader Apple builds in (or the external one some Macs have),
/// from `system_profiler SPCardReaderDataType`.
public struct CardReader: Sendable, Hashable {
    public struct Card: Sendable, Hashable {
        /// "SDHC Card".
        public var name: String
        public var productName: String?
        public var sizeBytes: UInt64?
        /// Identifies the card.
        public var serialNumber: String?

        public init(name: String, productName: String? = nil, sizeBytes: UInt64? = nil, serialNumber: String? = nil) {
            self.name = name
            self.productName = productName
            self.sizeBytes = sizeBytes
            self.serialNumber = serialNumber
        }
    }

    public var isBuiltIn: Bool
    /// PCI vendor and device IDs: "0x17a0", "0x9755".
    public var vendorID: String?
    public var deviceID: String?
    /// The PCIe link, "Off" while no card is in.
    public var linkSpeed: String?
    public var cards: [Card]

    public init(isBuiltIn: Bool, vendorID: String? = nil, deviceID: String? = nil, linkSpeed: String? = nil, cards: [Card] = []) {
        self.isBuiltIn = isBuiltIn
        self.vendorID = vendorID
        self.deviceID = deviceID
        self.linkSpeed = linkSpeed
        self.cards = cards
    }
}

/// Smart cards as CryptoTokenKit sees them, from `system_profiler
/// SPSmartCardsDataType` (the slot manager itself needs an entitlement),
/// with the USB devices that offer a smart-card (CCID) interface from the
/// I/O Registry. Read-only: no card is ever opened or asked anything.
public struct SmartCardReport: Sendable, Hashable {
    public struct Reader: Sendable, Hashable {
        public var name: String
        /// A card is in it (the reader reports the card's answer to reset).
        public var hasCard: Bool

        public init(name: String, hasCard: Bool) {
            self.name = name
            self.hasCard = hasCard
        }
    }

    /// A driver bundle: "fr.apdu.ccid.smartcardccid" 1.5.1.
    public struct Driver: Sendable, Hashable {
        public var id: String
        public var version: String?

        public init(id: String, version: String?) {
            self.id = id
            self.version = version
        }

        /// "fr.apdu.ccid.smartcardccid:1.5.1 (/usr/libexec/…/ifd-ccid.bundle)".
        static func parse(_ text: String) -> Driver? {
            let identity = text.split(separator: " (", maxSplits: 1).first.map(String.init) ?? text
            let parts = identity.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let id = parts.first, !id.isEmpty else { return nil }
            return Driver(id: id, version: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
        }
    }

    /// Readers CryptoTokenKit lists.
    public var readers: [Reader]
    public var readerDrivers: [Driver]
    /// Drivers for kinds of card ("com.apple.CryptoTokenKit.pivtoken").
    public var tokenDrivers: [Driver]
    /// Cards present now, by token ID ("com.apple.pivtoken:3F2A…", which
    /// identifies the card). The Secure Enclave's own token is left out.
    public var tokens: [String]
    /// USB devices with a smart-card interface, by product name, whether or
    /// not a driver took them; nil when the I/O Registry wasn't read.
    public var usbDevices: [String]?

    public init(readers: [Reader] = [], readerDrivers: [Driver] = [], tokenDrivers: [Driver] = [], tokens: [String] = [],
                usbDevices: [String]? = nil) {
        self.readers = readers
        self.readerDrivers = readerDrivers
        self.tokenDrivers = tokenDrivers
        self.tokens = tokens
        self.usbDevices = usbDevices
    }

    /// The token's driver, without the card's identity: "com.apple.pivtoken".
    public static func tokenKind(_ token: String) -> String {
        token.split(separator: ":", maxSplits: 1).first.map(String.init) ?? token
    }
}

/// The specialised hardware on the System page: memory details, storage
/// controllers, card readers and smart cards. One `system_profiler` run of
/// a few data types (a quarter of a second to a second), so it's read only
/// when the page first needs it and again on Refresh, never per sample.
public struct HardwareInventory: Sendable, Hashable {
    public var memory: DeviceReading<MemoryDetails>
    /// Every controller found on the buses read; empty when there are none
    /// (a virtual machine's disk has none).
    public var storageControllers: DeviceReading<[StorageController]>
    public var cardReaders: DeviceReading<[CardReader]>
    public var smartCards: DeviceReading<SmartCardReport>

    public init(memory: DeviceReading<MemoryDetails>, storageControllers: DeviceReading<[StorageController]>,
                cardReaders: DeviceReading<[CardReader]>, smartCards: DeviceReading<SmartCardReport>) {
        self.memory = memory
        self.storageControllers = storageControllers
        self.cardReaders = cardReaders
        self.smartCards = smartCards
    }

    public static let unavailable = HardwareInventory(memory: .unavailable, storageControllers: .unavailable, cardReaders: .unavailable,
                                                      smartCards: .unavailable)

    public static let dataTypes = ["SPMemoryDataType"] + StorageController.Bus.allCases.map(\.dataType)
        + ["SPCardReaderDataType", "SPSmartCardsDataType"]

    /// The controller and drive behind a disk ("disk0").
    public func drive(bsdName: String) -> (controller: StorageController, drive: StorageController.Drive)? {
        for controller in storageControllers.value ?? [] {
            if let drive = controller.drives.first(where: { $0.bsdName == bsdName }) { return (controller, drive) }
        }
        return nil
    }

    // MARK: - Parsing

    /// Parses `system_profiler -json` output for `dataTypes`. A data type
    /// missing from it is unavailable; `usbSmartCardDevices` comes from the
    /// I/O Registry.
    public static func parse(_ data: Data, usbSmartCardDevices: [String]? = nil) -> HardwareInventory {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            var inventory = HardwareInventory.unavailable
            if let usbSmartCardDevices { inventory.smartCards = .read(SmartCardReport(usbDevices: usbSmartCardDevices)) }
            return inventory
        }
        func items(_ key: String) -> [[String: Any]]? { root[key] as? [[String: Any]] }
        let buses = StorageController.Bus.allCases.compactMap { bus in items(bus.dataType).map { (bus, $0) } }
        let smartCards = items("SPSmartCardsDataType").map { parseSmartCards($0, usbDevices: usbSmartCardDevices) }
            ?? usbSmartCardDevices.map { SmartCardReport(usbDevices: $0) }
        return HardwareInventory(
            memory: items("SPMemoryDataType").map { .read(parseMemory($0)) } ?? .unavailable,
            storageControllers: buses.isEmpty ? .unavailable : .read(buses.flatMap { parseControllers($1, bus: $0) }),
            cardReaders: items("SPCardReaderDataType").map { .read(parseCardReaders($0)) } ?? .unavailable,
            smartCards: smartCards.map { .read($0) } ?? .unavailable
        )
    }

    /// Trimmed, and nil when blank or a placeholder for "doesn't know".
    static func reported(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "unknown", "not available", "not provided", "n/a", "empty": return nil
        default: return text
        }
    }

    static func yesNo(_ value: Any?) -> Bool? {
        switch (value as? String)?.lowercased() {
        case "yes", "true": true
        case "no", "false": false
        default: nil
        }
    }

    static func parseMemory(_ entries: [[String: Any]]) -> MemoryDetails {
        var details = MemoryDetails()
        for entry in entries {
            details.type = details.type ?? reported(entry["dimm_type"])
            details.manufacturer = details.manufacturer ?? reported(entry["dimm_manufacturer"])
            details.size = details.size ?? reported(entry["SPMemoryDataType"]) ?? reported(entry["dimm_size"])
            details.isUpgradeable = details.isUpgradeable ?? yesNo(entry["is_memory_upgradeable"])
            if let ecc = entry["global_ecc_state"] as? String {
                details.ecc = switch ecc {
                case "ecc_enabled": "Enabled"
                case "ecc_disabled": "Disabled"
                case "ecc_errors": "Errors"
                default: reported(ecc)
                }
            }
            for item in entry["_items"] as? [[String: Any]] ?? [] {
                let status = item["dimm_status"] as? String
                let isEmpty = status == "empty" || (item["dimm_size"] as? String)?.lowercased() == "empty"
                let state: String? = switch status {
                case "ok": "OK"
                case "mapped_out": "Mapped Out"
                case "empty", nil: nil
                default: reported(status)
                }
                details.modules.append(MemoryDetails.Module(
                    slot: reported(item["_name"]) ?? "Slot \(details.modules.count + 1)",
                    size: isEmpty ? nil : reported(item["dimm_size"]),
                    type: isEmpty ? nil : reported(item["dimm_type"]),
                    speed: isEmpty ? nil : reported(item["dimm_speed"]),
                    manufacturer: isEmpty ? nil : reported(item["dimm_manufacturer"]),
                    partNumber: isEmpty ? nil : reported(item["dimm_part_number"]),
                    serialNumber: isEmpty ? nil : reported(item["dimm_serial_number"]),
                    isEmpty: isEmpty,
                    status: state
                ))
            }
        }
        return details
    }

    /// Each controller in one bus's report, with every drive found under
    /// it at any depth (SAS and Fibre Channel nest domains and targets).
    static func parseControllers(_ entries: [[String: Any]], bus: StorageController.Bus) -> [StorageController] {
        let prefix = bus.prefix
        return entries.map { entry in
            var drives: [StorageController.Drive] = []
            func walk(_ items: [[String: Any]]) {
                for item in items {
                    if item["bsd_name"] != nil || item["device_model"] != nil || item["size_in_bytes"] != nil {
                        drives.append(drive(item, prefix: prefix))
                    } else {
                        walk(item["_items"] as? [[String: Any]] ?? [])
                    }
                }
            }
            walk(entry["_items"] as? [[String: Any]] ?? [])
            return StorageController(
                bus: bus, name: reported(entry["_name"]) ?? bus.title,
                vendor: reported(entry["\(prefix)_vendor"]),
                linkWidth: reported(entry["\(prefix)_linkwidth"]),
                linkSpeed: reported(entry["\(prefix)_negotiatedlinkspeed"]) ?? reported(entry["\(prefix)_linkspeed"])
                    ?? reported(entry["\(prefix)_portspeed"]),
                drives: drives
            )
        }
    }

    private static func drive(_ item: [String: Any], prefix: String) -> StorageController.Drive {
        let model = reported(item["device_model"]) ?? reported(item["\(prefix)_product"])
        return StorageController.Drive(
            name: reported(item["_name"]) ?? model ?? "Drive",
            bsdName: reported(item["bsd_name"]),
            model: model,
            revision: reported(item["device_revision"]) ?? reported(item["\(prefix)_revision"]),
            serialNumber: reported(item["device_serial"]),
            sizeBytes: (item["size_in_bytes"] as? NSNumber)?.uint64Value,
            smartStatus: reported(item["smart_status"]),
            supportsTRIM: yesNo(item["\(prefix)_trim_support"]),
            medium: reported(item["\(prefix)_medium_type"]),
            isRemovable: yesNo(item["removable_media"]),
            isDetachable: yesNo(item["detachable_drive"])
        )
    }

    static func parseCardReaders(_ entries: [[String: Any]]) -> [CardReader] {
        entries.map { entry in
            let cards = (entry["_items"] as? [[String: Any]] ?? []).map { item in
                CardReader.Card(
                    name: reported(item["_name"]) ?? "Card",
                    productName: reported(item["spcardreader_card_productname"]),
                    sizeBytes: (item["size_in_bytes"] as? NSNumber)?.uint64Value,
                    serialNumber: reported(item["spcardreader_card_serialnumber"])
                )
            }
            return CardReader(
                isBuiltIn: entry["_name"] as? String != "spcardreader_external",
                vendorID: reported(entry["spcardreader_vendor-id"]),
                deviceID: reported(entry["spcardreader_device-id"]),
                linkSpeed: reported(entry["spcardreader_link-speed"]),
                cards: cards
            )
        }
    }

    static func parseSmartCards(_ entries: [[String: Any]], usbDevices: [String]?) -> SmartCardReport {
        func numbered(_ name: String) -> [String] {
            guard let entry = entries.first(where: { $0["_name"] as? String == name }) else { return [] }
            return entry.filter { $0.key.hasPrefix("#") }.sorted { $0.key < $1.key }.compactMap { $0.value as? String }
        }
        let readers = numbered("READERS").map { text in
            let name = text.components(separatedBy: " (ATR").first?.trimmingCharacters(in: .whitespaces) ?? text
            return SmartCardReport.Reader(name: name.isEmpty ? text : name, hasCard: text.contains("ATR"))
        }
        let tokenEntry = entries.first { $0["_name"] as? String == "AVAIL_SMARTCARDS_TOKEN" }
        let tokens = (tokenEntry?["_items"] as? [[String: Any]] ?? []).compactMap { $0["_name"] as? String }
            .filter { SmartCardReport.tokenKind($0) != "com.apple.setoken" }
        return SmartCardReport(
            readers: readers,
            readerDrivers: numbered("READERS_DRIVERS").compactMap(SmartCardReport.Driver.parse),
            tokenDrivers: numbered("SMARTCARDS_DRIVERS").compactMap(SmartCardReport.Driver.parse),
            tokens: tokens,
            usbDevices: usbDevices
        )
    }
}

/// Runs `system_profiler` for `HardwareInventory` and looks for USB
/// smart-card interfaces in the I/O Registry. Blocks; call it off the main
/// thread, when the page first needs it or on Refresh.
public enum HardwareInventoryReader {
    public static func read(timeout: TimeInterval = 20) -> HardwareInventory {
        let usb = usbSmartCardDevices()
        let arguments = ["-json", "-timeout", String(Int(timeout / 2))] + HardwareInventory.dataTypes
        guard let result = CommandRunner.execute("/usr/sbin/system_profiler", arguments, capture: .output, timeout: timeout),
              result.status == 0 else {
            return HardwareInventory.parse(Data(), usbSmartCardDevices: usb)
        }
        return HardwareInventory.parse(Data(result.text.utf8), usbSmartCardDevices: usb)
    }

    /// USB interfaces of class 11 (smart card, CCID), by their device's product name.
    static func usbSmartCardDevices() -> [String] {
        var names: [String] = []
        IORegistry.forEachService(matching: "IOUSBHostInterface") { interface in
            let properties = IORegistry.properties(of: interface)
            guard properties.int("bInterfaceClass") == 11 else { return }
            let name = (properties.string("USB Product Name") ?? properties.string("kUSBProductString"))?
                .trimmingCharacters(in: .whitespaces)
            names.append(name.flatMap { $0.isEmpty ? nil : $0 } ?? "USB smart-card reader")
        }
        return names
    }
}
