import Foundation
@testable import OTMKit
import Testing

/// Save Report's Markdown and JSON, and `otm system report`'s.
struct SystemReportDocumentTests {
    private static let boot = Date(timeIntervalSince1970: 1_791_255_888)
    private static let collected = boot.addingTimeInterval(3_600)
    private static let devicesCollected = boot.addingTimeInterval(3_000)

    private static let info = SystemInfo(
        hardware: MacHardware(modelIdentifier: "Mac17,8", marketingName: "MacBook Pro (16-inch, M5 Pro)", chip: "Apple M5 Pro",
                              physicalMemory: 48 << 30, pageSize: 16_384, kind: .laptop, serialNumber: "SERIAL123",
                              hardwareUUID: "UUID-456"),
        topology: CPUTopology(
            brand: "Apple M5 Pro", architecture: "arm64", physicalCores: 18, logicalCores: 18,
            tiers: [.init(level: 0, name: "Performance", logicalCPUs: 18, physicalCPUs: 18, l2CacheBytes: 16 << 20)],
            tierForCPU: [], l1DataCacheBytes: 128 << 10, l1InstructionCacheBytes: nil, l2CacheBytes: nil, l3CacheBytes: nil,
            isAppleSilicon: true
        ),
        software: SoftwareInfo(productVersion: "27.2", build: "26B5101f", kernelRelease: "27.2.0", kernel: nil, bootTime: boot,
                               computerName: "Test Mac", localHostName: "Test-Mac.local"),
        gpus: [GPUInfo(name: "Apple M5 Pro", coreCount: 20)],
        disks: [DiskInfo(bsdName: "disk0", model: "APPLE SSD", isInternal: true, isSolidState: true, size: 2_000_000_000_000)],
        volumes: [
            VolumeInfo(name: "Macintosh HD", mountPoint: "/", fileSystem: "APFS", totalBytes: 1_994_000_000_000,
                       availableBytes: 1_000_000_000_000, isInternal: true, isRemovable: false, isRoot: true, physicalDisk: "disk0"),
            VolumeInfo(name: "Installer", mountPoint: "/Volumes/Installer", fileSystem: nil, totalBytes: 500_000_000,
                       availableBytes: 1_000_000, isInternal: false, isRemovable: true, isRoot: false, physicalDisk: nil),
        ],
        network: [
            NetworkPortInfo(name: "en0", displayName: "Wi-Fi", kind: .wifi, isUp: true, addresses: ["192.168.1.9", "2001:db8::5"],
                            hardwareAddress: "a4:83:e7:0b:12:9c", linkSpeed: 1_200_000_000),
            // Only a link-local address: the page leaves it out, so the report does.
            NetworkPortInfo(name: "utun0", displayName: "utun0", kind: .vpn, isUp: true, addresses: ["fe80::2"],
                            hardwareAddress: nil, linkSpeed: nil),
        ],
        battery: nil
    )

    private static let display = DisplayInfo(id: 1, name: "Built-in Display", pixelWidth: 3456, pixelHeight: 2234, pointWidth: 1728,
                                             pointHeight: 1117, scale: 2, refreshRate: Double.nan, isBuiltIn: true, isMain: true)

    /// A hub with a drive behind it and a mouse behind that, then a keyboard
    /// on the bus; a dock with a display chained from it; paired AirPods.
    private static let devices = PeripheralInventory(
        usb: .read(USBReport(buses: 1, devices: [
            USBDevice(name: "Hub", vendorID: 0x05E3, productID: 0x0626, speed: "5 Gb/s", bus: "USB 3.1 Bus"),
            USBDevice(name: "Drive [backup]", vendor: "SanDisk", vendorID: 0x0781, productID: 0x55FD, power: "4.48 W (896 mA)",
                      serialNumber: "S123", bus: "USB 3.1 Bus", hub: "Hub", depth: 1),
            USBDevice(name: "Mouse", bus: "USB 3.1 Bus", hub: "Drive [backup]", depth: 2),
            USBDevice(name: "Keyboard", serialNumber: "K789", bus: "USB 3.1 Bus"),
        ])),
        thunderbolt: .read(ThunderboltReport(ports: [.init(speed: "Up to 40 Gb/s", isInUse: true)], devices: [
            .init(name: "TS4", vendor: "CalDigit, Inc.", speed: "Up to 40 Gb/s", upstream: nil, depth: 0),
            .init(name: "Studio Display", vendor: "Apple Inc.", speed: nil, upstream: "TS4", depth: 1),
        ])),
        bluetooth: .read(BluetoothReport(isOn: true, chipset: "Apple N1", firmware: nil, devices: [
            BluetoothDevice(name: "AirPods", kind: "Headphones", isConnected: true, address: "AA:BB:CC:DD:EE:02",
                            batteries: [.init(part: "Left", percent: 80)]),
        ])),
        audio: .read([AudioDevice(name: "Speakers", outputChannels: 2, sampleRate: 48000, transport: "Built-in", isDefaultOutput: true)]),
        cameras: .unavailable
    )

