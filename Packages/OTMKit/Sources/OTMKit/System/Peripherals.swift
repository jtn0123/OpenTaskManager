import Foundation

/// One category of attached devices: what was read, which may be nothing,
/// or a report that didn't arrive. Keeps "none connected" from standing in
/// for a category macOS didn't describe.
public enum DeviceReading<Value: Sendable & Hashable>: Sendable, Hashable {
    case read(Value)
    case unavailable

    public var value: Value? {
        if case let .read(value) = self { value } else { nil }
    }
}

/// The value itself in JSON, or null when the category couldn't be read.
extension DeviceReading: Encodable where Value: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}

/// A USB device, in the order of the bus tree: a hub comes before the
/// devices plugged into it, which name it as their `hub`.
public struct USBDevice: Sendable, Hashable, Encodable {
    public var name: String
    public var vendor: String?
    public var vendorID: Int?
    public var productID: Int?
    /// The negotiated link speed, as macOS words it ("5 Gb/s").
    public var speed: String?
    /// Power the Mac set aside for it ("4.48 W (896 mA)").
    public var power: String?
    public var serialNumber: String?
    /// Part of the Mac rather than plugged in.
    public var isBuiltIn = false
    /// The controller it hangs off ("USB 3.1 Bus").
    public var bus: String
    /// The hub it's plugged into; nil when it's on the bus directly.
    public var hub: String?
    /// Hubs between it and the bus.
    public var depth = 0

    public init(name: String, vendor: String? = nil, vendorID: Int? = nil, productID: Int? = nil, speed: String? = nil,
                power: String? = nil, serialNumber: String? = nil, isBuiltIn: Bool = false, bus: String, hub: String? = nil,
                depth: Int = 0) {
        self.name = name
        self.vendor = vendor
        self.vendorID = vendorID
        self.productID = productID
        self.speed = speed
        self.power = power
        self.serialNumber = serialNumber
        self.isBuiltIn = isBuiltIn
        self.bus = bus
        self.hub = hub
        self.depth = depth
    }

    /// "0781:55fd", the vendor and product IDs as they're usually looked up.
    public var idPair: String? {
        guard let vendorID, let productID else { return nil }
        return String(format: "%04x:%04x", vendorID, productID)
    }
}

/// The USB buses and everything on them.
public struct USBReport: Sendable, Hashable, Encodable {
    public var buses: Int
    public var devices: [USBDevice]

    public init(buses: Int, devices: [USBDevice]) {
        self.buses = buses
        self.devices = devices
    }
}

/// Thunderbolt and USB4 ports, and devices chained off them.
public struct ThunderboltReport: Sendable, Hashable, Encodable {
    public struct Port: Sendable, Hashable, Encodable {
        public var speed: String?
        public var isInUse: Bool

        public init(speed: String?, isInUse: Bool) {
            self.speed = speed
            self.isInUse = isInUse
        }
    }

    public struct Device: Sendable, Hashable, Encodable {
        public var name: String
        public var vendor: String?
        public var speed: String?
        /// The device it's chained from; nil when it's plugged into the Mac.
        public var upstream: String?

        public init(name: String, vendor: String?, speed: String?, upstream: String?) {
            self.name = name
            self.vendor = vendor
            self.speed = speed
            self.upstream = upstream
        }
    }

    public var ports: [Port]
    public var devices: [Device]

    public init(ports: [Port], devices: [Device]) {
        self.ports = ports
        self.devices = devices
    }

    /// False on a Mac (or virtual machine) without Thunderbolt.
    public var hasHardware: Bool { !ports.isEmpty || !devices.isEmpty }
}

public struct BluetoothDevice: Sendable, Hashable, Encodable {
    public struct Battery: Sendable, Hashable, Encodable {
        /// "Left", "Right", "Case", or nil for a single battery.
        public var part: String?
        public var percent: Int

        public init(part: String?, percent: Int) {
            self.part = part
            self.percent = percent
        }
    }

