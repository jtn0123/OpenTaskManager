import Foundation

/// A label and value on the System page, and a line of its plain-text summary.
public struct InfoRow: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case good, warning, unknown
    }

    public let label: String
    public let value: String
    /// Starts a group within a section (one display, one drive); `value` is a short note.
    public var isHeading = false
    /// Identifies this machine (serial number, hardware UUID, MAC address): hidden unless asked for.
    public var isSensitive = false
    /// An address or identifier someone may copy: shown monospaced, one item per line.
    public var isCode = false
    public var status: Status?

    public init(_ label: String, _ value: String, isHeading: Bool = false, isSensitive: Bool = false, isCode: Bool = false,
                status: Status? = nil) {
        self.label = label
        self.value = value
        self.isHeading = isHeading
        self.isSensitive = isSensitive
        self.isCode = isCode
        self.status = status
    }
}

public struct InfoSection: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case processor, memory, graphics, displays, storage, network, usb, thunderbolt, bluetooth, audio, battery, software, security
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let title: String
    public let rows: [InfoRow]
}

/// Turns a `SystemInfo` into titled label/value sections, shared by the
/// System page's cards and the plain-text summary it copies.
public enum SystemReport {
    /// `devices` is nil while the device report is still being read.
    public static func sections(
        _ info: SystemInfo, displays: [DisplayInfo], devices: PeripheralInventory?, security: SecurityStatus?, now: Date = Date()
    ) -> [InfoSection] {
        var sections = [
            InfoSection(kind: .processor, title: "Processor", rows: processor(info)),
            InfoSection(kind: .memory, title: "Memory", rows: memory(info)),
            InfoSection(kind: .graphics, title: "Graphics", rows: graphics(info)),
            InfoSection(kind: .displays, title: "Displays", rows: self.displays(displays)),
            InfoSection(kind: .storage, title: "Storage", rows: storage(info)),
            InfoSection(kind: .network, title: "Network", rows: network(info)),
        ]
        sections += deviceSections(devices)
        if let battery = info.battery {
            sections.append(InfoSection(kind: .battery, title: "Battery", rows: self.battery(battery)))
        }
        sections.append(InfoSection(kind: .software, title: "Software", rows: software(info.software, now: now)))
        sections.append(InfoSection(kind: .security, title: "Security", rows: self.security(security)))
        return sections
    }

