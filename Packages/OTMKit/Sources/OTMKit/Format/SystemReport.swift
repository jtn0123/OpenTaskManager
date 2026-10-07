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
    /// An IP address, router, DNS server, search domain or proxy host: shown
    /// on the page and copied, but left out of a saved report unless
    /// identifiers are included, since a report gets shared.
    public var isAddress = false
    /// One of an attached device's facts, under its heading: the page shows
    /// it once the device is opened. Copied and saved text always keep it.
    public var isDetail = false
    /// On a device's heading, the status worth seeing without opening it
    /// ("built-in", "battery 80%", "default for output").
    public var state: String?
    /// On a device's heading, how many hubs or devices it's plugged in behind.
    public var depth = 0
    public var status: Status?
    /// On a network port's heading, its BSD name ("en0"), so the page can
    /// link the port to its traffic.
    public var interface: String?

    public init(_ label: String, _ value: String, isHeading: Bool = false, isSensitive: Bool = false, isCode: Bool = false,
                isAddress: Bool = false, isDetail: Bool = false, state: String? = nil, depth: Int = 0, status: Status? = nil,
                interface: String? = nil) {
        self.label = label
        self.value = value
        self.isHeading = isHeading
        self.isSensitive = isSensitive
        self.isCode = isCode
        self.isAddress = isAddress
        self.isDetail = isDetail
        self.state = state
        self.depth = depth
        self.status = status
        self.interface = interface
    }

    /// A heading's note and state together: "5 Gb/s, built-in".
    public var headingNote: String {
        [value, state ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A section's rows as an attached-device card shows them: runs of plain
/// rows, and each device with the facts it keeps behind a disclosure.
public enum InfoBlock: Sendable, Hashable {
    case rows([InfoRow])
    case device(InfoRow, details: [InfoRow])
}

public struct InfoSection: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case processor, memory, graphics, displays, storage, network, networkConfiguration, usb, thunderbolt, bluetooth, audio, battery,
             software, security

        /// USB, Thunderbolt, Bluetooth, and audio and video: the cards
        /// listing what's attached, which keep their own heights on the page.
        public var isAttachedDevice: Bool {
            switch self {
            case .usb, .thunderbolt, .bluetooth, .audio: true
            default: false
            }
        }

        /// The ports and the configuration: a pair the page keeps together.
        public var isNetwork: Bool {
            self == .network || self == .networkConfiguration
        }
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let title: String
    public let rows: [InfoRow]

    /// Whether some rows wait behind a device's disclosure.
    public var hasDetails: Bool { rows.contains(where: \.isDetail) }

    /// The rows grouped for an attached-device card: a heading takes the
    /// detail rows after it, and the other rows run together.
    public var blocks: [InfoBlock] {
        var blocks: [InfoBlock] = []
        for row in rows {
            if row.isHeading {
                blocks.append(.device(row, details: []))
            } else if row.isDetail, case let .device(heading, details) = blocks.last {
                blocks[blocks.count - 1] = .device(heading, details: details + [row])
            } else if case let .rows(run) = blocks.last {
                blocks[blocks.count - 1] = .rows(run + [row])
            } else {
                blocks.append(.rows([row]))
            }
        }
        return blocks
    }
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
        ]
        sections += networkSections(info.network, info.networkConfiguration)
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
        var lines = [hardware.displayName, summaryLine(info)]
        if includeIdentifiers {
            lines += identifiers(hardware).map { "\($0.label): \($0.value)" }
        }
        lines += textLines(sections(info, displays: displays, devices: devices, security: security, now: now),
                           includeIdentifiers: includeIdentifiers)
        return lines.joined(separator: "\n") + "\n"
    }

    /// "Mac17,8 · Apple M5 Pro · 48 GB memory · macOS 27.2 (26B5101f)".
    static func summaryLine(_ info: SystemInfo) -> String {
        let hardware = info.hardware
        return "\(hardware.modelIdentifier) · \(hardware.chip) · \(SystemFacts.memorySize(hardware.physicalMemory)) memory"
            + " · \(info.software.macOSDescription)"
    }

    /// Just the attached devices, as `otm devices` prints them.
    public static func deviceText(_ devices: PeripheralInventory, includeIdentifiers: Bool) -> String {
        textLines(deviceSections(devices), includeIdentifiers: includeIdentifiers).dropFirst().joined(separator: "\n") + "\n"
    }

    /// Just the network cards, as `otm netconfig` prints them: addresses as
    /// the page shows and copies them, MAC addresses only with `includeIdentifiers`.
    public static func networkText(_ ports: [NetworkPortInfo], configuration: NetworkConfiguration?, includeIdentifiers: Bool) -> String {
        textLines(networkSections(ports, configuration), includeIdentifiers: includeIdentifiers).dropFirst().joined(separator: "\n") + "\n"
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
                    let note = row.headingNote
                    lines.append("  " + row.label + (note.isEmpty ? "" : " (\(note))"))
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