    public var name: String
    /// What it is, as macOS classes it ("Headphones", "Keyboard").
    public var kind: String?
    public var isConnected: Bool
    public var address: String?
    public var firmware: String?
    public var batteries: [Battery]

    public init(name: String, kind: String? = nil, isConnected: Bool, address: String? = nil, firmware: String? = nil,
                batteries: [Battery] = []) {
        self.name = name
        self.kind = kind
        self.isConnected = isConnected
        self.address = address
        self.firmware = firmware
        self.batteries = batteries
    }
}

/// The Bluetooth controller and the devices paired with it, connected first.
public struct BluetoothReport: Sendable, Hashable, Encodable {
    public var isOn: Bool?
    public var chipset: String?
    public var firmware: String?
    public var devices: [BluetoothDevice]

    public init(isOn: Bool?, chipset: String?, firmware: String?, devices: [BluetoothDevice]) {
        self.isOn = isOn
        self.chipset = chipset
        self.firmware = firmware
        self.devices = devices
    }
}

public struct AudioDevice: Sendable, Hashable, Encodable {
    public var name: String
    public var manufacturer: String?
    public var inputChannels: Int
    public var outputChannels: Int
    public var sampleRate: Double?
    /// How it's connected, in words ("Built-in", "USB", "Bluetooth").
    public var transport: String?
    public var isDefaultInput = false
    public var isDefaultOutput = false
    /// Plays alerts and sound effects.
    public var isDefaultSystemOutput = false

    public init(name: String, manufacturer: String? = nil, inputChannels: Int = 0, outputChannels: Int = 0, sampleRate: Double? = nil,
                transport: String? = nil, isDefaultInput: Bool = false, isDefaultOutput: Bool = false,
                isDefaultSystemOutput: Bool = false) {
        self.name = name
        self.manufacturer = manufacturer
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.transport = transport
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
        self.isDefaultSystemOutput = isDefaultSystemOutput
    }
}

public struct CameraDevice: Sendable, Hashable, Encodable {
    public var name: String
    public var model: String?

    public init(name: String, model: String?) {
        self.name = name
        self.model = model
    }
}

/// What's attached to this Mac, from one `system_profiler` report.
public struct PeripheralInventory: Sendable, Hashable, Encodable {
    public var usb: DeviceReading<USBReport>
    public var thunderbolt: DeviceReading<ThunderboltReport>
    public var bluetooth: DeviceReading<BluetoothReport>
    public var audio: DeviceReading<[AudioDevice]>
    public var cameras: DeviceReading<[CameraDevice]>

    public init(usb: DeviceReading<USBReport>, thunderbolt: DeviceReading<ThunderboltReport>, bluetooth: DeviceReading<BluetoothReport>,
                audio: DeviceReading<[AudioDevice]>, cameras: DeviceReading<[CameraDevice]>) {
        self.usb = usb
        self.thunderbolt = thunderbolt
        self.bluetooth = bluetooth
        self.audio = audio
        self.cameras = cameras
    }

    /// When the report couldn't be run or read at all.
    public static let unavailable = PeripheralInventory(
        usb: .unavailable, thunderbolt: .unavailable, bluetooth: .unavailable, audio: .unavailable, cameras: .unavailable
    )

    /// The report's data types, newest USB format first. macOS 26 renamed
    /// the USB report (`SPUSBHostDataType`); earlier versions only have
    /// `SPUSBDataType`, and each version answers an unknown type with nothing.
    public static let dataTypes = [
        "SPUSBHostDataType", "SPUSBDataType", "SPThunderboltDataType", "SPBluetoothDataType", "SPAudioDataType", "SPCameraDataType",
    ]