    /// The whole page as plain text. Serial number, hardware UUID and MAC
    /// addresses are left out unless `includeIdentifiers` is set.
    public static func text(
        _ info: SystemInfo, displays: [DisplayInfo], devices: PeripheralInventory?, security: SecurityStatus?, includeIdentifiers: Bool,
        now: Date = Date()
    ) -> String {
        let hardware = info.hardware
        var lines = [
            hardware.displayName,
            "\(hardware.modelIdentifier) · \(hardware.chip) · \(SystemFacts.memorySize(hardware.physicalMemory)) memory"
                + " · \(info.software.macOSDescription)",
        ]
        if includeIdentifiers {
            lines += identifiers(hardware).map { "\($0.label): \($0.value)" }
        }
        lines += textLines(sections(info, displays: displays, devices: devices, security: security, now: now),
                           includeIdentifiers: includeIdentifiers)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Just the attached devices, as `otm devices` prints them.
    public static func deviceText(_ devices: PeripheralInventory, includeIdentifiers: Bool) -> String {
        textLines(deviceSections(devices), includeIdentifiers: includeIdentifiers).dropFirst().joined(separator: "\n") + "\n"
    }

    /// Each section as a blank line, its title and indented rows.
    private static func textLines(_ sections: [InfoSection], includeIdentifiers: Bool) -> [String] {
        var lines: [String] = []
        for section in sections {
            let rows = section.rows.filter { includeIdentifiers || !$0.isSensitive }
            guard !rows.isEmpty else { continue }
            lines.append("")
            lines.append(section.title)
            var indent = "  "
            for row in rows {
                if row.isHeading {
                    lines.append("  " + row.label + (row.value.isEmpty ? "" : " (\(row.value))"))
                    indent = "    "
                } else {
                    // Further lines of a list (several addresses) line up under the first.
                    let continuation = "\n" + indent + String(repeating: " ", count: row.label.count + 2)
                    lines.append(indent + row.label + ": " + row.value.replacingOccurrences(of: "\n", with: continuation))
                }
            }
        }
        return lines
    }

    /// Serial number and hardware UUID, as sensitive rows.
    public static func identifiers(_ hardware: MacHardware) -> [InfoRow] {
        [
            InfoRow("Serial number", hardware.serialNumber ?? "Unavailable", isSensitive: true),
            InfoRow("Hardware UUID", hardware.hardwareUUID ?? "Unavailable", isSensitive: true),
        ]
    }

    // MARK: - Sections

    private static func processor(_ info: SystemInfo) -> [InfoRow] {
        let topology = info.topology
        var rows = [
            InfoRow("Chip", info.hardware.chip),
            InfoRow("Cores", SystemFacts.coreSummary(topology)),
        ]
        if topology.tiers.count > 1 {
            for tier in topology.tiers {
                let cache = tier.l2CacheBytes.map { " · \(Format.bytes(UInt64($0))) L2 per cluster" } ?? ""
                rows.append(InfoRow("\(tier.name) cores", "\(tier.physicalCPUs)\(cache)"))
            }
        }
        rows.append(InfoRow("Logical CPUs", String(topology.logicalCores)))
        rows.append(InfoRow("Architecture", topology.isAppleSilicon ? "Apple silicon (arm64)" : topology.architecture))
        if let l1 = topology.l1DataCacheBytes {
            let instructions = topology.l1InstructionCacheBytes.map { " data, \(Format.bytes(UInt64($0))) instruction" } ?? ""
            rows.append(InfoRow("L1 cache", "\(Format.bytes(UInt64(l1)))\(instructions) per core"))
        }
        if topology.tiers.count <= 1, let l2 = topology.l2CacheBytes {
            rows.append(InfoRow("L2 cache", Format.bytes(UInt64(l2))))
        }
        if let l3 = topology.l3CacheBytes { rows.append(InfoRow("L3 cache", Format.bytes(UInt64(l3)))) }
        return rows
    }

    private static func memory(_ info: SystemInfo) -> [InfoRow] {
        var rows = [InfoRow("Installed", SystemFacts.memorySize(info.hardware.physicalMemory))]
        if info.topology.isAppleSilicon {
            rows.append(InfoRow("Kind", "Unified memory, shared by the CPU, GPU and Neural Engine"))
        }
        if let page = info.hardware.pageSize {
            rows.append(InfoRow("Page size", Format.bytes(UInt64(page))))
        }
        return rows
    }

    private static func graphics(_ info: SystemInfo) -> [InfoRow] {
        guard !info.gpus.isEmpty else { return [InfoRow("GPU", "None found")] }
        var rows: [InfoRow] = []
        for gpu in info.gpus {
            if info.gpus.count > 1 { rows.append(InfoRow(gpu.name, "", isHeading: true)) } else { rows.append(InfoRow("GPU", gpu.name)) }
            if let cores = gpu.coreCount { rows.append(InfoRow("Cores", String(cores))) }
        }
        if info.topology.isAppleSilicon {
            rows.append(InfoRow("Memory", "Shares the \(SystemFacts.memorySize(info.hardware.physicalMemory)) of unified memory"))
        }
        return rows
    }

    private static func displays(_ displays: [DisplayInfo]) -> [InfoRow] {
        guard !displays.isEmpty else { return [InfoRow("Displays", "None found")] }
        var rows: [InfoRow] = []
        for display in displays {
            let notes = [display.isBuiltIn ? "built-in" : nil, display.isMain ? "main" : nil].compactMap { $0 }
            rows.append(InfoRow(display.name, notes.joined(separator: ", "), isHeading: true))
            rows.append(InfoRow("Resolution", SystemFacts.resolution(display)))
            if display.pointWidth != display.pixelWidth || display.pointHeight != display.pixelHeight {
                rows.append(InfoRow("Looks like", "\(display.pointWidth) × \(display.pointHeight)"))
            }
            rows.append(InfoRow("Scale", Format.fixed(display.scale, display.scale.rounded() == display.scale ? 0 : 1) + "×"))
            if let rate = display.refreshRate, rate > 0 { rows.append(InfoRow("Refresh rate", SystemFacts.refreshRate(rate))) }
        }
        return rows
    }

    /// Each drive with the volumes stored on it, then volumes with no drive
    /// of their own here (disk images, network shares).
    private static func storage(_ info: SystemInfo) -> [InfoRow] {
        func volumeRow(_ volume: VolumeInfo) -> InfoRow {
            let format = volume.fileSystem.map { " · \($0)" } ?? ""
            return InfoRow(volume.name, "\(SystemFacts.decimalBytes(volume.availableBytes)) free of "
                + "\(SystemFacts.decimalBytes(volume.totalBytes))\(format)")
        }
        let volumes = info.volumes.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
        var rows: [InfoRow] = []
        for disk in info.disks {
            let place = disk.isInternal.map { $0 ? "Internal" : "External" }
            let medium = disk.isSolidState.map { $0 ? "SSD" : "hard disk" }
            rows.append(InfoRow(disk.model ?? disk.bsdName, [place, medium].compactMap { $0 }.joined(separator: " "), isHeading: true))
            if let size = disk.size { rows.append(InfoRow("Capacity", SystemFacts.decimalBytes(size))) }
            rows.append(InfoRow("Device", disk.bsdName, isCode: true))
            rows += volumes.filter { $0.physicalDisk == disk.bsdName }.map(volumeRow)
        }
        let known = Set(info.disks.map(\.bsdName))
        let others = volumes.filter { $0.physicalDisk.map { !known.contains($0) } ?? true }
        if !others.isEmpty {
            rows.append(InfoRow(info.disks.isEmpty ? "Volumes" : "Other volumes", "", isHeading: true))
            rows += others.map(volumeRow)
        }
        return rows.isEmpty ? [InfoRow("Storage", "None found")] : rows
    }

    private static func network(_ info: SystemInfo) -> [InfoRow] {
        let ports = info.network.filter(\.isWorthListing)
        guard !ports.isEmpty else { return [InfoRow("Network", "No active connections")] }
        var rows: [InfoRow] = []
        for port in ports {
            // Ports without a friendly name ("bridge100") would otherwise repeat it.
            rows.append(InfoRow(port.displayName, port.displayName == port.name ? "" : port.name, isHeading: true))
            let connected = port.isUp && !port.addresses.isEmpty
            rows.append(InfoRow("Status", connected ? "Connected" : "Not connected", status: connected ? .good : nil))
            let ipv4 = port.addresses.filter { !$0.contains(":") }
            let ipv6 = port.addresses.filter { $0.contains(":") && !$0.lowercased().hasPrefix("fe80") }
            if !ipv4.isEmpty { rows.append(InfoRow("IPv4", ipv4.joined(separator: "\n"), isCode: true)) }
            if !ipv6.isEmpty { rows.append(InfoRow("IPv6", ipv6.joined(separator: "\n"), isCode: true)) }
            if let speed = port.linkSpeed, connected {
                rows.append(InfoRow("Link speed", Format.bitsPerSecond(Double(speed) / 8)))
            }
            if let address = port.hardwareAddress {
                rows.append(InfoRow("Hardware address", address, isSensitive: true, isCode: true))
            }
        }
        return rows
    }

    private static func battery(_ battery: BatteryInfo) -> [InfoRow] {
        var rows: [InfoRow] = []
        if let percent = battery.percent {
            let state = battery.isCharging ? "charging" : battery.isPluggedIn ? "plugged in" : "on battery"
            rows.append(InfoRow("Charge", "\(percent)%, \(state)"))
        }
        if let condition = battery.condition {
            rows.append(InfoRow("Condition", condition.summary + (condition.isEstimated ? " (judged from capacity)" : ""),
                                status: condition.summary == "Normal" ? .good : .warning))
        }
        if let cycles = battery.cycleCount { rows.append(InfoRow("Cycle count", String(cycles))) }
        if let health = battery.health {
            var value = Format.percent(health) + " of design capacity"
            if let full = battery.fullChargeCapacity, let design = battery.designCapacity {
                value += " (\(full) of \(design) mAh)"
            }
            rows.append(InfoRow("Full charge", value))
        }
        return rows
    }

    private static func software(_ software: SoftwareInfo, now: Date) -> [InfoRow] {
        var rows = [InfoRow("macOS", software.productVersion + (software.build.map { " (\($0))" } ?? ""))]
        if let release = software.kernelRelease ?? software.kernel?.release {
            rows.append(InfoRow("Kernel", "Darwin \(release)"))
        }
        if let kernel = software.kernel, let xnu = kernel.xnu {
            rows.append(InfoRow("Kernel build", xnu + (kernel.configuration.map { " (\($0))" } ?? "")))
        }
        if let name = software.computerName { rows.append(InfoRow("Computer name", name)) }
        if let host = software.localHostName { rows.append(InfoRow("Local host name", host, isCode: true)) }
        if let boot = software.bootTime {
            rows.append(InfoRow("Started up", boot.formatted(date: .abbreviated, time: .shortened)))
            rows.append(InfoRow("Up time", Format.duration(now.timeIntervalSince(boot))))
        }
        return rows
    }

    private static func security(_ status: SecurityStatus?) -> [InfoRow] {
        guard let status else {
            return ["System Integrity Protection", "FileVault", "Gatekeeper"].map { InfoRow($0, "Checking…") }
        }
        func row(_ label: String, _ summary: String?, protected: Bool?) -> InfoRow {
            guard let summary, let protected else { return InfoRow(label, "Couldn't read", status: .unknown) }
            return InfoRow(label, summary, status: protected ? .good : .warning)
        }
        return [
            row("System Integrity Protection", status.sip?.summary, protected: status.sip?.isProtected),
            row("FileVault", status.fileVault?.summary, protected: status.fileVault?.isProtected),
            row("Gatekeeper", status.gatekeeper?.summary, protected: status.gatekeeper?.isProtected),
        ]
    }
}
