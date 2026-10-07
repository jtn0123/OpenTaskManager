import Foundation

/// Version 1 of the JSON system report, kept apart from the model types so
/// changing those never changes the format by accident. Sizes are bytes,
/// times ISO 8601, and attached devices nest under the hub or device
/// they're plugged into. With identifiers left out, serial numbers, the
/// hardware UUID, MAC, Bluetooth and IP addresses, routers, DNS servers,
/// search domains and proxy hosts are `null`, and `includesIdentifiers` is false.
struct SystemReportJSON: Encodable {
    let format = SystemReportDocument.format
    let schemaVersion = SystemReportDocument.schemaVersion
    let generator: String
    let collectedAt: Date
    let includesIdentifiers: Bool
    let hardware: Hardware
    let processor: Processor
    let graphics: [GPU]
    let displays: [Display]
    let storage: Storage
    let network: [NetworkPort]
    /// Routes, DNS, proxies and services; null where it wasn't read.
    @Nullable var networkConfiguration: NetworkSetup?
    /// null while the device report is still being read.
    @Nullable var devices: Devices?
    /// null on a Mac without one.
    @Nullable var battery: Battery?
    let software: Software
    /// null while it's still being checked.
    @Nullable var security: Security?

    init(_ report: SystemReportDocument, includeIdentifiers keep: Bool) {
        let info = report.info
        generator = report.generator
        collectedAt = report.collectedAt
        includesIdentifiers = keep
        hardware = Hardware(info.hardware, keep: keep)
        processor = Processor(info.topology)
        graphics = info.gpus.map(GPU.init)
        displays = report.displays.map(Display.init)
        storage = Storage(disks: info.disks, volumes: info.volumes)
        // The ports the page lists: not idle ones or link-local tunnels.
        let configuration = info.networkConfiguration
        network = info.network.filter(\.isWorthListing).map { NetworkPort($0, configuration: configuration, keep: keep) }
        networkConfiguration = configuration.map { NetworkSetup($0, keep: keep) }
        devices = report.devices.map { Devices($0, collectedAt: report.devicesCollectedAt ?? report.collectedAt, keep: keep) }
        battery = info.battery.map(Battery.init)
        software = Software(info.software, at: report.collectedAt)
        security = report.security.map(Security.init)
    }

    /// Nests a list kept in tree order, where each item comes just before
    /// everything plugged in behind it, one level deeper.
    static func nest<Item, Node>(_ items: [Item], depth: (Item) -> Int, node: (Item, [Node]) -> Node) -> [Node] {
        var index = 0
        func level(_ minimum: Int) -> [Node] {
            var nodes: [Node] = []
            while index < items.count, depth(items[index]) >= minimum {
                let item = items[index]
                index += 1
                nodes.append(node(item, level(depth(item) + 1)))
            }
            return nodes
        }
        return level(0)
    }