    /// Parses `system_profiler -json` output. A data type missing from the
    /// report is unavailable; one present but empty was read and found nothing.
    public static func parse(_ data: Data) -> PeripheralInventory {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable }
        func items(_ key: String) -> [[String: Any]]? { root[key] as? [[String: Any]] }
        return PeripheralInventory(
            usb: parseUSB(host: items("SPUSBHostDataType"), legacy: items("SPUSBDataType")),
            thunderbolt: items("SPThunderboltDataType").map { .read(parseThunderbolt($0)) } ?? .unavailable,
            bluetooth: items("SPBluetoothDataType").map { .read(parseBluetooth($0)) } ?? .unavailable,
            audio: items("SPAudioDataType").map { .read(parseAudio($0)) } ?? .unavailable,
            cameras: items("SPCameraDataType").map { .read(parseCameras($0)) } ?? .unavailable
        )
    }

    // MARK: - USB

    static func parseUSB(host: [[String: Any]]?, legacy: [[String: Any]]?) -> DeviceReading<USBReport> {
        // Whichever report found buses; the new one when both are empty.
        if let host, !host.isEmpty || (legacy ?? []).isEmpty {
            return .read(USBReport(buses: host.count, devices: host.flatMap { usbDevices(on: $0, legacy: false) }))
        }
        if let legacy {
            return .read(USBReport(buses: legacy.count, devices: legacy.flatMap { usbDevices(on: $0, legacy: true) }))
        }
        return .unavailable
    }

    private static func usbDevices(on bus: [String: Any], legacy: Bool) -> [USBDevice] {
        let busName = cleaned(bus.string("_name")) ?? "USB"
        var devices: [USBDevice] = []
        func walk(_ items: [[String: Any]], hub: String?, depth: Int) {
            for item in items {
                let name = cleaned(item.string("_name")) ?? "USB device"
                var device = legacy ? legacyUSBDevice(item, name: name, bus: busName) : hostUSBDevice(item, name: name, bus: busName)
                device.hub = hub
                device.depth = depth
                devices.append(device)
                walk(item["_items"] as? [[String: Any]] ?? [], hub: name, depth: depth + 1)
            }
        }
        walk(bus["_items"] as? [[String: Any]] ?? [], hub: nil, depth: 0)
        return devices
    }

    /// macOS 26 and later: `USBDeviceKey…` fields.
    private static func hostUSBDevice(_ item: [String: Any], name: String, bus: String) -> USBDevice {
        USBDevice(
            name: name,
            vendor: cleaned(item.string("USBDeviceKeyVendorName")),
            vendorID: hexNumber(item.string("USBDeviceKeyVendorID")),
            productID: hexNumber(item.string("USBDeviceKeyProductID")),
            speed: cleaned(item.string("USBDeviceKeyLinkSpeed")),
            power: cleaned(item.string("USBDeviceKeyPowerAllocation")),
            serialNumber: serial(item.string("USBDeviceKeySerialNumber")),
            isBuiltIn: item.string("USBKeyHardwareType") == "Built-in",
            bus: bus
        )
    }

    /// macOS 14 and 15: `vendor_id` reads "0x05ac  (Apple Inc.)", speed "up_to_480_Mb_per_sec".
    private static func legacyUSBDevice(_ item: [String: Any], name: String, bus: String) -> USBDevice {
        let vendorField = item.string("vendor_id")
        let appleVendor = vendorField == "apple_vendor_id"
        var vendor = cleaned(item.string("manufacturer"))
        if vendor == nil, let vendorField, let open = vendorField.firstIndex(of: "("), let close = vendorField.lastIndex(of: ")"),
           open < close {
            vendor = cleaned(String(vendorField[vendorField.index(after: open)..<close]))
        }
        let power = item.string("bus_power_used").flatMap(Int.init).map { "\($0) mA" }
        return USBDevice(
            name: name,
            vendor: vendor ?? (appleVendor ? "Apple Inc." : nil),
            vendorID: appleVendor ? 0x05AC : hexNumber(vendorField),
            productID: hexNumber(item.string("product_id")),
            speed: item.string("speed").map(describeLegacySpeed),
            power: power,
            serialNumber: serial(item.string("serial_num")),
            isBuiltIn: item.string("Built-in_Device") == "Yes",
            bus: bus
        )
    }

    /// "up_to_480_Mb_per_sec" reads "Up to 480 Mb/s"; anything else loses its underscores.
    static func describeLegacySpeed(_ raw: String) -> String {
        let parts = raw.split(separator: "_")
        if parts.count == 6, parts[0] == "up", parts[1] == "to", parts[4] == "per", parts[5] == "sec" {
            return "Up to \(parts[2]) \(parts[3])/s"
        }
        let words = raw.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: - Thunderbolt

    static func parseThunderbolt(_ buses: [[String: Any]]) -> ThunderboltReport {
        var ports: [ThunderboltReport.Port] = []
        var devices: [ThunderboltReport.Device] = []
        func walk(_ items: [[String: Any]], upstream: String?) {
            for item in items {
                let name = cleaned(item.string("device_name_key")) ?? cleaned(item.string("_name")) ?? "Thunderbolt device"
                devices.append(.init(name: name, vendor: cleaned(item.string("vendor_name_key")), speed: linkSpeed(item),
                                     upstream: upstream))
                walk(item["_items"] as? [[String: Any]] ?? [], upstream: name)
            }
        }
        // Each bus is the Mac's own controller; its receptacles are the ports.
        for bus in buses where bus["Thunderbolt"] as? String != "no_hardware" {
            for key in bus.keys.sorted() where key.hasPrefix("receptacle_") && key.hasSuffix("_tag") {
                guard let receptacle = bus.dictionary(key), receptacle["receptacle_id_key"] != nil else { continue }
                let status = receptacle.string("receptacle_status_key")
                ports.append(.init(speed: cleaned(receptacle.string("current_speed_key")),
                                   isInUse: status.map { $0 != "receptacle_no_devices_connected" } ?? false))
            }
            walk(bus["_items"] as? [[String: Any]] ?? [], upstream: nil)
        }
        return ThunderboltReport(ports: ports, devices: devices)
    }

    /// The speed of a device's link back towards the Mac, which the report
    /// keeps in one of its nested receptacle records.
    private static func linkSpeed(_ item: [String: Any]) -> String? {
        for key in item.keys.sorted() where key.hasPrefix("receptacle_") {
            if let speed = cleaned(item.dictionary(key)?.string("current_speed_key")) { return speed }
        }
        return nil
    }

    // MARK: - Bluetooth

    static func parseBluetooth(_ entries: [[String: Any]]) -> BluetoothReport {
        let entry = entries.first ?? [:]
        let controller = entry.dictionary("controller_properties") ?? [:]
        let state = controller.string("controller_state")
        var firmware = cleaned(controller.string("controller_firmwareVersion"))
        // "MAC FW Version: 26.216.0.0, PHY FW Version: 3.1.205.0" reads "26.216.0.0".
        if let text = firmware, text.hasPrefix("MAC FW Version: ") {
            firmware = cleaned(String(text.dropFirst("MAC FW Version: ".count).prefix { $0 != "," }))
        }
        var chipset = cleaned(controller.string("controller_chipset"))
        if chipset == "APPLE_VIRTUAL" { chipset = "Virtual" }
        let devices = bluetoothDevices(entry["device_connected"], connected: true)
            + bluetoothDevices(entry["device_not_connected"], connected: false)
        return BluetoothReport(isOn: state.map { $0 == "attrib_on" }, chipset: chipset, firmware: firmware, devices: devices)
    }

    /// The report lists each device as a one-entry dictionary, its name to its fields.
    private static func bluetoothDevices(_ list: Any?, connected: Bool) -> [BluetoothDevice] {
        guard let list = list as? [[String: Any]] else { return [] }
        return list.flatMap { entry in
            entry.keys.sorted().map { name in
                let fields = entry.dictionary(name) ?? [:]
                let parts: [(key: String, part: String?)] = [
                    ("device_batteryLevelMain", nil), ("device_batteryLevel", nil), ("device_batteryLevelLeft", "Left"),
                    ("device_batteryLevelRight", "Right"), ("device_batteryLevelCase", "Case"),
                ]
                let batteries = parts.compactMap { key, part -> BluetoothDevice.Battery? in
                    guard let text = fields.string(key), let percent = Int(text.trimmingCharacters(in: .init(charactersIn: "% ")))
                    else { return nil }
                    return .init(part: part, percent: percent)
                }
                return BluetoothDevice(
                    name: cleaned(name) ?? "Bluetooth device",
                    kind: cleaned(fields.string("device_minorType")),
                    isConnected: connected,
                    address: cleaned(fields.string("device_address")),
                    firmware: cleaned(fields.string("device_firmwareVersion")),
                    batteries: batteries
                )
            }
        }
    }

    // MARK: - Audio and cameras

    static func parseAudio(_ groups: [[String: Any]]) -> [AudioDevice] {
        groups.flatMap { group -> [AudioDevice] in
            let items = group["_items"] as? [[String: Any]] ?? []
            return items.map(audioDevice)
        }
    }

    private static func audioDevice(_ item: [String: Any]) -> AudioDevice {
        func isDefault(_ key: String) -> Bool { item.string(key) == "spaudio_yes" }
        let transport = item.string("coreaudio_device_transport")
        return AudioDevice(
            name: cleaned(item.string("_name")) ?? "Audio device",
            manufacturer: cleaned(item.string("coreaudio_device_manufacturer")),
            inputChannels: item.int("coreaudio_device_input") ?? 0,
            outputChannels: item.int("coreaudio_device_output") ?? 0,
            sampleRate: item.double("coreaudio_device_srate"),
            transport: transport.map(describeAudioTransport),
            isDefaultInput: isDefault("coreaudio_default_audio_input_device"),
            isDefaultOutput: isDefault("coreaudio_default_audio_output_device"),
            isDefaultSystemOutput: isDefault("coreaudio_default_audio_system_device")
        )
    }

    /// "coreaudio_device_type_usb" reads "USB".
    static func describeAudioTransport(_ raw: String) -> String {
        let kind = raw.hasPrefix("coreaudio_device_type_") ? String(raw.dropFirst("coreaudio_device_type_".count)) : raw
        let known = [
            "builtin": "Built-in", "usb": "USB", "bluetooth": "Bluetooth", "bluetoothle": "Bluetooth LE", "virtual": "Virtual",
            "aggregate": "Aggregate", "airplay": "AirPlay", "hdmi": "HDMI", "displayport": "DisplayPort",
            "thunderbolt": "Thunderbolt", "pci": "PCI", "firewire": "FireWire", "avb": "AVB",
            "continuitycapturewired": "Continuity Camera", "continuitycapturewireless": "Continuity Camera",
        ]
        if let text = known[kind] { return text }
        let words = kind.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func parseCameras(_ items: [[String: Any]]) -> [CameraDevice] {
        items.map { item in
            CameraDevice(name: cleaned(item.string("_name")) ?? "Camera", model: cleaned(item.string("spcamera_model-id")))
        }
    }

    // MARK: - Fields

    /// Trimmed, and nil when blank. Devices pad their names (" SanDisk 3.2 Gen1").
    private static func cleaned(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// "0x0781" and "0x05ac  (Apple Inc.)" read 0x0781 and 0x05AC.
    static func hexNumber(_ text: String?) -> Int? {
        guard let token = text?.split(separator: " ").first, token.lowercased().hasPrefix("0x") else { return nil }
        return Int(token.dropFirst(2), radix: 16)
    }

    private static func serial(_ text: String?) -> String? {
        guard let text = cleaned(text), text != "Not Provided" else { return nil }
        return text
    }
}

/// Runs `system_profiler` for the attached devices. A second or so on a
/// busy Mac, so only when asked: never per sample, never on the main thread.
public enum PeripheralReader {
    public static func read(timeout: TimeInterval = 20) -> PeripheralInventory {
        // system_profiler's own limit first, so it returns what it has rather than nothing.
        let arguments = ["-json", "-timeout", String(Int(timeout / 2))] + PeripheralInventory.dataTypes
        guard let result = CommandRunner.execute("/usr/sbin/system_profiler", arguments, capture: .output, timeout: timeout),
              result.status == 0 else { return .unavailable }
        return PeripheralInventory.parse(Data(result.text.utf8))
    }
}
