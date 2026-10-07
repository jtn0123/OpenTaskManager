import Foundation
@testable import OTMKit
import Testing

struct SecurityParsingTests {
    @Test func parsesSIP() {
        #expect(SystemFacts.parseSIP("System Integrity Protection status: enabled.\n") == .enabled)
        #expect(SystemFacts.parseSIP("System Integrity Protection status: disabled.\n") == .disabled)
        let custom = """
        System Integrity Protection status: unknown (Custom Configuration).

        Configuration:
        \tApple Internal: disabled
        \tKext Signing: disabled
        """
        #expect(SystemFacts.parseSIP(custom) == .custom)
        #expect(SystemFacts.parseSIP("System Integrity Protection status: enabled (Custom Configuration).") == .custom)
        #expect(SystemFacts.parseSIP("csrutil: command not found") == nil)
        #expect(SystemFacts.parseSIP("") == nil)
    }

    @Test func parsesFileVault() {
        #expect(SystemFacts.parseFileVault("FileVault is On.\n") == .on)
        #expect(SystemFacts.parseFileVault("FileVault is Off.\n") == .off)
        #expect(SystemFacts.parseFileVault("FileVault is Off, but will be enabled after the next restart.\n") == .pendingRestart)
        #expect(SystemFacts.parseFileVault("FileVault is On.\nEncryption in progress: Percent completed = 34.2\n") == .encrypting(34.2))
        #expect(SystemFacts.parseFileVault("FileVault is On.\nDecryption in progress: Percent completed = 7\n") == .decrypting(7))
        #expect(SystemFacts.parseFileVault("Encryption in progress\n") == .encrypting(nil))
        #expect(SystemFacts.parseFileVault("Error: something else") == nil)
    }

    @Test func parsesGatekeeper() {
        #expect(SystemFacts.parseGatekeeper("assessments enabled\n") == .enabled)
        #expect(SystemFacts.parseGatekeeper("assessments disabled\n") == .disabled)
        #expect(SystemFacts.parseGatekeeper("spctl: unknown option") == nil)
    }

    @Test func describesStatuses() {
        #expect(SIPStatus.enabled.isProtected)
        #expect(!SIPStatus.custom.isProtected)
        #expect(FileVaultStatus.encrypting(42.4).summary == "Encrypting (42% done)")
        #expect(FileVaultStatus.encrypting(nil).isProtected)
        #expect(!FileVaultStatus.pendingRestart.isProtected)
        #expect(GatekeeperStatus.disabled.summary == "Disabled")
    }
}

struct SystemFactsTests {
    @Test func parsesKernelVersion() throws {
        let text = "Darwin Kernel Version 27.2.0: Tue Sep 29 21:48:08 PDT 2026; root:xnu-13432.40.177.0.3~56/RELEASE_ARM64_T6050"
        let kernel = try #require(SystemFacts.parseKernelVersion(text))
        #expect(kernel.release == "27.2.0")
        #expect(kernel.buildDate == "Tue Sep 29 21:48:08 PDT 2026")
        #expect(kernel.xnu == "xnu-13432.40.177.0.3~56")
        #expect(kernel.configuration == "RELEASE_ARM64_T6050")
        #expect(SystemFacts.parseKernelVersion("  ") == nil)
        #expect(SystemFacts.parseKernelVersion("Darwin")?.xnu == nil)
    }

