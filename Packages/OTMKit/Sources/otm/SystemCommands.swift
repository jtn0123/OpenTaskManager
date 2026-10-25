import Foundation
import OTMKit

/// `otm hardware [--all] [--json]`: the memory details and the
/// Controllers and Readers card, from one `system_profiler` run.
func hardwareCommand(_ options: Options) {
    let hardware = HardwareInventoryReader.read()
    if options.json {
        guard let data = try? SystemReportDocument.hardwareJSON(hardware, includeIdentifiers: options.all) else {
            fail("could not encode JSON")
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
        print(SystemReport.hardwareText(hardware, includeIdentifiers: options.all), terminator: "")
    }
}

func systemSummary(_ snapshot: SystemSnapshot, topology: CPUTopology) -> String {
    var lines: [String] = []
    let tiers = topology.tiers.map { "\($0.logicalCPUs) \($0.name)" }.joined(separator: " + ")
    lines.append("CPU     \(Format.percent(snapshot.cpu.usage, digits: 1)) of \(topology.brand) (\(tiers))")
    for tier in topology.tiers {
        let usages = snapshot.cpu.coreUsage.enumerated().filter { topology.tierForCPU[$0.offset] == tier.level }.map(\.element)
        let average = usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
        lines.append("  \(pad(tier.name, 12)) \(Format.percent(average, digits: 1))")
    }
    let load = snapshot.cpu.loadAverage.map { Format.fixed($0, 2) }.joined(separator: " ")
    lines.append("  load \(load)   uptime \(Format.duration(snapshot.uptime))   processes \(snapshot.processes.count)")
    let memory = snapshot.memory
    lines.append("Memory  \(Format.bytes(memory.used)) of \(Format.bytes(memory.physical)) (\(memory.pressure.rawValue) pressure)")
    lines.append("  app \(Format.bytes(memory.app))  wired \(Format.bytes(memory.wired))"
        + "  compressed \(Format.bytes(memory.compressed))  cached \(Format.bytes(memory.cached))"
        + "  swap \(Format.bytes(memory.swapUsed))")
    lines.append("  page in \(Format.bytesPerSecond(memory.pageInRate))  out \(Format.bytesPerSecond(memory.pageOutRate))"
        + "  swap in \(Format.bytesPerSecond(memory.swapInRate))  out \(Format.bytesPerSecond(memory.swapOutRate))"
        + "  compress \(Format.bytesPerSecond(memory.compressionRate))  decompress \(Format.bytesPerSecond(memory.decompressionRate))")
    for gpu in snapshot.gpus {
        let cores = gpu.coreCount.map { " (\($0) cores)" } ?? ""
        let clock = gpu.frequencyMHz.map { "  \(Format.frequency(megahertz: $0))" } ?? ""
        // "n/a" when the driver doesn't report utilization (a VM's paravirtual GPU).
        let busy = gpu.deviceUtilization.map { Format.percent($0) } ?? "n/a"
        lines.append("GPU     \(busy) \(gpu.name)\(cores)\(clock)")
    }
    for disk in snapshot.disks {
        lines.append("Disk    \(disk.bsdName) \(disk.model ?? "")"
            + "  read \(Format.bytesPerSecond(disk.readBytesPerSecond))  write \(Format.bytesPerSecond(disk.writeBytesPerSecond))"
            + "  active \(Format.percent(disk.activeFraction))")
    }
    for volume in snapshot.volumes {
        lines.append("Volume  \(volume.name)  \(Format.bytes(volume.availableBytes)) free of \(Format.bytes(volume.totalBytes))")
    }
    for link in snapshot.network where link.isPrimary {
        let address = link.addresses.first ?? "no address"
        lines.append("Net     \(link.displayName) (\(link.name), \(address))"
            + "  ↓ \(Format.bitsPerSecond(link.receivedBytesPerSecond))  ↑ \(Format.bitsPerSecond(link.sentBytesPerSecond))")
    }
    let power = snapshot.power
    var powerLine = "Power   thermal \(power.thermalState.rawValue)"
    if let watts = power.systemWatts { powerLine += "  system \(Format.watts(watts))" }
    if let battery = power.battery {
        powerLine += "  battery \(battery.percent)%" + (battery.isCharging ? " charging" : battery.isPluggedIn ? " plugged in" : "")
        if let cycles = battery.cycleCount { powerLine += "  \(cycles) cycles" }
    }
    lines.append(powerLine)
    return lines.joined(separator: "\n")
}

@MainActor
func systemReportCommand(_ options: Options) async {
    // What the System page reads, the same way; the tool name stands in for the app's.
    async let security = SecurityReader.read()
    async let firewall = FirewallReader.read()
    let devices = PeripheralReader.read()
    let hardware = HardwareInventoryReader.read()
    let report = SystemReportDocument(info: SystemInfoReader.read(topology: monitor.topology), displays: DisplayReader.read(),
                                      devices: devices, devicesCollectedAt: Date(), security: await security,
                                      firewall: await firewall, hardware: hardware, hardwareCollectedAt: Date(),
                                      generator: "otm \(version)")
    if options.json {
        guard let data = try? report.json(includeIdentifiers: options.all) else { fail("could not encode JSON") }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
        print(report.markdown(includeIdentifiers: options.all), terminator: "")
    }
}

@MainActor
func systemCommand(_ options: Options) async throws {
    let snapshot = try await monitor.measuredSample(over: .seconds(options.interval))
    if options.json {
        printJSON(snapshot.withoutProcesses())
    } else {
        print(systemSummary(snapshot, topology: monitor.topology))
    }
}

func devicesCommand(_ options: Options) {
    let devices = PeripheralReader.read()
    if options.json {
        printJSON(devices)
    } else {
        print(SystemReport.deviceText(devices, includeIdentifiers: options.all), terminator: "")
    }
}
