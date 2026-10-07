import Foundation

/// A one-off description of this Mac's hardware and software, for the
/// System page and its copyable summary. Read by `SystemInfoReader`.
public struct SystemInfo: Sendable {
    public let hardware: MacHardware
    public let topology: CPUTopology
    public let software: SoftwareInfo
    public let gpus: [GPUInfo]
    public let disks: [DiskInfo]
    public let volumes: [VolumeInfo]
    public let network: [NetworkPortInfo]
    /// nil on Macs without a battery.
    public let battery: BatteryInfo?
    /// Addresses with prefixes, routers, DNS, proxies, services and routes;
    /// nil where it wasn't read.
    public let networkConfiguration: NetworkConfiguration?

    public init(
        hardware: MacHardware, topology: CPUTopology, software: SoftwareInfo, gpus: [GPUInfo], disks: [DiskInfo],
        volumes: [VolumeInfo], network: [NetworkPortInfo], battery: BatteryInfo?, networkConfiguration: NetworkConfiguration? = nil
    ) {
        self.hardware = hardware
        self.topology = topology
        self.software = software
        self.gpus = gpus
        self.disks = disks
        self.volumes = volumes
        self.network = network
        self.battery = battery
        self.networkConfiguration = networkConfiguration
    }
}

/// The broad shape of a Mac, for picking an icon.
public enum MacKind: String, Sendable, Codable {
    case laptop, mini, studio, iMac, pro, virtual, desktop

    /// Prefers the marketing name ("MacBook Pro (16-inch, M5 Pro)"), then
    /// the model identifier, which only names the family on Intel Macs
    /// ("Macmini9,1"; Apple silicon models are all "MacNN,N"). A battery
    /// settles the rest.
    public static func classify(marketingName: String?, modelIdentifier: String, hasBattery: Bool) -> MacKind {
        for text in [marketingName ?? "", modelIdentifier] {
            let lowered = text.lowercased()
            if lowered.contains("macbook") { return .laptop }
            if lowered.contains("mac mini") || lowered.hasPrefix("macmini") { return .mini }
            if lowered.contains("mac studio") { return .studio }
            if lowered.hasPrefix("imac") { return .iMac }
            if lowered.contains("mac pro") || lowered.hasPrefix("macpro") { return .pro }
            if lowered.hasPrefix("virtualmac") || lowered.contains("virtual machine") { return .virtual }
        }
        return hasBattery ? .laptop : .desktop
    }
}

public struct MacHardware: Sendable, Hashable {
    /// `hw.model`, such as "Mac17,8".
    public let modelIdentifier: String
    /// The device tree's product name, such as "MacBook Pro (16-inch, M5 Pro)".
    public let marketingName: String?
    /// `machdep.cpu.brand_string`, such as "Apple M5 Pro".
    public let chip: String
    public let physicalMemory: UInt64
    /// `hw.pagesize`: 16 KB on Apple silicon, 4 KB on Intel.
    public let pageSize: Int?
    public let kind: MacKind
    /// Identifies this machine; show only on request.
    public let serialNumber: String?
    public let hardwareUUID: String?

    public init(
        modelIdentifier: String, marketingName: String?, chip: String, physicalMemory: UInt64, pageSize: Int?,
        kind: MacKind, serialNumber: String?, hardwareUUID: String?
    ) {
        self.modelIdentifier = modelIdentifier
        self.marketingName = marketingName
        self.chip = chip
        self.physicalMemory = physicalMemory
        self.pageSize = pageSize
        self.kind = kind
        self.serialNumber = serialNumber
        self.hardwareUUID = hardwareUUID
    }

    public var displayName: String { marketingName ?? modelIdentifier }
}

public struct SoftwareInfo: Sendable, Hashable {
    /// "27.2" or "27.2.1".
    public let productVersion: String
    /// `kern.osversion`, such as "26B5101f".
    public let build: String?
    /// `kern.osrelease`, such as "27.2.0".
    public let kernelRelease: String?
    /// `kern.version`, parsed.
    public let kernel: KernelVersion?
    public let bootTime: Date?
    /// The name in Sharing settings ("Justin's MacBook Pro").
    public let computerName: String?
    /// The Bonjour name ("Justins-MacBook-Pro.local").
    public let localHostName: String?

    public init(
        productVersion: String, build: String?, kernelRelease: String?, kernel: KernelVersion?, bootTime: Date?,
        computerName: String?, localHostName: String?
    ) {
        self.productVersion = productVersion
        self.build = build
        self.kernelRelease = kernelRelease
        self.kernel = kernel
        self.bootTime = bootTime
        self.computerName = computerName
        self.localHostName = localHostName
    }

    /// "macOS 27.2 (26B5101f)".
    public var macOSDescription: String {
        "macOS \(productVersion)" + (build.map { " (\($0))" } ?? "")
    }
}

/// The pieces of `kern.version`: "Darwin Kernel Version 27.2.0: <date>; root:xnu-…/RELEASE_ARM64_T6050".
public struct KernelVersion: Sendable, Hashable {
    public let release: String?
    public let buildDate: String?
    /// "xnu-13432.40.177.0.3~56".
    public let xnu: String?
    /// "RELEASE_ARM64_T6050".
    public let configuration: String?
}

