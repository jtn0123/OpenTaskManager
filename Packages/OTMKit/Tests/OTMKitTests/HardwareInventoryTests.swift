import Foundation
@testable import OTMKit
import Testing

/// `system_profiler` reports for memory, storage controllers, card readers
/// and smart cards, captured without administrator rights (serial numbers
/// replaced), and the rows the System page builds from them.
struct HardwareInventoryTests {
    private static let smartCardsNone = """
      "SPSmartCardsDataType" : [
        { "_name" : "READERS" },
        { "_name" : "READERS_DRIVERS",
          "#01" : "fr.apdu.ccid.smartcardccid:1.5.1 (/usr/libexec/SmartCardServices/drivers/ifd-ccid.bundle)" },
        { "_name" : "SMARTCARDS_DRIVERS",
          "#01" : "com.apple.CryptoTokenKit.pivtoken:1.0 (/System/Library/Frameworks/CryptoTokenKit.framework/PlugIns/pivtoken.appex)",
          "#02" : "com.apple.PlatformSSO.AccessKey:1.0 (/System/Library/ExtensionKit/Extensions/AccessKey.appex)" },
        { "_items" : [ { "_name" : "com.apple.setoken" }, { "_name" : "com.apple.setoken:aks" } ], "_name" : "AVAIL_SMARTCARDS_KEYCHAIN" },
        { "_items" : [ { "_name" : "com.apple.setoken" }, { "_name" : "com.apple.setoken:aks" } ], "_name" : "AVAIL_SMARTCARDS_TOKEN" }
      ]
    """

    /// A MacBook Pro with an M-series chip: unified memory with no slots, the
    /// SSD on Apple's controller, an empty SD slot, no smart cards.
    private static let laptop = """
    {
      "SPCardReaderDataType" : [ {
        "_items" : [ ], "_name" : "spcardreader", "spcardreader_device-id" : "0x9755", "spcardreader_link-speed" : "Off",
        "spcardreader_link-width" : "Off", "spcardreader_revision-id" : "0x0002", "spcardreader_subsystem_vendor-id" : "0x17a0",
        "spcardreader_subsystem-id" : "0x9755", "spcardreader_vendor-id" : "0x17a0"
      } ],
      "SPFibreChannelDataType" : [ ],
      "SPMemoryDataType" : [ { "dimm_manufacturer" : "Micron", "dimm_type" : "LPDDR5", "SPMemoryDataType" : "48 GB" } ],
      "SPNVMeDataType" : [ { "_items" : [ {
        "_name" : "APPLE SSD AP1024Z", "bsd_name" : "disk0", "detachable_drive" : "no", "device_model" : "APPLE SSD AP1024Z",
        "device_revision" : "241.40.4", "device_serial" : "0000TESTSERIAL01", "partition_map_type" : "guid_partition_map_type",
        "removable_media" : "no", "size" : "1 TB", "size_in_bytes" : 1000555581440, "smart_status" : "Verified",
        "spnvme_trim_support" : "Yes",
        "volumes" : [ { "_name" : "Macintosh HD", "bsd_name" : "disk0s2", "iocontent" : "Apple_APFS", "size_in_bytes" : 994610155520 } ]
      } ], "_name" : "Apple SSD Controller" } ],
      "SPParallelSCSIDataType" : [ ],
      "SPSASDataType" : [ ],
      "SPSerialATADataType" : [ ],
    \(smartCardsNone)
    }
    """

    /// A virtual machine: memory macOS can't describe, a paravirtual disk on
    /// no controller system_profiler knows, no readers.
    private static let virtualMachine = """
    {
      "SPCardReaderDataType" : [ ],
      "SPFibreChannelDataType" : [ ],
      "SPMemoryDataType" : [ { "dimm_manufacturer" : "Unknown", "dimm_type" : "unknown", "SPMemoryDataType" : "8 GB" } ],
      "SPNVMeDataType" : [ ],
      "SPParallelSCSIDataType" : [ ],
      "SPSASDataType" : [ ],
      "SPSerialATADataType" : [ ],
    \(smartCardsNone)
    }
    """

