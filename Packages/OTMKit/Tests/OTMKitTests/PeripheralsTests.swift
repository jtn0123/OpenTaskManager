import Foundation
@testable import OTMKit
import Testing

struct PeripheralParsingTests {
    /// A MacBook Pro on macOS 27 with a flash drive in: the new USB report,
    /// three idle USB4 ports, no paired Bluetooth devices.
    private static let laptop = """
    {
      "SPAudioDataType" : [ { "_items" : [
        { "_name" : "MacBook Pro Microphone", "coreaudio_default_audio_input_device" : "spaudio_yes", "coreaudio_device_input" : 1,
          "coreaudio_device_manufacturer" : "Apple Inc.", "coreaudio_device_srate" : 48000,
          "coreaudio_device_transport" : "coreaudio_device_type_builtin" },
        { "_name" : "MacBook Pro Speakers", "coreaudio_default_audio_output_device" : "spaudio_yes",
          "coreaudio_default_audio_system_device" : "spaudio_yes", "coreaudio_device_manufacturer" : "Apple Inc.",
          "coreaudio_device_output" : 2, "coreaudio_device_srate" : 44100,
          "coreaudio_device_transport" : "coreaudio_device_type_builtin" }
      ], "_name" : "coreaudio_device" } ],
      "SPBluetoothDataType" : [ { "controller_properties" : {
        "controller_address" : "C0:C7:DB:00:00:01", "controller_chipset" : "Apple N1",
        "controller_firmwareVersion" : "MAC FW Version: 26.216.0.0, PHY FW Version: 3.1.205.0", "controller_state" : "attrib_on" } } ],
      "SPCameraDataType" : [ { "_name" : "MacBook Pro Camera", "spcamera_model-id" : "MacBook Pro Camera" } ],
      "SPThunderboltDataType" : [
        { "_name" : "thunderboltusb4_bus_1", "device_name_key" : "MacBook Pro",
          "receptacle_1_tag" : { "current_speed_key" : "Up to 120 Gb/s", "receptacle_id_key" : "2",
                                 "receptacle_status_key" : "receptacle_no_devices_connected" } },
        { "_name" : "thunderboltusb4_bus_0", "device_name_key" : "MacBook Pro",
          "receptacle_1_tag" : { "current_speed_key" : "Up to 120 Gb/s", "receptacle_id_key" : "1",
                                 "receptacle_status_key" : "receptacle_no_devices_connected" } }
      ],
      "SPUSBDataType" : [ ],
      "SPUSBHostDataType" : [
        { "_name" : "USB 4.0 Bus", "Driver" : "AppleT6050USBXHCIAUSS", "USBKeyHardwareType" : "Built-in" },
        { "_items" : [ { "_name" : " SanDisk 3.2 Gen1", "USBDeviceKeyLinkSpeed" : "5 Gb/s",
                         "USBDeviceKeyPowerAllocation" : "4.48 W (896 mA)", "USBDeviceKeyProductID" : "0x55fd",
                         "USBDeviceKeySerialNumber" : "03017022120225210315", "USBDeviceKeyVendorID" : "0x0781",
                         "USBDeviceKeyVendorName" : " USB", "USBKeyHardwareType" : "Removable" } ],
          "_name" : "USB 3.1 Bus", "Driver" : "AppleT8142USBXHCI", "USBKeyHardwareType" : "Built-in" }
      ]
    }
    """

    /// A macOS 26 virtual machine: no Thunderbolt, no cameras, Bluetooth off.
    private static let virtualMachine = """
    {
      "SPAudioDataType" : [ { "_items" : [ { "_name" : "Apple Virtual Sound Device", "coreaudio_device_input" : 2,
        "coreaudio_device_output" : 2, "coreaudio_default_audio_output_device" : "spaudio_yes",
        "coreaudio_device_transport" : "coreaudio_device_type_builtin" } ], "_name" : "coreaudio_device" } ],
      "SPBluetoothDataType" : [ { "controller_properties" : { "controller_chipset" : "APPLE_VIRTUAL",
        "controller_firmwareVersion" : "v0", "controller_state" : "attrib_off" } } ],
      "SPCameraDataType" : [ ],
      "SPThunderboltDataType" : [ { "Thunderbolt" : "no_hardware" } ],
      "SPUSBDataType" : [ ],
      "SPUSBHostDataType" : [ { "_items" : [
        { "_name" : "Virtual USB Keyboard", "USBDeviceKeyLinkSpeed" : "12 Mb/s", "USBDeviceKeySerialNumber" : "Not Provided",
          "USBDeviceKeyVendorID" : "0x05ac", "USBDeviceKeyProductID" : "0x8105", "USBDeviceKeyVendorName" : "Apple Inc." }
      ], "_name" : "USB 3.1 Bus" } ]
    }
    """