    private func document(devices: PeripheralInventory? = Self.devices, security: SecurityStatus? = nil) -> SystemReportDocument {
        SystemReportDocument(info: Self.info, displays: [Self.display], devices: devices,
                             devicesCollectedAt: devices == nil ? nil : Self.devicesCollected, security: security,
                             collectedAt: Self.collected, generator: "otm test")
    }

    private func object(_ report: SystemReportDocument, includeIdentifiers: Bool) throws -> [String: Any] {
        let data = try report.json(includeIdentifiers: includeIdentifiers)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try #require(value as? [String: Any])
    }

    private func list(_ value: Any?) throws -> [[String: Any]] {
        try #require(value as? [[String: Any]])
    }

    @Test func jsonSaysWhatItIsAndWhen() throws {
        let json = try object(document(), includeIdentifiers: false)
        #expect(json["format"] as? String == "io.github.jtn0123.OpenTaskManager.system-report")
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["generator"] as? String == "otm test")
        #expect(json["collectedAt"] as? String == ISO8601DateFormatter().string(from: Self.collected))
        #expect(json["includesIdentifiers"] as? Bool == false)
        #expect(Set(json.keys) == [
            "format", "schemaVersion", "generator", "collectedAt", "includesIdentifiers", "hardware", "processor", "graphics",
            "displays", "storage", "network", "devices", "battery", "software", "security",
        ])
        let software = try dictionary(json["software"])
        #expect(software["uptimeSeconds"] as? Int == 3_600)
        #expect(software["bootTime"] as? String == ISO8601DateFormatter().string(from: Self.boot))
    }

    @Test func jsonWritesNullForWhatItDoesNotKnow() throws {
        let json = try object(document(devices: nil), includeIdentifiers: false)
        // Present, as null: a reader can tell "not reported" from "not in this version".
        #expect(json["devices"] is NSNull)
        #expect(json["battery"] is NSNull)
        #expect(json["security"] is NSNull)
        let processor = try dictionary(json["processor"])
        #expect(processor["l3CacheBytes"] is NSNull)
        #expect(processor["l1InstructionCacheBytesPerCore"] is NSNull)
        #expect(processor["l1DataCacheBytesPerCore"] as? Int == 128 << 10)
        let software = try dictionary(json["software"])
        #expect(software["kernelBuild"] is NSNull)
        // JSON has no NaN: an unknown refresh rate is null too.
        let display = try #require(list(json["displays"]).first)
        #expect(display["refreshRateHz"] is NSNull)
        #expect(display["scale"] as? Double == 2)
        let storage = try dictionary(json["storage"])
        let disk = try #require(list(storage["disks"]).first)
        #expect(try list(disk["volumes"]).map { $0["name"] as? String } == ["Macintosh HD"])
        let other = try #require(list(storage["otherVolumes"]).first)
        #expect(other["name"] as? String == "Installer" && other["fileSystem"] is NSNull)
    }

    @Test func jsonLeavesIdentifiersOutUnlessAsked() throws {
        let hidden = try object(document(), includeIdentifiers: false)
        let hardware = try dictionary(hidden["hardware"])
        #expect(hardware["serialNumber"] is NSNull)
        #expect(hardware["hardwareUUID"] is NSNull)
        #expect(hardware["modelIdentifier"] as? String == "Mac17,8")
        let network = try list(hidden["network"])
        #expect(network.map { $0["name"] as? String } == ["en0"])
        #expect(network[0]["addresses"] is NSNull)
        #expect(network[0]["hardwareAddress"] is NSNull)
        #expect(network[0]["linkSpeedBitsPerSecond"] as? Int == 1_200_000_000)
        let devices = try dictionary(hidden["devices"])
        let hub = try #require(list(try dictionary(devices["usb"])["devices"]).first)
        let drive = try #require(list(hub["devices"]).first)
        #expect(drive["serialNumber"] is NSNull)
        let airPods = try #require(list(try dictionary(devices["bluetooth"])["devices"]).first)
        #expect(airPods["address"] is NSNull)
        let text = try #require(String(data: document().json(includeIdentifiers: false), encoding: .utf8))
        for secret in ["SERIAL123", "UUID-456", "a4:83:e7", "192.168.1.9", "2001:db8", "S123", "K789", "AA:BB"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }

        let shown = try object(document(), includeIdentifiers: true)
        #expect(shown["includesIdentifiers"] as? Bool == true)
        let shownHardware = try dictionary(shown["hardware"])
        #expect(shownHardware["serialNumber"] as? String == "SERIAL123")
        #expect(shownHardware["hardwareUUID"] as? String == "UUID-456")
        let shownPort = try #require(list(shown["network"]).first)
        #expect(shownPort["addresses"] as? [String] == ["192.168.1.9", "2001:db8::5"])
        #expect(shownPort["hardwareAddress"] as? String == "a4:83:e7:0b:12:9c")
        let shownText = try #require(String(data: document().json(includeIdentifiers: true), encoding: .utf8))
        for secret in ["S123", "K789", "AA:BB:CC:DD:EE:02"] {
            #expect(shownText.contains(secret), "\(secret) missing")
        }
    }

    @Test func jsonNestsDevicesUnderWhatTheyArePluggedInto() throws {
        let devices = try dictionary(try object(document(), includeIdentifiers: false)["devices"])
        #expect(devices["collectedAt"] as? String == ISO8601DateFormatter().string(from: Self.devicesCollected))
        // Cameras couldn't be read; audio was, and found a device.
        #expect(devices["cameras"] is NSNull)
        #expect(try list(devices["audio"]).first?["sampleRateHz"] as? Double == 48000)

        let usb = try dictionary(devices["usb"])
        #expect(usb["buses"] as? Int == 1)
        let top = try list(usb["devices"])
        #expect(top.map { $0["name"] as? String } == ["Hub", "Keyboard"])
        #expect(top[0]["vendorID"] as? String == "0x05e3" && top[0]["productID"] as? String == "0x0626")
        let drive = try #require(list(top[0]["devices"]).first)
        #expect(drive["name"] as? String == "Drive [backup]")
        #expect(drive["vendorID"] as? String == "0x0781" && drive["productID"] as? String == "0x55fd")
        #expect(drive["power"] as? String == "4.48 W (896 mA)")
        #expect(try list(drive["devices"]).map { $0["name"] as? String } == ["Mouse"])
        #expect(try list(top[1]["devices"]).isEmpty)
        #expect(top[1]["vendorID"] is NSNull)

        let thunderbolt = try dictionary(devices["thunderbolt"])
        #expect(try list(thunderbolt["ports"]).first?["isInUse"] as? Bool == true)
        let dock = try #require(list(thunderbolt["devices"]).first)
        #expect(dock["name"] as? String == "TS4")
        let chained = try #require(list(dock["devices"]).first)
        #expect(chained["name"] as? String == "Studio Display" && chained["speed"] is NSNull)
    }

    @Test func jsonDescribesSecurityChecks() throws {
        let security = SecurityStatus(sip: .custom, fileVault: .encrypting(42), gatekeeper: nil)
        let json = try dictionary(try object(document(security: security), includeIdentifiers: false)["security"])
        let sip = try dictionary(json["systemIntegrityProtection"])
        #expect(sip["state"] as? String == "custom" && sip["isProtected"] as? Bool == false)
        let fileVault = try dictionary(json["fileVault"])
        #expect(fileVault["state"] as? String == "encrypting" && fileVault["percentDone"] as? Double == 42)
        #expect(json["gatekeeper"] is NSNull)
    }

    @Test func nestsATreeOrderedList() {
        struct Node: Equatable {
            var name: String
            var children: [Node]
        }
        let items = [("a", 0), ("b", 1), ("c", 2), ("d", 1), ("e", 0)]
        let tree = SystemReportJSON.nest(items, depth: { $0.1 }, node: { Node(name: $0.0, children: $1) })
        #expect(tree == [
            Node(name: "a", children: [Node(name: "b", children: [Node(name: "c", children: [])]), Node(name: "d", children: [])]),
            Node(name: "e", children: []),
        ])
        // A list that starts deeper than the top still keeps every item.
        let orphans = SystemReportJSON.nest([("x", 1), ("y", 0)], depth: { $0.1 }, node: { Node(name: $0.0, children: $1) })
        #expect(orphans.map(\.name) == ["x", "y"])
    }

    @Test func markdownLeavesIdentifiersOutUnlessAsked() {
        let hidden = document().markdown(includeIdentifiers: false)
        #expect(hidden.hasPrefix("# MacBook Pro (16-inch, M5 Pro)\n\nMac17,8 · Apple M5 Pro · 48 GB memory · macOS 27.2 (26B5101f)\n"))
        #expect(hidden.contains("- Written by: otm test\n"))
        #expect(hidden.contains("- Left out: serial numbers, the hardware UUID, and MAC, Bluetooth and IP addresses\n"))
        for secret in ["SERIAL123", "UUID-456", "a4:83:e7", "192.168.1.9", "2001:db8", "S123", "K789", "AA:BB"] {
            #expect(!hidden.contains(secret), "\(secret) leaked")
        }
        // The port is still listed, without its addresses.
        #expect(hidden.contains("- **Wi-Fi** (en0)\n  - Status: Connected\n"))

        let shown = document().markdown(includeIdentifiers: true)
        #expect(!shown.contains("Left out"))
        #expect(shown.contains("- Serial number: SERIAL123\n- Hardware UUID: UUID-456\n"))
        #expect(shown.contains("  - IPv4: `192.168.1.9`\n"))
        #expect(shown.contains("  - Hardware address: `a4:83:e7:0b:12:9c`\n"))
        #expect(shown.contains("    - Serial number: `S123`\n"))
        #expect(shown.contains("  - Address: `AA:BB:CC:DD:EE:02`\n"))
    }

    @Test func markdownNestsDevicesAndTheirFacts() {
        let markdown = document().markdown(includeIdentifiers: false)
        #expect(markdown.contains("\n## USB\n\n- **Hub** (5 Gb/s)\n  - Connected to: USB 3.1 Bus\n  - Vendor:product: `05e3:0626`\n"))
        // Behind the hub, one level in, with its own facts a level further; brackets escaped.
        #expect(markdown.contains("""
          - **Drive \\[backup\\]**
            - Maker: SanDisk
            - Connected to: Hub
            - Power: 4.48 W (896 mA)
            - Vendor:product: `0781:55fd`
            - **Mouse**
              - Connected to: Drive \\[backup\\]
        - **Keyboard**
          - Connected to: USB 3.1 Bus

        """))
        #expect(markdown.contains("\n## Thunderbolt and USB4\n\n- Ports: 1, up to 40 Gb/s each\n- In use: 1 of 1\n- **TS4** (Up to 40 Gb/s)\n"))
        #expect(markdown.contains("  - **Studio Display**\n    - Maker: Apple Inc.\n    - Connected to: TS4\n"))
        // A plain row after a device isn't one of its facts.
        #expect(markdown.contains("""
        - **Speakers** (built-in, default for output)
          - Channels: 2 out
          - Sample rate: 48 kHz
        - Cameras: Couldn't read

        """))
        #expect(markdown.contains("- **AirPods** (connected, battery Left 80%)\n  - Kind: Headphones\n"))
        #expect(markdown.hasSuffix("\n"))
    }

    @Test func markdownEscapesFormatting() {
        #expect(SystemReportDocument.escaped("a*b [d] <e> `f` g|h \\") == "a\\*b \\[d\\] \\<e\\> \\`f\\` g\\|h \\\\")
        #expect(SystemReportDocument.escaped("Mac17,8 · 48 GB") == "Mac17,8 · 48 GB")
        // Underscores only where they could start or end emphasis.
        #expect(SystemReportDocument.escaped("RELEASE_ARM64_T6050") == "RELEASE_ARM64_T6050")
        #expect(SystemReportDocument.escaped("_tmp_ x_ _") == "\\_tmp\\_ x\\_ \\_")
    }

    @Test func networkAddressesAreFlagged() {
        let rows = SystemReport.sections(Self.info, displays: [], devices: nil, security: nil).first { $0.kind == .network }?.rows ?? []
        #expect(rows.filter(\.isAddress).map(\.label) == ["IPv4", "IPv6"])
        #expect(rows.first { $0.label == "Hardware address" }?.isSensitive == true)
    }
}
