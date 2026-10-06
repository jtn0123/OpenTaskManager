import Darwin
import Foundation
import OTMKit

let version = "0.1.0"

let usage = """
otm \(version): OpenTaskManager from the terminal

USAGE:
  otm ps [-n COUNT] [--sort cpu|mem|power|gpu|disk|pid|name] [--json]
  otm top [-n COUNT] [--sort KEY] [--interval SECONDS]
  otm system [--json]
  otm power [--json]             System, CPU/GPU/ANE/DRAM and cluster power,
                                 clocks, adapter and battery flow
  otm ports [--json]             Listening TCP/UDP ports of your processes
  otm inspect PID [--json]       Arguments, environment and open files
  otm kill PID [--signal NAME]   NAME: term (default), kill, int, hup, stop, cont
  otm --version
"""

struct Options {
    var command = "ps"
    var positional: [String] = []
    var count = 20
    var sort = "cpu"
    var json = false
    var interval = 1.0
    var signal = "term"
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    if let first = arguments.first, !first.hasPrefix("-") {
        options.command = first
        _ = iterator.next()
    }
    while let argument = iterator.next() {
        switch argument {
        case "-n", "--count": options.count = iterator.next().flatMap(Int.init) ?? options.count
        case "-s", "--sort": options.sort = iterator.next() ?? options.sort
        case "-i", "--interval": options.interval = iterator.next().flatMap(Double.init) ?? options.interval
        case "--signal": options.signal = iterator.next() ?? options.signal
        case "--json": options.json = true
        case "-h", "--help": options.command = "help"
        case "-v", "--version": options.command = "version"
        default: options.positional.append(argument)
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("otm: \(message)\n".utf8))
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { fail("could not encode JSON") }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
    let fill = String(repeating: " ", count: max(width - clipped.count, 0))
    return right ? fill + clipped : clipped + fill
}

func sorted(_ processes: [ProcessSample], by key: String) -> [ProcessSample] {
    switch key {
    case "mem", "memory": processes.sorted { $0.memory > $1.memory }
    case "power", "energy": processes.sorted { ($0.powerWatts ?? 0) > ($1.powerWatts ?? 0) }
    case "gpu": processes.sorted { ($0.gpuFraction ?? 0) > ($1.gpuFraction ?? 0) }
    case "disk": processes.sorted { $0.diskReadRate + $0.diskWriteRate > $1.diskReadRate + $1.diskWriteRate }
    case "pid": processes.sorted { $0.pid < $1.pid }
    case "name": processes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    default: processes.sorted { $0.cpuPercent > $1.cpuPercent }
    }
}

func processTable(_ snapshot: SystemSnapshot, options: Options) -> String {
    var lines = [
        pad("PID", 7, right: true) + "  " + pad("NAME", 28) + pad("CPU%", 7, right: true)
            + pad("MEM", 10, right: true) + pad("POWER", 9, right: true) + pad("GPU%", 6, right: true)
            + pad("THR", 5, right: true) + pad("DISK/s", 11, right: true) + "  USER",
    ]
    for process in sorted(snapshot.processes, by: options.sort).prefix(options.count) {
        let marker = process.isRestricted ? "*" : " "
        lines.append(
            pad(String(process.pid), 7, right: true) + " " + marker + pad(process.name, 28)
                + pad(Format.fixed(process.cpuPercent, 1), 7, right: true)
                + pad(Format.bytes(process.memory), 10, right: true)
                + pad(process.powerWatts.map(Format.watts) ?? "-", 9, right: true)
                + pad(process.gpuFraction.map { Format.fixed($0 * 100, 0) } ?? "-", 6, right: true)
                + pad(process.threadCount > 0 ? String(process.threadCount) : "-", 5, right: true)
                + pad(Format.bytes(process.diskReadRate + process.diskWriteRate), 11, right: true)
                + "  " + process.userName
        )
    }
    return lines.joined(separator: "\n")
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
        lines.append("GPU     \(Format.percent(gpu.deviceUtilization)) \(gpu.name)\(cores)\(clock)")
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

struct PowerReport: Encodable {
    let interval: TimeInterval
    let power: PowerSample
    let gpus: [GPUSample]
}

func describe(_ source: SystemPowerSource) -> String {
    switch source {
    case .smcSystemTotal: "SMC system total"
    case .batteryTelemetry: "battery gauge"
    case .smcInput: "SMC DC input"
    case .batteryDischarge: "battery discharge"
    }
}

/// Signed battery flow: "+12.0 W charging", "-8.21 W discharging".
func batteryFlow(_ watts: Double) -> String {
    if abs(watts) < 0.05 { return "idle" }
    return (watts > 0 ? "+" : "-") + Format.watts(abs(watts)) + (watts > 0 ? " charging" : " discharging")
}

func powerSummary(_ snapshot: SystemSnapshot) -> String {
    let power = snapshot.power
    var lines: [String] = []
    if let watts = power.systemWatts {
        lines.append("System    \(Format.watts(watts))" + (power.systemWattsSource.map { " (\(describe($0)))" } ?? ""))
    } else {
        lines.append("System    unavailable")
    }
    if let adapter = power.adapter {
        var line = "Adapter   \(adapter.name ?? "connected")"
        if let rated = adapter.ratedWatts { line += ", rated " + (rated == rated.rounded() ? "\(Int(rated)) W" : Format.watts(rated)) }
        if let input = adapter.inputWatts { line += ", drawing \(Format.watts(input))" }
        lines.append(line)
    }
    if let battery = power.battery {
        let flow = battery.watts.map { ", \(batteryFlow($0))" } ?? ""
        lines.append("Battery   \(battery.percent)%\(flow)")
    }

    if let components = power.components {
        lines.append("Components (measured total \(Format.watts(components.total)))")
        let names: [(PowerComponent, String)] = [(.cpu, "CPU"), (.gpu, "GPU"), (.ane, "ANE"), (.dram, "DRAM")]
        for (component, name) in names {
            guard let watts = components.watts(component) else {
                lines.append("  \(pad(name, 6))—  not measured")
                continue
            }
            let note = components.sources[component] == .smc ? "  (SMC)" : ""
            lines.append("  \(pad(name, 6))\(Format.watts(watts))\(note)")
        }
        if !components.clusters.isEmpty {
            lines.append("  " + pad("CLUSTER", 24) + pad("POWER", 9, right: true) + pad("CLOCK", 11, right: true) + pad("ACTIVE", 8, right: true))
            for cluster in components.clusters {
                lines.append("  " + pad("\(cluster.name) (\(cluster.channel))", 24)
                    + pad(cluster.watts.map(Format.watts) ?? "—", 9, right: true)
                    + pad(cluster.frequencyMHz.map { Format.frequency(megahertz: $0) } ?? "—", 11, right: true)
                    + pad(cluster.activeFraction.map { Format.percent($0, digits: 1) } ?? "—", 8, right: true))
            }
        }
    } else {
        lines.append("Components unavailable (no IOReport energy data)")
    }
    for gpu in snapshot.gpus {
        let clock = gpu.frequencyMHz.map { Format.frequency(megahertz: $0) } ?? "—"
        let active = gpu.activeResidency.map { Format.percent($0, digits: 1) } ?? "—"
        lines.append("GPU       \(gpu.name): clock \(clock), active \(active)")
    }
    lines.append("Thermal   \(power.thermalState.rawValue)" + (power.isLowPowerMode ? ", Low Power Mode on" : ""))
    return lines.joined(separator: "\n")
}

struct ListeningPort: Encodable {
    let pid: Int32
    let process: String
    let proto: String
    let address: String
    let port: Int
}

func listeningPorts(_ snapshot: SystemSnapshot) -> [ListeningPort] {
    var ports: [ListeningPort] = []
    for process in snapshot.processes where !process.isRestricted {
        for file in ProcessInspector.openFiles(of: process.pid) ?? [] {
            guard let socket = file.socket, socket.isListening, let port = socket.localPort,
                  socket.proto == .tcp || socket.proto == .udp else { continue }
            ports.append(ListeningPort(pid: process.pid, process: process.name, proto: socket.proto.rawValue,
                                       address: socket.localAddress ?? "*", port: port))
        }
    }
    return ports.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
}

struct Inspection: Encodable {
    let process: ProcessSample?
    let arguments: ProcessArguments?
    let currentDirectory: String?
    let openFiles: [OpenFile]?
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let monitor = SystemMonitor()

switch options.command {
case "help":
    print(usage)

case "version":
    print("otm \(version)")

case "ps":
    let snapshot = try await monitor.measuredSample(over: .seconds(options.interval))
    if options.json {
        printJSON(Array(sorted(snapshot.processes, by: options.sort).prefix(options.count)))
    } else {
        print(processTable(snapshot, options: options))
        if snapshot.processes.contains(where: \.isRestricted) {
            print("\n* other users' and system processes: CPU and resident memory only (macOS restricts the rest)")
        }
    }

case "top":
    _ = await monitor.sample()
    while true {
        try await Task.sleep(for: .seconds(options.interval))
        let snapshot = await monitor.sample()
        print("\u{1B}[H\u{1B}[2J" + systemSummary(snapshot, topology: monitor.topology) + "\n\n" + processTable(snapshot, options: options))
    }

case "system":
    let snapshot = try await monitor.measuredSample(over: .seconds(options.interval))
    if options.json {
        printJSON(snapshot.withoutProcesses())
    } else {
        print(systemSummary(snapshot, topology: monitor.topology))
    }

case "power":
    // The process list isn't shown, so don't pay for it.
    var sampling = SystemMonitor.Options()
    sampling.includeProcesses = false
    await monitor.setOptions(sampling)
    let snapshot = try await monitor.measuredSample(over: .seconds(options.interval))
    if options.json {
        printJSON(PowerReport(interval: snapshot.interval, power: snapshot.power, gpus: snapshot.gpus))
    } else {
        print(powerSummary(snapshot))
    }

case "ports":
    let snapshot = await monitor.sample()
    let ports = listeningPorts(snapshot)
    if options.json {
        printJSON(ports)
    } else {
        print(pad("PROTO", 6) + pad("ADDRESS", 26) + pad("PORT", 7, right: true) + pad("PID", 8, right: true) + "  PROCESS")
        for port in ports {
            print(pad(port.proto, 6) + pad(port.address, 26) + pad(String(port.port), 7, right: true)
                + pad(String(port.pid), 8, right: true) + "  " + port.process)
        }
    }

case "inspect":
    guard let pid = options.positional.first.flatMap(Int32.init) else { fail("inspect needs a PID") }
    let snapshot = await monitor.sample()
    let inspection = Inspection(
        process: snapshot.processes.first { $0.pid == pid },
        arguments: ProcessInspector.arguments(of: pid),
        currentDirectory: ProcessInspector.currentDirectory(of: pid),
        openFiles: ProcessInspector.openFiles(of: pid)
    )
    guard inspection.process != nil else { fail("no process with PID \(pid)") }
    if options.json {
        printJSON(inspection)
    } else {
        let process = inspection.process!
        print("\(process.name) (PID \(process.pid), parent \(process.parentPID), user \(process.userName))")
        print("Path:       \(process.executablePath ?? "unknown")")
        print("Directory:  \(inspection.currentDirectory ?? "unavailable")")
        print("Command:    \(inspection.arguments?.commandLine ?? "unavailable (another user's process)")")
        if let environment = inspection.arguments?.environment, !environment.isEmpty {
            print("Environment (\(environment.count)):")
            for variable in environment { print("  \(variable.name)=\(variable.value)") }
        }
        if let files = inspection.openFiles {
            print("Open files (\(files.count)):")
            for file in files {
                let kind = file.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
                print("  \(pad(String(file.descriptor), 5, right: true))  \(kind)\(file.detail)")
            }
        }
    }

case "kill":
    guard let pid = options.positional.first.flatMap(Int32.init) else { fail("kill needs a PID") }
    let signals: [String: ProcessSignal] = [
        "term": .terminate, "kill": .kill, "int": .interrupt, "hup": .hangUp,
        "stop": .stop, "cont": .continue, "usr1": .user1, "usr2": .user2,
    ]
    guard let signal = signals[options.signal.lowercased().replacingOccurrences(of: "sig", with: "")] else {
        fail("unknown signal \(options.signal)")
    }
    do {
        try ProcessControl.send(signal, to: pid)
    } catch {
        fail(error.localizedDescription + (error == .permissionDenied ? " Try: sudo \(ProcessControl.shellCommand(for: signal, pids: [pid]))" : ""))
    }

default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