    private func parse(_ json: String) -> PeripheralInventory {
        PeripheralInventory.parse(Data(json.utf8))
    }

    @Test func readsTheNewUSBReport() throws {
        let usb = try #require(parse(Self.laptop).usb.value)
        #expect(usb.buses == 2)
        let drive = try #require(usb.devices.first)
        #expect(usb.devices.count == 1)
        // Padding is trimmed; "Not Provided" serials and blank names are dropped elsewhere.
        #expect(drive.name == "SanDisk 3.2 Gen1")
        #expect(drive.vendor == "USB")
        #expect(drive.idPair == "0781:55fd")
        #expect(drive.speed == "5 Gb/s")
        #expect(drive.power == "4.48 W (896 mA)")
        #expect(drive.serialNumber == "03017022120225210315")
        #expect(drive.bus == "USB 3.1 Bus" && drive.hub == nil && drive.depth == 0 && !drive.isBuiltIn)

        let keyboard = try #require(parse(Self.virtualMachine).usb.value?.devices.first)
        #expect(keyboard.serialNumber == nil)
        #expect(keyboard.idPair == "05ac:8105")
    }

    @Test func readsTheOlderUSBReportWithHubs() throws {
        let json = """
        { "SPUSBDataType" : [ { "_name" : "USB31Bus", "_items" : [
            { "_name" : "USB3.1 Hub", "vendor_id" : "0x05e3  (Genesys Logic, Inc.)", "product_id" : "0x0626",
              "speed" : "up_to_5_Gb_per_sec", "_items" : [
                { "_name" : "Keyboard", "vendor_id" : "apple_vendor_id", "product_id" : "0x029c", "speed" : "up_to_12_Mb_per_sec",
                  "bus_power_used" : "100", "serial_num" : "ABC" },
                { "_name" : "Thing", "vendor_id" : "0x1234", "manufacturer" : "Maker Co", "speed" : "super_speed_plus" }
              ] }
        ] } ] }
        """
        let usb = try #require(parse(json).usb.value)
        #expect(usb.buses == 1)
        #expect(usb.devices.map(\.name) == ["USB3.1 Hub", "Keyboard", "Thing"])
        let hub = usb.devices[0]
        #expect(hub.vendor == "Genesys Logic, Inc.")
        #expect(hub.idPair == "05e3:0626")
        #expect(hub.speed == "Up to 5 Gb/s")
        let keyboard = usb.devices[1]
        #expect(keyboard.vendor == "Apple Inc." && keyboard.vendorID == 0x05AC)
        #expect(keyboard.hub == "USB3.1 Hub" && keyboard.depth == 1 && keyboard.bus == "USB31Bus")
        #expect(keyboard.power == "100 mA")
        #expect(keyboard.speed == "Up to 12 Mb/s")
        #expect(usb.devices[2].vendor == "Maker Co")
        #expect(usb.devices[2].speed == "Super speed plus")
        // No product ID, no pair.
        #expect(usb.devices[2].idPair == nil)
    }