    @Test func judgesBatteryCondition() {
        #expect(SystemFacts.batteryCondition(health: "Good", healthCondition: nil, capacity: 0.5)
            == BatteryCondition(summary: "Normal", isEstimated: false))
        #expect(SystemFacts.batteryCondition(health: "Poor", healthCondition: "Check Battery", capacity: nil)
            == BatteryCondition(summary: "Service recommended", isEstimated: false))
        #expect(SystemFacts.batteryCondition(health: nil, healthCondition: "Permanent Battery Failure", capacity: 1)?.summary
            == "Permanent failure")
        #expect(SystemFacts.batteryCondition(health: "Fair", healthCondition: "", capacity: 1)?.summary == "Service recommended")
        #expect(SystemFacts.batteryCondition(health: nil, healthCondition: nil, capacity: 1.03)
            == BatteryCondition(summary: "Normal", isEstimated: true))
        #expect(SystemFacts.batteryCondition(health: nil, healthCondition: nil, capacity: 0.79)
            == BatteryCondition(summary: "Service recommended", isEstimated: true))
        #expect(SystemFacts.batteryCondition(health: nil, healthCondition: nil, capacity: nil) == nil)
    }

    @Test func formatsSizes() {
        #expect(SystemFacts.memorySize(48 << 30) == "48 GB")
        #expect(SystemFacts.memorySize(8 << 30) == "8 GB")
        #expect(SystemFacts.memorySize(3 << 29) == "1.50 GB")
        #expect(SystemFacts.decimalBytes(2_001_111_162_880) == "2 TB")
        #expect(SystemFacts.decimalBytes(494_384_795_648) == "494 GB")
        #expect(SystemFacts.decimalBytes(1_500_000_000_000) == "1.5 TB")
        #expect(SystemFacts.decimalBytes(15_260_000_000) == "15.3 GB")
        #expect(SystemFacts.decimalBytes(999) == "999 bytes")
    }

    @Test func formatsVersionsAndRates() {
        #expect(SystemFacts.productVersion(major: 27, minor: 2, patch: 0) == "27.2")
        #expect(SystemFacts.productVersion(major: 27, minor: 2, patch: 1) == "27.2.1")
        #expect(SystemFacts.refreshRate(120) == "120 Hz")
        #expect(SystemFacts.refreshRate(59.94) == "59.94 Hz")
        #expect(SystemFacts.refreshRate(60.0001) == "60 Hz")
    }

    @Test func describesDisplays() {
        let retina = DisplayInfo(id: 1, name: "Built-in", pixelWidth: 3456, pixelHeight: 2234, pointWidth: 1728, pointHeight: 1117,
                                 scale: 2, refreshRate: 120, isBuiltIn: true, isMain: true)
        #expect(SystemFacts.describe(retina) == "3456 × 2234 (looks like 1728 × 1117) · 120 Hz")
        let plain = DisplayInfo(id: 2, name: "Monitor", pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, pointHeight: 1080,
                                scale: 1, refreshRate: nil, isBuiltIn: false, isMain: false)
        #expect(SystemFacts.describe(plain) == "1920 × 1080")
    }

    @Test func summarisesCores() {
        let tiers = [
            CPUTopology.Tier(level: 0, name: "Super", logicalCPUs: 6, physicalCPUs: 6, l2CacheBytes: nil),
            CPUTopology.Tier(level: 1, name: "Performance", logicalCPUs: 12, physicalCPUs: 12, l2CacheBytes: nil),
        ]
        let hybrid = CPUTopology(brand: "Apple M5 Pro", architecture: "arm64", physicalCores: 18, logicalCores: 18, tiers: tiers,
                                 tierForCPU: [], l1DataCacheBytes: nil, l1InstructionCacheBytes: nil, l2CacheBytes: nil,
                                 l3CacheBytes: nil, isAppleSilicon: true)
        #expect(SystemFacts.coreSummary(hybrid) == "18 cores: 6 Super, 12 Performance")
        let single = CPUTopology(brand: "Intel", architecture: "x86_64", physicalCores: 8, logicalCores: 16,
                                 tiers: [CPUTopology.Tier(level: 0, name: "Core", logicalCPUs: 16, physicalCPUs: 8, l2CacheBytes: nil)],
                                 tierForCPU: [], l1DataCacheBytes: nil, l1InstructionCacheBytes: nil, l2CacheBytes: nil,
                                 l3CacheBytes: nil, isAppleSilicon: false)
        #expect(SystemFacts.coreSummary(single) == "8 cores")
    }

    @Test func formatsHardwareAddresses() {
        #expect(SystemFacts.hardwareAddress([0xA4, 0x83, 0xE7, 0x0B, 0x12, 0x9C]) == "a4:83:e7:0b:12:9c")
        #expect(SystemFacts.hardwareAddress([0, 0, 0, 0, 0, 0]) == nil)
        #expect(SystemFacts.hardwareAddress([]) == nil)
    }

    /// Apple silicon identifiers ("Mac16,10") don't name the family, so the marketing name decides,
    /// even over a missing battery.
    @Test(arguments: [
        ("MacBook Pro (16-inch, M5 Pro)", MacKind.laptop),
        ("Mac mini (2024)", .mini),
        ("Mac Studio (2025)", .studio),
        ("iMac (24-inch, 2024)", .iMac),
        ("Mac Pro (2023)", .pro),
    ])
    func classifiesMacsByName(name: String, kind: MacKind) {
        #expect(MacKind.classify(marketingName: name, modelIdentifier: "Mac16,10", hasBattery: false) == kind)
    }

    @Test func classifiesMacsWithoutAMarketingName() {
        #expect(MacKind.classify(marketingName: nil, modelIdentifier: "MacBookPro16,1", hasBattery: true) == .laptop)
        #expect(MacKind.classify(marketingName: nil, modelIdentifier: "Macmini9,1", hasBattery: false) == .mini)
        #expect(MacKind.classify(marketingName: nil, modelIdentifier: "iMac21,1", hasBattery: false) == .iMac)
        #expect(MacKind.classify(marketingName: nil, modelIdentifier: "VirtualMac2,1", hasBattery: false) == .virtual)
        #expect(MacKind.classify(marketingName: nil, modelIdentifier: "Mac15,3", hasBattery: true) == .laptop)
        #expect(MacKind.classify(marketingName: nil, modelIdentifier: "Mac15,3", hasBattery: false) == .desktop)
    }

    @Test func listsOnlyNetworkPortsWorthShowing() {
        func port(_ name: String, _ kind: NetworkInterfaceKind, up: Bool, _ addresses: [String]) -> NetworkPortInfo {
            NetworkPortInfo(name: name, displayName: name, kind: kind, isUp: up, addresses: addresses, hardwareAddress: nil, linkSpeed: nil)
        }
        #expect(port("en0", .wifi, up: false, []).isWorthListing)
        #expect(port("en5", .ethernet, up: true, ["192.168.1.20"]).isWorthListing)
        #expect(port("utun4", .vpn, up: true, ["100.101.102.103"]).isWorthListing)
        #expect(!port("utun0", .vpn, up: true, ["fe80::1%utun0"]).isWorthListing)
        #expect(!port("en1", .ethernet, up: false, []).isWorthListing)
        #expect(!port("lo0", .loopback, up: true, ["127.0.0.1"]).isWorthListing)
    }
}