public struct GPUInfo: Sendable, Hashable {
    public let name: String
    public let coreCount: Int?

    public init(name: String, coreCount: Int?) {
        self.name = name
        self.coreCount = coreCount
    }
}

/// A physical drive.
public struct DiskInfo: Sendable, Hashable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String
    public let model: String?
    public let isInternal: Bool?
    public let isSolidState: Bool?
    public let size: UInt64?
    /// How it's attached, as the I/O Registry's "Physical Interconnect"
    /// says: "Apple Fabric", "PCI-Express", "SATA", "USB", "Thunderbolt",
    /// "Secure Digital". nil where the driver doesn't say (a virtual disk).
    public let interconnect: String?
    /// "Internal" or "External", from the same place.
    public let interconnectLocation: String?

    public init(bsdName: String, model: String?, isInternal: Bool?, isSolidState: Bool?, size: UInt64?, interconnect: String? = nil,
                interconnectLocation: String? = nil) {
        self.bsdName = bsdName
        self.model = model
        self.isInternal = isInternal
        self.isSolidState = isSolidState
        self.size = size
        self.interconnect = interconnect
        self.interconnectLocation = interconnectLocation
    }
}

public struct NetworkPortInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// BSD name, such as "en0".
    public let name: String
    /// "Wi-Fi", "Thunderbolt Ethernet".
    public let displayName: String
    public let kind: NetworkInterfaceKind
    public let isUp: Bool
    /// IPv4 first, then global IPv6, then link-local.
    public let addresses: [String]
    /// Identifies this machine on a network; show only on request.
    public let hardwareAddress: String?
    /// Bits per second.
    public let linkSpeed: UInt64?

    public init(
        name: String, displayName: String, kind: NetworkInterfaceKind, isUp: Bool, addresses: [String],
        hardwareAddress: String?, linkSpeed: UInt64?
    ) {
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.isUp = isUp
        self.addresses = addresses
        self.hardwareAddress = hardwareAddress
        self.linkSpeed = linkSpeed
    }

    /// Wi-Fi always (so "not connected" shows), anything else only while it
    /// carries a routable address. That hides idle Thunderbolt ports and the
    /// link-local-only tunnels macOS keeps for its own services.
    public var isWorthListing: Bool {
        if kind == .loopback { return false }
        if kind == .wifi { return true }
        return isUp && addresses.contains { !$0.lowercased().hasPrefix("fe80") }
    }
}

public struct BatteryInfo: Sendable, Hashable {
    public let percent: Int?
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let cycleCount: Int?
    /// Full-charge capacity as a share of design capacity.
    public let health: Double?
    /// Milliamp-hours.
    public let designCapacity: Int?
    public let fullChargeCapacity: Int?
    public let condition: BatteryCondition?

    public init(
        percent: Int?, isCharging: Bool, isPluggedIn: Bool, cycleCount: Int?, health: Double?,
        designCapacity: Int?, fullChargeCapacity: Int?, condition: BatteryCondition?
    ) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.cycleCount = cycleCount
        self.health = health
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.condition = condition
    }
}

public struct BatteryCondition: Sendable, Hashable {
    /// "Normal", "Service recommended".
    public let summary: String
    /// True when macOS gave no verdict and this one comes from capacity alone.
    public let isEstimated: Bool
}

/// One display, described for the System page.
public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public let id: UInt32
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The size apps lay out in ("looks like").
    public let pointWidth: Int
    public let pointHeight: Int
    public let scale: Double
    /// Hertz; nil when the display doesn't say.
    public let refreshRate: Double?
    public let isBuiltIn: Bool
    public let isMain: Bool

    public init(
        id: UInt32, name: String, pixelWidth: Int, pixelHeight: Int, pointWidth: Int, pointHeight: Int, scale: Double,
        refreshRate: Double?, isBuiltIn: Bool, isMain: Bool
    ) {
        self.id = id
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
        self.refreshRate = refreshRate
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
    }
}

public enum SIPStatus: Sendable, Hashable {
    case enabled, disabled
    /// Some protections turned off ("unknown (Custom Configuration)").
    case custom
}

public enum FileVaultStatus: Sendable, Hashable {
    case on, off
    /// Turned on, waiting for a restart to start encrypting.
    case pendingRestart
    /// Percent complete, when `fdesetup` says.
    case encrypting(Double?)
    case decrypting(Double?)
}

public enum GatekeeperStatus: Sendable, Hashable {
    case enabled, disabled
}

/// nil fields couldn't be read: the tool was missing, timed out or said something unexpected.
public struct SecurityStatus: Sendable, Hashable {
    public var sip: SIPStatus?
    public var fileVault: FileVaultStatus?
    public var gatekeeper: GatekeeperStatus?

    public init(sip: SIPStatus? = nil, fileVault: FileVaultStatus? = nil, gatekeeper: GatekeeperStatus? = nil) {
        self.sip = sip
        self.fileVault = fileVault
        self.gatekeeper = gatekeeper
    }
}