    /// JSON has no NaN or infinity.
    static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }

    // MARK: - Hardware

    struct Hardware: Encodable {
        let name: String
        let modelIdentifier: String
        @Nullable var marketingName: String?
        let kind: MacKind
        let chip: String
        let memoryBytes: UInt64
        @Nullable var pageSizeBytes: Int?
        @Nullable var serialNumber: String?
        @Nullable var hardwareUUID: String?

        init(_ hardware: MacHardware, keep: Bool) {
            name = hardware.displayName
            modelIdentifier = hardware.modelIdentifier
            marketingName = hardware.marketingName
            kind = hardware.kind
            chip = hardware.chip
            memoryBytes = hardware.physicalMemory
            pageSizeBytes = hardware.pageSize
            serialNumber = keep ? hardware.serialNumber : nil
            hardwareUUID = keep ? hardware.hardwareUUID : nil
        }
    }

    struct Processor: Encodable {
        let brand: String
        let architecture: String
        let isAppleSilicon: Bool
        let physicalCores: Int
        let logicalCores: Int
        /// Fastest first: "Super", "Performance", "Efficiency".
        let coreTypes: [CoreType]
        @Nullable var l1DataCacheBytesPerCore: Int?
        @Nullable var l1InstructionCacheBytesPerCore: Int?
        /// One shared L2; with several core types each has its own, per cluster.
        @Nullable var l2CacheBytes: Int?
        @Nullable var l3CacheBytes: Int?

        init(_ topology: CPUTopology) {
            brand = topology.brand
            architecture = topology.architecture
            isAppleSilicon = topology.isAppleSilicon
            physicalCores = topology.physicalCores
            logicalCores = topology.logicalCores
            coreTypes = topology.tiers.map(CoreType.init)
            l1DataCacheBytesPerCore = topology.l1DataCacheBytes
            l1InstructionCacheBytesPerCore = topology.l1InstructionCacheBytes
            l2CacheBytes = topology.l2CacheBytes
            l3CacheBytes = topology.l3CacheBytes
        }
    }

    struct CoreType: Encodable {
        let name: String
        let physicalCores: Int
        let logicalCores: Int
        @Nullable var l2CacheBytesPerCluster: Int?

        init(_ tier: CPUTopology.Tier) {
            name = tier.name
            physicalCores = tier.physicalCPUs
            logicalCores = tier.logicalCPUs
            l2CacheBytesPerCluster = tier.l2CacheBytes
        }
    }

    struct GPU: Encodable {
        let name: String
        @Nullable var coreCount: Int?

        init(_ gpu: GPUInfo) {
            name = gpu.name
            coreCount = gpu.coreCount
        }
    }

    struct Display: Encodable {
        let name: String
        let pixelWidth: Int
        let pixelHeight: Int
        /// The size apps lay out in ("looks like").
        let pointWidth: Int
        let pointHeight: Int
        let scale: Double
        @Nullable var refreshRateHz: Double?
        let isBuiltIn: Bool
        let isMain: Bool

        init(_ display: DisplayInfo) {
            name = display.name
            pixelWidth = display.pixelWidth
            pixelHeight = display.pixelHeight
            pointWidth = display.pointWidth
            pointHeight = display.pointHeight
            scale = SystemReportJSON.finite(display.scale) ?? 1
            refreshRateHz = SystemReportJSON.finite(display.refreshRate)
            isBuiltIn = display.isBuiltIn
            isMain = display.isMain
        }
    }

    // MARK: - Storage and network

    struct Storage: Encodable {
        let disks: [Disk]
        /// Disk images, network shares and other volumes without a drive here.
        let otherVolumes: [Volume]

        init(disks: [DiskInfo], volumes: [VolumeInfo]) {
            let sorted = volumes.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
            let known = Set(disks.map(\.bsdName))
            self.disks = disks.map { disk in Disk(disk, volumes: sorted.filter { $0.physicalDisk == disk.bsdName }.map(Volume.init)) }
            otherVolumes = sorted.filter { $0.physicalDisk.map { !known.contains($0) } ?? true }.map(Volume.init)
        }
    }

    struct Disk: Encodable {
        let bsdName: String
        @Nullable var model: String?
        @Nullable var isInternal: Bool?
        @Nullable var isSolidState: Bool?
        @Nullable var sizeBytes: UInt64?
        let volumes: [Volume]

        init(_ disk: DiskInfo, volumes: [Volume]) {
            bsdName = disk.bsdName
            model = disk.model
            isInternal = disk.isInternal
            isSolidState = disk.isSolidState
            sizeBytes = disk.size
            self.volumes = volumes
        }
    }

    struct Volume: Encodable {
        let name: String
        let mountPoint: String
        @Nullable var fileSystem: String?
        let totalBytes: UInt64
        let availableBytes: UInt64
        let isInternal: Bool
        let isRemovable: Bool
        let isRoot: Bool

        init(_ volume: VolumeInfo) {
            name = volume.name
            mountPoint = volume.mountPoint
            fileSystem = volume.fileSystem
            totalBytes = volume.totalBytes
            availableBytes = volume.availableBytes
            isInternal = volume.isInternal
            isRemovable = volume.isRemovable
            isRoot = volume.isRoot
        }
    }

    // MARK: - Attached devices

    struct Devices: Encodable {
        /// When `system_profiler` ran, which may be before the rest.
        let collectedAt: Date
        /// Each category is null when macOS didn't describe it.
        @Nullable var usb: USB?
        @Nullable var thunderbolt: Thunderbolt?
        @Nullable var bluetooth: Bluetooth?
        @Nullable var audio: [Audio]?
        @Nullable var cameras: [Camera]?

        init(_ inventory: PeripheralInventory, collectedAt: Date, keep: Bool) {
            self.collectedAt = collectedAt
            usb = inventory.usb.value.map { USB($0, keep: keep) }
            thunderbolt = inventory.thunderbolt.value.map(Thunderbolt.init)
            bluetooth = inventory.bluetooth.value.map { Bluetooth($0, keep: keep) }
            audio = inventory.audio.value?.map(Audio.init)
            cameras = inventory.cameras.value?.map(Camera.init)
        }
    }

    struct USB: Encodable {
        let buses: Int
        /// Devices on the buses directly, each with what's plugged into it.
        let devices: [USBNode]

        init(_ report: USBReport, keep: Bool) {
            buses = report.buses
            devices = SystemReportJSON.nest(report.devices, depth: \.depth) { USBNode($0, devices: $1, keep: keep) }
        }
    }

    struct USBNode: Encodable {
        let name: String
        @Nullable var vendor: String?
        /// "0x0781".
        @Nullable var vendorID: String?
        @Nullable var productID: String?
        /// The negotiated link speed, as macOS words it ("5 Gb/s").
        @Nullable var speed: String?
        /// Power the Mac set aside for it ("4.48 W (896 mA)").
        @Nullable var power: String?
        @Nullable var serialNumber: String?
        let isBuiltIn: Bool
        let bus: String
        let devices: [USBNode]

        init(_ device: USBDevice, devices: [USBNode], keep: Bool) {
            name = device.name
            vendor = device.vendor
            vendorID = device.vendorID.map { String(format: "0x%04x", $0) }
            productID = device.productID.map { String(format: "0x%04x", $0) }
            speed = device.speed
            power = device.power
            serialNumber = keep ? device.serialNumber : nil
            isBuiltIn = device.isBuiltIn
            bus = device.bus
            self.devices = devices
        }
    }

    struct Thunderbolt: Encodable {
        let ports: [ThunderboltPort]
        /// Devices plugged into the Mac, each with what's chained from it.
        let devices: [ThunderboltNode]

        init(_ report: ThunderboltReport) {
            ports = report.ports.map(ThunderboltPort.init)
            devices = SystemReportJSON.nest(report.devices, depth: \.depth) { ThunderboltNode($0, devices: $1) }
        }
    }

    struct ThunderboltPort: Encodable {
        @Nullable var speed: String?
        let isInUse: Bool

        init(_ port: ThunderboltReport.Port) {
            speed = port.speed
            isInUse = port.isInUse
        }
    }

    struct ThunderboltNode: Encodable {
        let name: String
        @Nullable var vendor: String?
        @Nullable var speed: String?
        let devices: [ThunderboltNode]

        init(_ device: ThunderboltReport.Device, devices: [ThunderboltNode]) {
            name = device.name
            vendor = device.vendor
            speed = device.speed
            self.devices = devices
        }
    }

    struct Bluetooth: Encodable {
        @Nullable var isOn: Bool?
        @Nullable var chipset: String?
        @Nullable var firmware: String?
        /// Paired devices, connected first.
        let devices: [BluetoothPeripheral]

        init(_ report: BluetoothReport, keep: Bool) {
            isOn = report.isOn
            chipset = report.chipset
            firmware = report.firmware
            devices = report.devices.map { BluetoothPeripheral($0, keep: keep) }
        }
    }

    struct BluetoothPeripheral: Encodable {
        let name: String
        /// What it is, as macOS classes it ("Headphones").
        @Nullable var kind: String?
        let isConnected: Bool
        @Nullable var address: String?
        @Nullable var firmware: String?
        let batteries: [BluetoothBattery]

        init(_ device: BluetoothDevice, keep: Bool) {
            name = device.name
            kind = device.kind
            isConnected = device.isConnected
            address = keep ? device.address : nil
            firmware = device.firmware
            batteries = device.batteries.map(BluetoothBattery.init)
        }
    }

    struct BluetoothBattery: Encodable {
        /// "Left", "Right", "Case", or null for a single battery.
        @Nullable var part: String?
        let percent: Int

        init(_ battery: BluetoothDevice.Battery) {
            part = battery.part
            percent = battery.percent
        }
    }

    struct Audio: Encodable {
        let name: String
        @Nullable var manufacturer: String?
        /// How it's connected: "Built-in", "USB", "Bluetooth".
        @Nullable var transport: String?
        let inputChannels: Int
        let outputChannels: Int
        @Nullable var sampleRateHz: Double?
        let isDefaultInput: Bool
        let isDefaultOutput: Bool
        /// Plays alerts and sound effects.
        let isDefaultSystemOutput: Bool

        init(_ device: AudioDevice) {
            name = device.name
            manufacturer = device.manufacturer
            transport = device.transport
            inputChannels = device.inputChannels
            outputChannels = device.outputChannels
            sampleRateHz = SystemReportJSON.finite(device.sampleRate)
            isDefaultInput = device.isDefaultInput
            isDefaultOutput = device.isDefaultOutput
            isDefaultSystemOutput = device.isDefaultSystemOutput
        }
    }

    struct Camera: Encodable {
        let name: String
        @Nullable var model: String?

        init(_ camera: CameraDevice) {
            name = camera.name
            model = camera.model
        }
    }

    // MARK: - Battery, software and security

    struct Battery: Encodable {
        @Nullable var percent: Int?
        let isCharging: Bool
        let isPluggedIn: Bool
        @Nullable var cycleCount: Int?
        /// Full-charge capacity as a share of design capacity: 1 is as new.
        @Nullable var health: Double?
        @Nullable var designCapacityMilliampHours: Int?
        @Nullable var fullChargeCapacityMilliampHours: Int?
        /// "Normal", "Service recommended".
        @Nullable var condition: String?
        /// True when macOS gave no verdict and `condition` comes from capacity alone.
        @Nullable var conditionIsEstimated: Bool?

        init(_ battery: BatteryInfo) {
            percent = battery.percent
            isCharging = battery.isCharging
            isPluggedIn = battery.isPluggedIn
            cycleCount = battery.cycleCount
            health = SystemReportJSON.finite(battery.health)
            designCapacityMilliampHours = battery.designCapacity
            fullChargeCapacityMilliampHours = battery.fullChargeCapacity
            condition = battery.condition?.summary
            conditionIsEstimated = battery.condition?.isEstimated
        }
    }

    struct Software: Encodable {
        let macOSVersion: String
        @Nullable var build: String?
        /// "27.2.0".
        @Nullable var kernelRelease: String?
        /// "xnu-13432.40.177.0.3~56".
        @Nullable var kernelBuild: String?
        /// "RELEASE_ARM64_T6050".
        @Nullable var kernelConfiguration: String?
        @Nullable var bootTime: Date?
        /// Up time at `collectedAt`.
        @Nullable var uptimeSeconds: Int?
        @Nullable var computerName: String?
        @Nullable var localHostName: String?

        init(_ software: SoftwareInfo, at time: Date) {
            macOSVersion = software.productVersion
            build = software.build
            kernelRelease = software.kernelRelease ?? software.kernel?.release
            kernelBuild = software.kernel?.xnu
            kernelConfiguration = software.kernel?.configuration
            bootTime = software.bootTime
            uptimeSeconds = software.bootTime.map { max(Int(time.timeIntervalSince($0)), 0) }
            computerName = software.computerName
            localHostName = software.localHostName
        }
    }

    /// Each check is null when its tool couldn't be read.
    struct Security: Encodable {
        @Nullable var systemIntegrityProtection: SecurityCheck?
        @Nullable var fileVault: SecurityCheck?
        @Nullable var gatekeeper: SecurityCheck?

        init(_ status: SecurityStatus) {
            systemIntegrityProtection = status.sip.map { sip in
                let state = switch sip {
                case .enabled: "enabled"
                case .disabled: "disabled"
                case .custom: "custom"
                }
                return SecurityCheck(state: state, summary: sip.summary, isProtected: sip.isProtected)
            }
            fileVault = status.fileVault.map { fileVault in
                let (state, done): (String, Double?) = switch fileVault {
                case .on: ("on", nil)
                case .off: ("off", nil)
                case .pendingRestart: ("pendingRestart", nil)
                case let .encrypting(percent): ("encrypting", percent)
                case let .decrypting(percent): ("decrypting", percent)
                }
                return SecurityCheck(state: state, summary: fileVault.summary, isProtected: fileVault.isProtected,
                                     percentDone: SystemReportJSON.finite(done))
            }
            gatekeeper = status.gatekeeper.map { gatekeeper in
                SecurityCheck(state: gatekeeper == .enabled ? "enabled" : "disabled", summary: gatekeeper.summary,
                              isProtected: gatekeeper.isProtected)
            }
        }
    }

    struct SecurityCheck: Encodable {
        /// "enabled", "disabled", "custom"; for FileVault "on", "off",
        /// "pendingRestart", "encrypting" or "decrypting".
        let state: String
        /// As the page words it: "Partly disabled (custom configuration)".
        let summary: String
        let isProtected: Bool
        /// While FileVault encrypts or decrypts, when `fdesetup` says.
        @Nullable var percentDone: Double?

        init(state: String, summary: String, isProtected: Bool, percentDone: Double? = nil) {
            self.state = state
            self.summary = summary
            self.isProtected = isProtected
            self.percentDone = percentDone
        }
    }
}

/// Writes nil as an explicit `null` rather than leaving the key out, so a
/// reader can tell a fact this Mac didn't report from a field it doesn't know.
@propertyWrapper
struct Nullable<Value: Encodable>: Encodable {
    var wrappedValue: Value?

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}