struct SystemReportTests {
    private static let boot = Date(timeIntervalSince1970: 1_791_255_888)

    private func info(battery: BatteryInfo? = nil) -> SystemInfo {
        let topology = CPUTopology(
            brand: "Apple M5 Pro", architecture: "arm64", physicalCores: 18, logicalCores: 18,
            tiers: [
                .init(level: 0, name: "Super", logicalCPUs: 6, physicalCPUs: 6, l2CacheBytes: 16 << 20),
                .init(level: 1, name: "Performance", logicalCPUs: 12, physicalCPUs: 12, l2CacheBytes: 8 << 20),
            ],
            tierForCPU: [], l1DataCacheBytes: 128 << 10, l1InstructionCacheBytes: 192 << 10, l2CacheBytes: nil, l3CacheBytes: nil,
            isAppleSilicon: true
        )
        return SystemInfo(
            hardware: MacHardware(modelIdentifier: "Mac17,8", marketingName: "MacBook Pro (16-inch, M5 Pro)", chip: "Apple M5 Pro",
                                  physicalMemory: 48 << 30, pageSize: 16_384, kind: .laptop, serialNumber: "SERIAL123",
                                  hardwareUUID: "UUID-456"),
            topology: topology,
            software: SoftwareInfo(productVersion: "27.2", build: "26B5101f", kernelRelease: "27.2.0",
                                   kernel: SystemFacts.parseKernelVersion("Darwin Kernel Version 27.2.0: x; root:xnu-1~2/RELEASE"),
                                   bootTime: Self.boot, computerName: "Test Mac", localHostName: "Test-Mac.local"),
            gpus: [GPUInfo(name: "Apple M5 Pro", coreCount: 20)],
            disks: [DiskInfo(bsdName: "disk0", model: "APPLE SSD", isInternal: true, isSolidState: true, size: 2_000_000_000_000)],
            volumes: [
                VolumeInfo(name: "Macintosh HD", mountPoint: "/", fileSystem: "APFS", totalBytes: 1_994_000_000_000,
                           availableBytes: 1_000_000_000_000, isInternal: true, isRemovable: false, isRoot: true, physicalDisk: "disk0"),
                VolumeInfo(name: "Installer", mountPoint: "/Volumes/Installer", fileSystem: "HFS+", totalBytes: 500_000_000,
                           availableBytes: 1_000_000, isInternal: false, isRemovable: true, isRoot: false, physicalDisk: nil),
            ],
            network: [
                NetworkPortInfo(name: "en0", displayName: "Wi-Fi", kind: .wifi, isUp: true, addresses: ["192.168.1.9", "fe80::1"],
                                hardwareAddress: "a4:83:e7:0b:12:9c", linkSpeed: 1_200_000_000),
                NetworkPortInfo(name: "utun0", displayName: "utun0", kind: .vpn, isUp: true, addresses: ["fe80::2"],
                                hardwareAddress: nil, linkSpeed: nil),
                NetworkPortInfo(name: "bridge100", displayName: "bridge100", kind: .bridge, isUp: true, addresses: ["192.168.64.1"],
                                hardwareAddress: nil, linkSpeed: nil),
            ],
            battery: battery
        )
    }