    @Test func tellsAMissingReportFromAnEmptyOne() {
        let empty = parse(#"{ "SPUSBHostDataType" : [ ], "SPCameraDataType" : [ ], "SPAudioDataType" : [ ] }"#)
        #expect(empty.usb == .read(USBReport(buses: 0, devices: [])))
        #expect(empty.cameras == .read([]))
        #expect(empty.audio == .read([]))
        #expect(empty.thunderbolt == .unavailable)
        #expect(empty.bluetooth == .unavailable)

        #expect(parse("not json") == .unavailable)
        #expect(parse("[]") == .unavailable)
    }

    @Test func readsThunderboltPortsAndChains() throws {
        let laptop = try #require(parse(Self.laptop).thunderbolt.value)
        #expect(laptop.hasHardware)
        #expect(laptop.ports == [.init(speed: "Up to 120 Gb/s", isInUse: false), .init(speed: "Up to 120 Gb/s", isInUse: false)])
        #expect(laptop.devices.isEmpty)

        let none = try #require(parse(Self.virtualMachine).thunderbolt.value)
        #expect(!none.hasHardware)

        let json = """
        { "SPThunderboltDataType" : [ { "_name" : "thunderbolt_bus_0", "device_name_key" : "Mac mini",
            "receptacle_1_tag" : { "receptacle_id_key" : "1", "receptacle_status_key" : "receptacle_connected",
                                   "current_speed_key" : "Up to 40 Gb/s" },
            "_items" : [ { "device_name_key" : "TS4", "vendor_name_key" : "CalDigit, Inc.",
                           "receptacle_upstream_ambiguous_tag" : { "current_speed_key" : "Up to 40 Gb/s x1" },
                           "_items" : [ { "device_name_key" : "Studio Display", "vendor_name_key" : "Apple Inc." } ] } ] } ] }
        """
        let chained = try #require(parse(json).thunderbolt.value)
        #expect(chained.ports == [.init(speed: "Up to 40 Gb/s", isInUse: true)])
        #expect(chained.devices == [
            .init(name: "TS4", vendor: "CalDigit, Inc.", speed: "Up to 40 Gb/s x1", upstream: nil, depth: 0),
            .init(name: "Studio Display", vendor: "Apple Inc.", speed: nil, upstream: "TS4", depth: 1),
        ])
    }

    @Test func readsBluetoothDevicesConnectedFirst() throws {
        let json = """
        { "SPBluetoothDataType" : [ {
            "controller_properties" : { "controller_state" : "attrib_on", "controller_chipset" : "BCM_4387" },
            "device_not_connected" : [ { "Magic Keyboard" : { "device_address" : "AA:BB:CC:DD:EE:01", "device_minorType" : "Keyboard" } } ],
            "device_connected" : [ { "AirPods Pro" : { "device_address" : "AA:BB:CC:DD:EE:02", "device_minorType" : "Headphones",
                "device_batteryLevelLeft" : "80%", "device_batteryLevelRight" : "75%", "device_batteryLevelCase" : "40%",
                "device_firmwareVersion" : "7A305" } } ]
        } ] }
        """
        let bluetooth = try #require(parse(json).bluetooth.value)
        #expect(bluetooth.isOn == true)
        #expect(bluetooth.chipset == "BCM_4387")
        #expect(bluetooth.devices.map(\.name) == ["AirPods Pro", "Magic Keyboard"])
        let pods = bluetooth.devices[0]
        #expect(pods.isConnected && pods.kind == "Headphones" && pods.firmware == "7A305")
        #expect(pods.batteries == [.init(part: "Left", percent: 80), .init(part: "Right", percent: 75), .init(part: "Case", percent: 40)])
        #expect(!bluetooth.devices[1].isConnected)

        let laptop = try #require(parse(Self.laptop).bluetooth.value)
        #expect(laptop.firmware == "26.216.0.0")
        #expect(laptop.devices.isEmpty)
        let virtual = try #require(parse(Self.virtualMachine).bluetooth.value)
        #expect(virtual.isOn == false && virtual.chipset == "Virtual")
    }

    @Test func readsAudioDevicesAndCameras() throws {
        let inventory = parse(Self.laptop)
        let audio = try #require(inventory.audio.value)
        #expect(audio.map(\.name) == ["MacBook Pro Microphone", "MacBook Pro Speakers"])
        #expect(audio[0].inputChannels == 1 && audio[0].outputChannels == 0 && audio[0].isDefaultInput && !audio[0].isDefaultOutput)
        #expect(audio[1].outputChannels == 2 && audio[1].isDefaultOutput && audio[1].isDefaultSystemOutput)
        #expect(audio[1].sampleRate == 44100)
        #expect(audio[0].transport == "Built-in")
        #expect(inventory.cameras == .read([CameraDevice(name: "MacBook Pro Camera", model: "MacBook Pro Camera")]))

        #expect(PeripheralInventory.describeAudioTransport("coreaudio_device_type_usb") == "USB")
        #expect(PeripheralInventory.describeAudioTransport("coreaudio_device_type_new_kind") == "New kind")
    }

    @Test func readsHexIdentifiers() {
        #expect(PeripheralInventory.hexNumber("0x0781") == 0x0781)
        #expect(PeripheralInventory.hexNumber("0x05ac  (Apple Inc.)") == 0x05AC)
        #expect(PeripheralInventory.hexNumber("apple_vendor_id") == nil)
        #expect(PeripheralInventory.hexNumber(nil) == nil)
    }
}

