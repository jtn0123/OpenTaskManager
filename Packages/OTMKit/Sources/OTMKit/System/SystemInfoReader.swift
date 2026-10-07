import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

/// Reads the facts on the System page once. Everything comes from sysctl,
/// the IORegistry and SystemConfiguration, reusing the live samplers for
/// GPUs, drives, volumes and network links.
public enum SystemInfoReader {
    /// Everything except displays (AppKit) and security state (`SecurityReader`).
    /// Walks the IORegistry and lists volumes, so call it off the main thread.
    public static func read(topology: CPUTopology) -> SystemInfo {
        let battery = readBattery()
        let model = Sysctl.string("hw.model") ?? "Mac"
        let marketingName = readMarketingName()
        let platform = readPlatformIdentifiers()
        let hardware = MacHardware(
            modelIdentifier: model,
            marketingName: marketingName,
            chip: Sysctl.string("machdep.cpu.brand_string") ?? topology.brand,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            pageSize: Sysctl.int("hw.pagesize"),
            kind: MacKind.classify(marketingName: marketingName, modelIdentifier: model, hasBattery: battery != nil),
            serialNumber: platform.serial,
            hardwareUUID: platform.uuid
        )
        let disks = DiskSampler().sample(interval: 0).map {
            DiskInfo(bsdName: $0.bsdName, model: $0.model, isInternal: $0.isInternal, isSolidState: $0.isSolidState, size: $0.size)
        }
        return SystemInfo(
            hardware: hardware,
            topology: topology,
            software: readSoftware(),
            gpus: GPUSampler().sample(includeProcesses: false).gpus.map { GPUInfo(name: $0.name, coreCount: $0.coreCount) },
            disks: disks,
            volumes: VolumeReader.read(),
            network: readNetwork(),
            battery: battery
        )
    }

    // MARK: - Hardware

    /// "MacBook Pro (16-inch, M5 Pro)" from the device tree. Apple silicon
    /// Macs carry it; Intel Macs don't, and fall back to the model identifier.
    static func readMarketingName() -> String? {
        guard let product = IORegistry.entry(path: "IODeviceTree:/product") else { return nil }
        defer { IOObjectRelease(product) }
        let properties = IORegistry.properties(of: product)
        let name = properties.string("product-name") ?? properties.string("product-description")
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func readPlatformIdentifiers() -> (serial: String?, uuid: String?) {
        var serial: String?
        var uuid: String?
        IORegistry.forEachService(matching: "IOPlatformExpertDevice") { device in
            serial = serial ?? (IORegistry.property("IOPlatformSerialNumber", of: device) as? String)
            uuid = uuid ?? (IORegistry.property("IOPlatformUUID", of: device) as? String)
        }
        return (serial.flatMap { $0.isEmpty ? nil : $0 }, uuid.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Software

    private static func readSoftware() -> SoftwareInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let boot = Sysctl.value("kern.boottime", as: timeval.self).map {
            Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_usec) / 1_000_000)
        }
        let localName = SCDynamicStoreCopyLocalHostName(nil) as String?
        return SoftwareInfo(
            productVersion: SystemFacts.productVersion(major: version.majorVersion, minor: version.minorVersion,
                                                       patch: version.patchVersion),
            build: Sysctl.string("kern.osversion"),
            kernelRelease: Sysctl.string("kern.osrelease"),
            kernel: Sysctl.string("kern.version").flatMap(SystemFacts.parseKernelVersion),
            bootTime: boot,
            computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?,
            localHostName: localName.map { $0 + ".local" }
        )
    }

    // MARK: - Network

    private static func readNetwork() -> [NetworkPortInfo] {
        let hardwareAddresses = readHardwareAddresses()
        return NetworkSampler().sample(interval: 0).map { link in
            NetworkPortInfo(
                name: link.name, displayName: link.displayName, kind: link.kind, isUp: link.isUp, addresses: link.addresses,
                hardwareAddress: hardwareAddresses[link.name], linkSpeed: link.linkSpeed
            )
        }
    }

    /// MAC addresses by interface name, from the AF_LINK entries of `getifaddrs`.
    private static func readHardwareAddresses() -> [String: String] {
        var result: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        guard let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data),
              let nameLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen),
              let addressLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_alen) else { return result }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK else { continue }
            // The link-layer address follows the interface name in `sdl_data`,
            // which can run past the struct's nominal size, so read by offset within `sa_len`.
            let raw = UnsafeRawPointer(address)
            let length = Int(address.pointee.sa_len)
            guard length > addressLengthOffset else { continue }
            let nameLength = Int(raw.load(fromByteOffset: nameLengthOffset, as: UInt8.self))
            let addressLength = Int(raw.load(fromByteOffset: addressLengthOffset, as: UInt8.self))
            let start = dataOffset + nameLength
            guard addressLength == 6, start + addressLength <= length else { continue }
            let bytes = (0..<addressLength).map { raw.load(fromByteOffset: start + $0, as: UInt8.self) }
            if let text = SystemFacts.hardwareAddress(bytes) {
                result[String(cString: entry.pointee.ifa_name)] = text
            }
        }
        return result
    }

    // MARK: - Battery

    private static func readBattery() -> BatteryInfo? {
        var properties: [String: Any]?
        IORegistry.forEachService(matching: "AppleSmartBattery") { service in
            properties = IORegistry.properties(of: service)
        }
        guard let properties, let sample = BatteryReading.parse(properties).battery else { return nil }
        // macOS 27 moved the capacities into `BatteryData`.
        let batteryData = properties.dictionary("BatteryData") ?? [:]
        func capacity(_ key: String) -> Int? { properties.int(key) ?? batteryData.int(key) }
        let source = internalBatteryDescription()
        return BatteryInfo(
            percent: sample.percent,
            isCharging: sample.isCharging,
            isPluggedIn: sample.isPluggedIn,
            cycleCount: sample.cycleCount,
            health: sample.health,
            designCapacity: capacity("DesignCapacity"),
            fullChargeCapacity: capacity("AppleRawMaxCapacity") ?? capacity("NominalChargeCapacity"),
            condition: SystemFacts.batteryCondition(
                health: source?[kIOPSBatteryHealthKey] as? String,
                healthCondition: source?[kIOPSBatteryHealthConditionKey] as? String,
                capacity: sample.health
            )
        )
    }

    /// The power source framework's description of the internal battery,
    /// which carries macOS's health verdict when it has one.
    private static func internalBatteryDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { return description }
        }
        return nil
    }
}