    private let display = DisplayInfo(id: 1, name: "Built-in Display", pixelWidth: 3456, pixelHeight: 2234, pointWidth: 1728,
                                      pointHeight: 1117, scale: 2, refreshRate: 120, isBuiltIn: true, isMain: true)

    @Test func summaryLeavesOutIdentifiersUnlessAsked() {
        let now = Self.boot.addingTimeInterval(90_000)
        let hidden = SystemReport.text(info(), displays: [display], security: nil, includeIdentifiers: false, now: now)
        #expect(hidden.hasPrefix("MacBook Pro (16-inch, M5 Pro)\nMac17,8 · Apple M5 Pro · 48 GB memory · macOS 27.2 (26B5101f)\n"))
        #expect(!hidden.contains("SERIAL123"))
        #expect(!hidden.contains("UUID-456"))
        #expect(!hidden.contains("a4:83:e7"))
        #expect(hidden.contains("  Up time: 1d 1h"))

        let shown = SystemReport.text(info(), displays: [display], security: nil, includeIdentifiers: true, now: now)
        #expect(shown.contains("Serial number: SERIAL123"))
        #expect(shown.contains("Hardware UUID: UUID-456"))
        #expect(shown.contains("    Hardware address: a4:83:e7:0b:12:9c"))
    }

    @Test func sectionsFollowThePageOrder() {
        let kinds = SystemReport.sections(info(), displays: [display], security: nil).map(\.kind)
        #expect(kinds == [.processor, .memory, .graphics, .displays, .storage, .network, .software, .security])
        let battery = BatteryInfo(percent: 80, isCharging: false, isPluggedIn: true, cycleCount: 3, health: 1.03, designCapacity: 8579,
                                  fullChargeCapacity: 8817, condition: BatteryCondition(summary: "Normal", isEstimated: true))
        let withBattery = SystemReport.sections(info(battery: battery), displays: [], security: nil)
        #expect(withBattery.map(\.kind).contains(.battery))
        let rows = withBattery.first { $0.kind == .battery }?.rows ?? []
        #expect(rows.contains(InfoRow("Charge", "80%, plugged in")))
        #expect(rows.contains(InfoRow("Full charge", "103% of design capacity (8817 of 8579 mAh)")))
        #expect(rows.first { $0.label == "Condition" }?.value == "Normal (judged from capacity)")
    }