struct DeviceReportTests {
    private func rows(_ kind: InfoSection.Kind, _ inventory: PeripheralInventory) -> [InfoRow] {
        SystemReport.deviceSections(inventory).first { $0.kind == kind }?.rows ?? []
    }

    @Test func listsUSBDevicesUnderTheirHub() {
        let inventory = PeripheralInventory(
            usb: .read(USBReport(buses: 1, devices: [
                USBDevice(name: "Hub", speed: "5 Gb/s", bus: "USB 3.1 Bus"),
                USBDevice(name: "Drive", vendor: "SanDisk", vendorID: 0x0781, productID: 0x55FD, power: "4.48 W (896 mA)",
                          serialNumber: "S123", bus: "USB 3.1 Bus", hub: "Hub", depth: 1),
            ])),
            thunderbolt: .read(ThunderboltReport(ports: [], devices: [])), bluetooth: .unavailable, audio: .read([]), cameras: .read([])
        )
        let usb = rows(.usb, inventory)
        // Each device is one compact row: its name, speed and depth behind hubs.
        #expect(usb.filter(\.isHeading) == [InfoRow("Hub", "5 Gb/s", isHeading: true), InfoRow("Drive", "", isHeading: true, depth: 1)])
        // The rest waits behind its disclosure.
        #expect(usb.filter { !$0.isHeading }.allSatisfy { $0.isDetail })
        #expect(usb.contains(InfoRow("Connected to", "USB 3.1 Bus", isDetail: true)))
        #expect(usb.contains(InfoRow("Connected to", "Hub", isDetail: true)))
        #expect(usb.contains(InfoRow("Power", "4.48 W (896 mA)", isDetail: true)))
        #expect(usb.contains(InfoRow("Vendor:product", "0781:55fd", isCode: true, isDetail: true)))
        #expect(usb.first { $0.label == "Serial number" }?.isSensitive == true)

        // No Thunderbolt hardware, no card; a failed report says so rather than "None".
        let kinds = SystemReport.deviceSections(inventory).map(\.kind)
        #expect(kinds == [.usb, .bluetooth, .audio])
        #expect(rows(.bluetooth, inventory) == [InfoRow("Devices", "Couldn't read", status: .unknown)])
        #expect(rows(.audio, inventory) == [InfoRow("Devices", "None found")])
    }

    @Test func summarisesPortsAndDevices() {
        let inventory = PeripheralInventory(
            usb: .read(USBReport(buses: 2, devices: [])),
            thunderbolt: .read(ThunderboltReport(
                ports: [.init(speed: "Up to 120 Gb/s", isInUse: true), .init(speed: "Up to 120 Gb/s", isInUse: false)],
                devices: [.init(name: "Dock", vendor: "CalDigit", speed: "Up to 40 Gb/s", upstream: nil)]
            )),
            bluetooth: .read(BluetoothReport(isOn: true, chipset: "Apple N1", firmware: "26.216.0.0", devices: [
                BluetoothDevice(name: "AirPods", kind: "Headphones", isConnected: true, address: "AA:BB",
                                batteries: [.init(part: "Left", percent: 80), .init(part: nil, percent: 50)]),
            ])),
            audio: .read([AudioDevice(name: "Speakers", manufacturer: "Apple Inc.", outputChannels: 2, sampleRate: 44100,
                                      transport: "Built-in", isDefaultOutput: true, isDefaultSystemOutput: true)]),
            cameras: .unavailable
        )
        #expect(rows(.usb, inventory) == [InfoRow("Devices", "None connected")])
        let thunderbolt = rows(.thunderbolt, inventory)
        #expect(thunderbolt.prefix(2) == [InfoRow("Ports", "2, up to 120 Gb/s each"), InfoRow("In use", "1 of 2")])
        #expect(thunderbolt.contains(InfoRow("Dock", "Up to 40 Gb/s", isHeading: true)))
        #expect(thunderbolt.contains(InfoRow("Maker", "CalDigit", isDetail: true)))
        #expect(thunderbolt.contains(InfoRow("Connected to", "This Mac", isDetail: true)))
        let bluetooth = rows(.bluetooth, inventory)
        #expect(bluetooth.contains(InfoRow("Chipset", "Apple N1 · firmware 26.216.0.0")))
        // The battery is the status worth seeing without opening the device.
        #expect(bluetooth.contains(InfoRow("AirPods", "connected", isHeading: true, state: "battery Left 80% · 50%")))
        #expect(bluetooth.contains(InfoRow("Kind", "Headphones", isDetail: true)))
        #expect(!bluetooth.contains { $0.label == "Battery" })
        let audio = rows(.audio, inventory)
        #expect(audio.contains(InfoRow("Speakers", "built-in", isHeading: true, state: "default for output and alerts")))
        #expect(audio.contains(InfoRow("Channels", "2 out", isDetail: true)))
        #expect(audio.contains(InfoRow("Sample rate", "44.1 kHz", isDetail: true)))
        #expect(audio.contains(InfoRow("Maker", "Apple Inc.", isDetail: true)))
        #expect(audio.last == InfoRow("Cameras", "Couldn't read", status: .unknown))

        // The text keeps every fact, the heading's status included.
        let text = SystemReport.deviceText(inventory, includeIdentifiers: false)
        #expect(text.hasPrefix("USB\n  Devices: None connected\n\nThunderbolt and USB4\n"))
        #expect(text.contains("  AirPods (connected, battery Left 80% · 50%)\n    Kind: Headphones\n"))
        #expect(text.contains("  Speakers (built-in, default for output and alerts)\n    Channels: 2 out\n    Sample rate: 44.1 kHz\n"))
        #expect(text.contains("  Dock (Up to 40 Gb/s)\n    Maker: CalDigit\n    Connected to: This Mac\n"))
        #expect(!text.contains("AA:BB"))
        #expect(SystemReport.deviceText(inventory, includeIdentifiers: true).contains("    Address: AA:BB"))
    }