    /// Shaped like an Intel desktop's report: four slots, two filled (one
    /// turned off after errors), a SATA hard disk failing SMART, a SAS
    /// card with a disk two levels down, an SD card in an external reader
    /// and a smart card in a USB reader.
    private static let desktop = """
    {
      "SPCardReaderDataType" : [ {
        "_items" : [ { "_name" : "SDXC Card", "spcardreader_card_productname" : "SD64G",
                       "spcardreader_card_serialnumber" : "0xTESTCARD", "size_in_bytes" : 63864569856 } ],
        "_name" : "spcardreader_external", "spcardreader_vendor-id" : "0x05ac", "spcardreader_device-id" : "0x8406",
        "spcardreader_link-speed" : "5.0 GT/s"
      } ],
      "SPMemoryDataType" : [ {
        "_items" : [
          { "_name" : "DIMM1", "dimm_manufacturer" : "0x802C", "dimm_part_number" : "16KTF1G64HZ-1G6E1",
            "dimm_serial_number" : "0xTEST0001", "dimm_size" : "8 GB", "dimm_speed" : "2667 MHz", "dimm_status" : "ok",
            "dimm_type" : "DDR4" },
          { "_name" : "DIMM2", "dimm_size" : "empty", "dimm_status" : "empty", "dimm_type" : "empty" },
          { "_name" : "DIMM3", "dimm_manufacturer" : "0x802C", "dimm_part_number" : "16KTF1G64HZ-1G6E1",
            "dimm_serial_number" : "0xTEST0003", "dimm_size" : "8 GB", "dimm_speed" : "2667 MHz", "dimm_status" : "mapped_out",
            "dimm_type" : "DDR4" },
          { "_name" : "DIMM4", "dimm_size" : "empty", "dimm_status" : "empty" }
        ],
        "global_ecc_state" : "ecc_disabled", "is_memory_upgradeable" : "Yes"
      } ],
      "SPSerialATADataType" : [ {
        "_items" : [ { "_name" : "WDC WD10EZEX", "bsd_name" : "disk2", "device_model" : "WDC WD10EZEX-08WN4A0",
                       "device_revision" : "01.01A01", "device_serial" : "WD-TEST0001", "removable_media" : "no",
                       "size_in_bytes" : 1000204886016, "smart_status" : "Failing", "spsata_medium_type" : "Rotational",
                       "spsata_trim_support" : "No" } ],
        "_name" : "Intel 200 Series Chipset", "spsata_vendor" : "Intel", "spsata_negotiatedlinkspeed" : "6 Gigabit"
      } ],
      "SPSASDataType" : [ {
        "_items" : [ { "_name" : "Domain 1", "_items" : [ { "_name" : "Target 0", "bsd_name" : "disk4",
                                                             "spsas_product" : "ST4000NM0035", "spsas_revision" : "TN04" } ] } ],
        "_name" : "SAS Controller", "spsas_linkwidth" : "x8", "spsas_linkspeed" : "8.0 GT/s"
      } ],
      "SPSmartCardsDataType" : [
        { "_name" : "READERS", "#01" : "Yubico YubiKey OTP+FIDO+CCID (ATR:{length = 23, bytes = 0x3bfd1300008131fe15})" },
        { "_name" : "READERS_DRIVERS" },
        { "_name" : "SMARTCARDS_DRIVERS", "#01" : "com.example.token" },
        { "_items" : [ { "_name" : "com.apple.setoken" }, { "_name" : "com.apple.pivtoken:3F2A0000TESTTOKEN" } ],
          "_name" : "AVAIL_SMARTCARDS_TOKEN" }
      ]
    }
    """