    @Test func storageKeepsVolumesWithTheirDrive() {
        let rows = SystemReport.sections(info(), displays: [], security: nil).first { $0.kind == .storage }?.rows ?? []
        #expect(rows.map(\.label) == ["APPLE SSD", "Capacity", "Device", "Macintosh HD", "Other volumes", "Installer"])
        #expect(rows[0].isHeading && rows[0].value == "Internal SSD")
        #expect(rows[3].value == "1 TB free of 1.99 TB · APFS")
    }

    @Test func networkHidesLinkLocalTunnels() {
        let rows = SystemReport.sections(info(), displays: [], security: nil).first { $0.kind == .network }?.rows ?? []
        #expect(rows.filter(\.isHeading).map(\.label) == ["Wi-Fi", "bridge100"])
        // The BSD name follows a friendly name, but isn't repeated when it's all there is.
        #expect(rows.filter(\.isHeading).map(\.value) == ["en0", ""])
        #expect(rows.contains(InfoRow("IPv4", "192.168.1.9")))
        #expect(!rows.contains { $0.label == "IPv6" })
        #expect(rows.contains(InfoRow("Link speed", "1.2 Gbps")))
        #expect(rows.first { $0.label == "Hardware address" }?.isSensitive == true)
    }

    @Test func securityShowsProgressThenResults() {
        let checking = SystemReport.sections(info(), displays: [], security: nil).first { $0.kind == .security }?.rows ?? []
        #expect(checking.map(\.value) == ["Checking…", "Checking…", "Checking…"])

        let status = SecurityStatus(sip: .enabled, fileVault: .off, gatekeeper: nil)
        let rows = SystemReport.sections(info(), displays: [], security: status).first { $0.kind == .security }?.rows ?? []
        #expect(rows == [
            InfoRow("System Integrity Protection", "Enabled", status: .good),
            InfoRow("FileVault", "Off", status: .warning),
            InfoRow("Gatekeeper", "Couldn't read", status: .unknown),
        ])
    }
}

/// Reads the real machine, so only invariants are checked.
@Suite(.serialized)
struct LiveSystemInfoTests {
    @Test func describesThisMac() {
        let info = SystemInfoReader.read(topology: CPUTopologyReader.read())
        #expect(!info.hardware.modelIdentifier.isEmpty)
        #expect(!info.hardware.chip.isEmpty)
        #expect(info.hardware.physicalMemory == ProcessInfo.processInfo.physicalMemory)
        #expect(info.software.productVersion.hasPrefix("\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)."))
        #expect(info.software.bootTime.map { $0 < Date() } ?? true)
        #expect(info.volumes.contains { $0.isRoot })
        if info.hardware.marketingName?.contains("MacBook") == true { #expect(info.hardware.kind == .laptop) }

        let text = SystemReport.text(info, displays: [], security: nil, includeIdentifiers: false)
        #expect(text.hasPrefix(info.hardware.displayName))
        if let serial = info.hardware.serialNumber { #expect(!text.contains(serial)) }
        if let uuid = info.hardware.hardwareUUID { #expect(!text.contains(uuid)) }
    }

    @Test func runsToolsWithATimeout() async {
        #expect(CommandRunner.run("/bin/echo", ["hello"], timeout: 5) == "hello\n")
        #expect(CommandRunner.run("/nonexistent/tool", [], timeout: 1) == nil)
        let start = Date()
        #expect(await CommandRunner.output(of: "/bin/sleep", ["30"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func readsSecurityStateWithoutRoot() async {
        let start = Date()
        let status = await SecurityReader.read(timeout: 5)
        #expect(Date().timeIntervalSince(start) < 15)
        // The three tools ship with macOS, so each answer should parse.
        let tools = FileManager.default
        if tools.isExecutableFile(atPath: "/usr/bin/csrutil") { #expect(status.sip != nil) }
        if tools.isExecutableFile(atPath: "/usr/bin/fdesetup") { #expect(status.fileVault != nil) }
        if tools.isExecutableFile(atPath: "/usr/sbin/spctl") { #expect(status.gatekeeper != nil) }
    }
}