    @Test func groupsEachDeviceWithItsDetails() throws {
        let inventory = PeripheralInventory(
            usb: .read(USBReport(buses: 1, devices: [])), thunderbolt: .unavailable,
            bluetooth: .read(BluetoothReport(isOn: true, chipset: "Apple N1", firmware: nil, devices: [
                BluetoothDevice(name: "Mouse", kind: "Mouse", isConnected: true),
                BluetoothDevice(name: "Keyboard", isConnected: false),
            ])),
            audio: .read([]), cameras: .read([])
        )
        let sections = SystemReport.deviceSections(inventory)
        let bluetooth = try #require(sections.first { $0.kind == .bluetooth })
        #expect(bluetooth.hasDetails)
        #expect(bluetooth.blocks == [
            .rows([InfoRow("Status", "On"), InfoRow("Chipset", "Apple N1")]),
            .device(InfoRow("Mouse", "connected", isHeading: true), details: [InfoRow("Kind", "Mouse", isDetail: true)]),
            // Nothing more to show: a row with no disclosure.
            .device(InfoRow("Keyboard", "not connected", isHeading: true), details: []),
        ])
        let usb = try #require(sections.first { $0.kind == .usb })
        #expect(!usb.hasDetails)
        #expect(usb.blocks == [.rows([InfoRow("Devices", "None connected")])])

        #expect(sections.allSatisfy { $0.kind.isAttachedDevice })
        #expect(InfoSection.Kind.allCases.filter(\.isAttachedDevice) == [.usb, .thunderbolt, .bluetooth, .audio])
    }

    @Test func headingNoteJoinsValueAndState() {
        #expect(InfoRow("Drive", "5 Gb/s", isHeading: true, state: "built-in").headingNote == "5 Gb/s, built-in")
        #expect(InfoRow("Drive", "", isHeading: true, state: "built-in").headingNote == "built-in")
        #expect(InfoRow("Drive", "5 Gb/s", isHeading: true).headingNote == "5 Gb/s")
        #expect(InfoRow("Drive", "", isHeading: true).headingNote.isEmpty)
    }

    @Test func saysCheckingUntilTheReportArrives() {
        let sections = SystemReport.deviceSections(nil)
        #expect(sections.map(\.kind) == [.usb, .bluetooth, .audio])
        #expect(sections.allSatisfy { $0.rows == [InfoRow("Devices", "Checking…")] })
    }
}

/// Runs the real `system_profiler`, so only checks that every category came back.
@Suite(.serialized)
struct LivePeripheralTests {
    @Test func readsThisMac() {
        let inventory = PeripheralReader.read()
        #expect(inventory.usb != .unavailable)
        #expect(inventory.audio != .unavailable)
        #expect(inventory.bluetooth != .unavailable)
        #expect(inventory.thunderbolt != .unavailable)
        #expect(inventory.cameras != .unavailable)
    }
}