    private static func parse(_ json: String, usb: [String]? = []) -> HardwareInventory {
        HardwareInventory.parse(Data(json.utf8), usbSmartCardDevices: usb)
    }

    private func value(_ label: String, in rows: [InfoRow]) -> String? {
        rows.first { $0.label == label }?.value
    }

    // MARK: - Parsing

    @Test func appleSiliconReportsUnifiedMemoryWithoutSlots() throws {
        let inventory = Self.parse(Self.laptop)
        let memory = try #require(inventory.memory.value)
        #expect(memory.type == "LPDDR5" && memory.manufacturer == "Micron" && memory.size == "48 GB")
        #expect(memory.modules.isEmpty)
        #expect(memory.isUpgradeable == nil && memory.ecc == nil)

        let controllers = try #require(inventory.storageControllers.value)
        #expect(controllers.count == 1)
        #expect(controllers[0].bus == .nvme && controllers[0].name == "Apple SSD Controller" && controllers[0].link == nil)
        // The drive's partitions aren't drives.
        #expect(controllers[0].drives == [StorageController.Drive(
            name: "APPLE SSD AP1024Z", bsdName: "disk0", model: "APPLE SSD AP1024Z", revision: "241.40.4", serialNumber: "0000TESTSERIAL01",
            sizeBytes: 1_000_555_581_440, smartStatus: "Verified", supportsTRIM: true, medium: nil, isRemovable: false,
            isDetachable: false
        )])
        #expect(inventory.drive(bsdName: "disk0")?.controller.name == "Apple SSD Controller")
        #expect(inventory.drive(bsdName: "disk3") == nil)

        #expect(inventory.cardReaders.value == [CardReader(isBuiltIn: true, vendorID: "0x17a0", deviceID: "0x9755", linkSpeed: "Off")])

        let cards = try #require(inventory.smartCards.value)
        #expect(cards.readers.isEmpty)
        #expect(cards.readerDrivers == [.init(id: "fr.apdu.ccid.smartcardccid", version: "1.5.1")])
        #expect(cards.tokenDrivers.map(\.id) == ["com.apple.CryptoTokenKit.pivtoken", "com.apple.PlatformSSO.AccessKey"])
        // The Secure Enclave's own token isn't a card.
        #expect(cards.tokens.isEmpty)
        #expect(cards.usbDevices == [])
    }

    @Test func aVirtualMachinesUnknownsStayUnknown() throws {
        let inventory = Self.parse(Self.virtualMachine, usb: nil)
        let memory = try #require(inventory.memory.value)
        // Never guessed from the chip.
        #expect(memory.type == nil && memory.manufacturer == nil && memory.size == "8 GB")
        #expect(inventory.storageControllers.value == [])
        #expect(inventory.cardReaders.value == [])
        #expect(inventory.smartCards.value?.usbDevices == nil)
    }

    @Test func slotsControllersAndReadersOnADesktop() throws {
        let inventory = Self.parse(Self.desktop, usb: ["YubiKey OTP+FIDO+CCID"])
        let memory = try #require(inventory.memory.value)
        #expect(memory.type == nil && memory.reportedType == "DDR4" && memory.reportedManufacturer == "0x802C")
        #expect(memory.isUpgradeable == true && memory.ecc == "Disabled")
        #expect(memory.modules.map(\.slot) == ["DIMM1", "DIMM2", "DIMM3", "DIMM4"])
        #expect(memory.modules.map(\.isEmpty) == [false, true, false, true])
        #expect(memory.modules.map(\.status) == ["OK", nil, "Mapped Out", nil])
        #expect(memory.modules[1] == MemoryDetails.Module(slot: "DIMM2", isEmpty: true))
        #expect(memory.modules[0].serialNumber == "0xTEST0001" && memory.modules[0].speed == "2667 MHz")

        let controllers = try #require(inventory.storageControllers.value)
        #expect(controllers.map(\.bus) == [.sata, .sas])
        #expect(controllers[0].vendor == "Intel" && controllers[0].link == "6 Gigabit")
        let disk = try #require(controllers[0].drives.first)
        #expect(disk.isVerified == false && disk.supportsTRIM == false && disk.medium == "Rotational")
        // Found two levels down, named by the bus's own keys.
        #expect(controllers[1].link == "x8 at 8.0 GT/s")
        #expect(controllers[1].drives == [.init(name: "Target 0", bsdName: "disk4", model: "ST4000NM0035", revision: "TN04")])
        // Buses missing from the report are left out, not unavailable.
        #expect(inventory.drive(bsdName: "disk4")?.controller.bus == .sas)

        let reader = try #require(inventory.cardReaders.value?.first)
        #expect(!reader.isBuiltIn && reader.linkSpeed == "5.0 GT/s")
        #expect(reader.cards == [.init(name: "SDXC Card", productName: "SD64G", sizeBytes: 63_864_569_856, serialNumber: "0xTESTCARD")])

        let cards = try #require(inventory.smartCards.value)
        #expect(cards.readers == [.init(name: "Yubico YubiKey OTP+FIDO+CCID", hasCard: true)])
        #expect(cards.readerDrivers.isEmpty)
        #expect(cards.tokenDrivers == [.init(id: "com.example.token", version: nil)])
        #expect(cards.tokens == ["com.apple.pivtoken:3F2A0000TESTTOKEN"])
        #expect(SmartCardReport.tokenKind(cards.tokens[0]) == "com.apple.pivtoken")
    }

    @Test func missingReportsAreUnavailable() {
        let none = Self.parse("not json", usb: ["Reader"])
        #expect(none.memory == .unavailable && none.storageControllers == .unavailable && none.cardReaders == .unavailable)
        // The I/O Registry still answered.
        #expect(none.smartCards.value == SmartCardReport(usbDevices: ["Reader"]))
        #expect(Self.parse("not json", usb: nil) == .unavailable)

        let partial = Self.parse("{ \"SPMemoryDataType\" : [ ], \"SPSASDataType\" : [ ] }", usb: nil)
        #expect(partial.memory.value == MemoryDetails())
        #expect(partial.storageControllers.value == [])
        #expect(partial.cardReaders == .unavailable && partial.smartCards == .unavailable)
    }

    @Test func placeholdersAndDriversParse() {
        for blank in ["Unknown", "unknown", "Not Available", "N/A", "empty", "  ", ""] {
            #expect(HardwareInventory.reported(blank) == nil, "\(blank)")
        }
        #expect(HardwareInventory.reported(" Samsung ") == "Samsung")
        #expect(HardwareInventory.reported(42) == nil)
        #expect(HardwareInventory.yesNo("Yes") == true && HardwareInventory.yesNo("no") == false && HardwareInventory.yesNo("x") == nil)

        #expect(SmartCardReport.Driver.parse("fr.apdu.ccid.smartcardccid:1.5.1 (/usr/libexec/ifd-ccid.bundle)")
            == .init(id: "fr.apdu.ccid.smartcardccid", version: "1.5.1"))
        #expect(SmartCardReport.Driver.parse("com.example.token:") == .init(id: "com.example.token", version: nil))
        #expect(SmartCardReport.Driver.parse(":1.0") == nil)
        #expect(HardwareInventory.dataTypes.count == 8)
    }

    // MARK: - Rows

    @Test func memoryRowsSayWhatWasntReported() {
        #expect(SystemReport.memoryDetails(nil).map(\.value) == ["Checking…", "Checking…"])
        let unread = SystemReport.memoryDetails(.unavailable)
        #expect(unread.map(\.value) == ["Couldn't read", "Couldn't read"] && unread.allSatisfy { $0.status == .unknown })

        let laptop = SystemReport.memoryDetails(Self.parse(Self.laptop))
        #expect(laptop.map(\.label) == ["Type", "Manufacturer"])
        #expect(laptop.map(\.value) == ["LPDDR5", "Micron"])

        let virtual = SystemReport.memoryDetails(Self.parse(Self.virtualMachine))
        #expect(virtual.map(\.value) == ["Not reported", "Not reported"])
    }

    @Test func memoryRowsListSlotsWithSerialsHidden() {
        let rows = SystemReport.memoryDetails(Self.parse(Self.desktop))
        #expect(rows.map(\.label) == ["Type", "Manufacturer", "Upgradeable", "ECC", "Slots", "Modules", "Serial numbers"])
        #expect(value("Type", in: rows) == "DDR4")
        #expect(value("Slots", in: rows) == "2 of 4 in use")
        #expect(value("Modules", in: rows) == """
        DIMM1: 8 GB DDR4 2667 MHz, 0x802C 16KTF1G64HZ-1G6E1
        DIMM2: empty
        DIMM3: 8 GB DDR4 2667 MHz, 0x802C 16KTF1G64HZ-1G6E1 (Mapped Out)
        DIMM4: empty
        """)
        #expect(rows.first { $0.label == "Modules" }?.status == .warning)
        let serials = rows.first { $0.label == "Serial numbers" }
        #expect(serials?.isSensitive == true && serials?.value == "DIMM1: 0xTEST0001\nDIMM3: 0xTEST0003")
    }

    @Test func eachDriveSaysHowItsAttached() {
        func disk(_ interconnect: String?, _ location: String?) -> DiskInfo {
            DiskInfo(bsdName: "disk0", model: nil, isInternal: nil, isSolidState: nil, size: nil, interconnect: interconnect,
                     interconnectLocation: location)
        }
        #expect(SystemReport.connection(disk("Apple Fabric", "Internal")) == "Apple Fabric, internal")
        #expect(SystemReport.connection(disk("USB", nil)) == "USB")
        // A virtual machine's disk names no bus.
        #expect(SystemReport.connection(disk(nil, "Internal")) == "Internal, bus not reported")
        #expect(SystemReport.connection(disk(nil, nil)) == nil)

        let laptop = SystemReport.driveDetails("disk0", hardware: Self.parse(Self.laptop))
        #expect(laptop.map(\.label) == ["Controller", "SMART status", "TRIM", "Firmware", "Serial number"])
        #expect(value("Controller", in: laptop) == "Apple SSD Controller (NVMe)")
        #expect(laptop[1].status == .good && value("TRIM", in: laptop) == "Supported")
        #expect(laptop.last?.isSensitive == true)
        #expect(SystemReport.driveDetails("disk0", hardware: nil).isEmpty)

        let failing = SystemReport.driveDetails("disk2", hardware: Self.parse(Self.desktop))
        #expect(value("SMART status", in: failing) == "Failing" && failing[1].status == .warning)
        #expect(value("TRIM", in: failing) == "Not supported")
    }

    @Test func controllersCardOnALaptop() {
        #expect(SystemReport.controllers(nil).map(\.value) == ["Checking…"])
        let rows = SystemReport.controllers(Self.parse(Self.laptop))
        #expect(rows.filter(\.isHeading).map(\.label) == ["Apple SSD Controller", "SD card reader", "Smart cards"])
        #expect(rows.filter(\.isHeading).map(\.headingNote) == ["NVMe storage", "built-in", ""])
        #expect(value("Drive", in: rows) == "APPLE SSD AP1024Z (disk0), " + SystemFacts.decimalBytes(1_000_555_581_440))
        #expect(value("Card", in: rows) == "None inserted")
        #expect(value("PCI vendor:device", in: rows) == "17a0:9755")
        #expect(value("Readers", in: rows) == "None connected")
        #expect(value("Cards present", in: rows) == "None")
        #expect(value("Reader drivers", in: rows) == "fr.apdu.ccid.smartcardccid 1.5.1")
        #expect(value("Card drivers", in: rows) == "com.apple.CryptoTokenKit.pivtoken 1.0\ncom.apple.PlatformSSO.AccessKey 1.0")
        #expect(!rows.contains { $0.label == "On USB" || $0.isSensitive })
    }

    @Test func controllersCardWhenThereAreNoneOrItCouldntRead() {
        let virtual = SystemReport.controllers(Self.parse(Self.virtualMachine))
        #expect(virtual.first?.label == "Storage controllers" && virtual.first?.value == "None reported")
        #expect(value("Reader", in: virtual) == "None")

        let unread = SystemReport.controllers(.unavailable)
        #expect(unread.filter { $0.value == "Couldn't read" }.map(\.label) == ["Storage controllers", "Reader", "Readers"])
        #expect(unread.filter { $0.value == "Couldn't read" }.allSatisfy { $0.status == .unknown })
    }

    @Test func controllersCardWithCardsIn() {
        let rows = SystemReport.controllers(Self.parse(Self.desktop, usb: ["YubiKey OTP+FIDO+CCID", "Card Reader X"]))
        #expect(rows.filter(\.isHeading).map(\.headingNote) == ["SATA storage", "SAS storage", "external", ""])
        #expect(value("Vendor", in: rows) == "Intel")
        #expect(value("Card", in: rows) == "SDXC Card (SD64G), " + SystemFacts.decimalBytes(63_864_569_856))
        #expect(rows.first { $0.label == "Card serial" }?.isSensitive == true)
        #expect(value("Readers", in: rows) == "Yubico YubiKey OTP+FIDO+CCID (card in)")
        // One more smart-card device on USB than readers: one hasn't a driver.
        #expect(value("On USB", in: rows) == "YubiKey OTP+FIDO+CCID\nCard Reader X")
        #expect(value("Cards present", in: rows) == "1 (com.apple.pivtoken)")
        #expect(rows.first { $0.label == "Card tokens" }?.isSensitive == true)
        #expect(value("Reader drivers", in: rows) == "None")

        let matched = SystemReport.controllers(Self.parse(Self.desktop, usb: ["YubiKey OTP+FIDO+CCID"]))
        #expect(value("On USB", in: matched) == nil)
    }

    @Test func driverNamesBreakAfterTheirDotsNotMidWord() {
        let drivers = "com.apple.CryptoTokenKit.pivtoken 1.0\ncom.apple.PlatformSSO.AccessKey 1.0"
        let forms = AddressBreaks.dottedForms(drivers)
        // The longest name in two even lines, the other as long; versions stay with their names.
        #expect(forms.first == "com.apple.CryptoTokenKit.\npivtoken 1.0\ncom.apple.PlatformSSO.\nAccessKey 1.0")
        #expect(forms.last == "com.apple.\nCryptoTokenKit.\npivtoken 1.0\ncom.apple.\nPlatformSSO.\nAccessKey 1.0")
        #expect(forms.count == 2)
        #expect(AddressBreaks.dottedForms("fr.apdu.ccid.smartcardccid 1.5.1").first == "fr.apdu.ccid.\nsmartcardccid 1.5.1")
        #expect(AddressBreaks.dottedGroups("EQHXZ8M8AV.com.google.Chrome") == ["EQHXZ8M8AV.", "com.", "google.", "Chrome"])
        // Not names: too few parts, addresses, a path, versions alone.
        for other in ["Managed-Virtual-Machine.local", "192.168.64.5/24", "192.168.64.5", "/Users/admin/Shares", "1.5", "1.5.1", "None",
                      "a..b.c"] {
            #expect(AddressBreaks.dottedGroups(other) == nil, "\(other)")
        }
        #expect(AddressBreaks.dottedForms("disk0").isEmpty)
    }

    // MARK: - Text and JSON

    @Test func hardwareTextLeavesSerialsOutUnlessAsked() {
        let inventory = Self.parse(Self.desktop)
        let text = SystemReport.hardwareText(inventory, includeIdentifiers: false)
        #expect(text.hasPrefix("Memory\n  Type: DDR4\n  Manufacturer: 0x802C\n"))
        #expect(text.contains("\n\nControllers and Readers\n  Intel 200 Series Chipset (SATA storage)\n    Vendor: Intel\n"))
        for secret in ["0xTEST0001", "0xTESTCARD", "3F2A0000TESTTOKEN"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }
        let all = SystemReport.hardwareText(inventory, includeIdentifiers: true)
        #expect(all.contains("  Serial numbers: DIMM1: 0xTEST0001\n                  DIMM3: 0xTEST0003\n"))
        #expect(all.contains("3F2A0000TESTTOKEN"))
    }

    @Test func hardwareJSONLeavesSerialsAndTokensOut() throws {
        let inventory = Self.parse(Self.desktop, usb: ["YubiKey OTP+FIDO+CCID"])
        let collected = Date(timeIntervalSince1970: 1_791_259_488)
        let data = try SystemReportDocument.hardwareJSON(inventory, includeIdentifiers: false, collectedAt: collected)
        let text = try #require(String(data: data, encoding: .utf8))
        for secret in ["0xTEST0001", "0xTEST0003", "WD-TEST0001", "0xTESTCARD", "3F2A0000TESTTOKEN"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["format", "schemaVersion", "collectedAt", "includesIdentifiers", "hardwareDetails"])
        let details = try #require(json["hardwareDetails"] as? [String: Any])
        let memory = try #require(details["memory"] as? [String: Any])
        // The report's own type, not the slots': null here.
        #expect(memory["type"] is NSNull && memory["isUpgradeable"] as? Bool == true && memory["ecc"] as? String == "Disabled")
        let modules = try #require(memory["modules"] as? [[String: Any]])
        #expect(modules.map { $0["isEmpty"] as? Bool } == [false, true, false, true])
        #expect(modules[0]["serialNumber"] is NSNull && modules[2]["status"] as? String == "Mapped Out")
        let controllers = try #require(details["storageControllers"] as? [[String: Any]])
        #expect(controllers.map { $0["bus"] as? String } == ["sata", "sas"])
        let drive = try #require((controllers[0]["drives"] as? [[String: Any]])?.first)
        #expect(drive["serialNumber"] is NSNull && drive["smartStatus"] as? String == "Failing" && drive["supportsTRIM"] as? Bool == false)
        let readers = try #require(details["cardReaders"] as? [[String: Any]])
        #expect(readers.first?["isBuiltIn"] as? Bool == false)
        let cards = try #require(details["smartCards"] as? [String: Any])
        #expect(cards["cardCount"] as? Int == 1 && cards["cardKinds"] as? [String] == ["com.apple.pivtoken"])
        #expect(cards["cardTokens"] is NSNull && cards["usbDevices"] as? [String] == ["YubiKey OTP+FIDO+CCID"])

        let shown = try SystemReportDocument.hardwareJSON(inventory, includeIdentifiers: true, collectedAt: collected)
        let shownText = try #require(String(data: shown, encoding: .utf8))
        for secret in ["0xTEST0001", "WD-TEST0001", "0xTESTCARD", "3F2A0000TESTTOKEN"] {
            #expect(shownText.contains(secret), "\(secret) missing")
        }

        let unread = try SystemReportDocument.hardwareJSON(.unavailable, includeIdentifiers: false, collectedAt: collected)
        let unreadDetails = try #require((JSONSerialization.jsonObject(with: unread) as? [String: Any])?["hardwareDetails"] as? [String: Any])
        for key in ["memory", "storageControllers", "cardReaders", "smartCards"] {
            #expect(unreadDetails[key] is NSNull, "\(key)")
        }
    }
}
