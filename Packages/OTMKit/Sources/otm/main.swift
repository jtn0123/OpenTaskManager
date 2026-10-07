import Darwin
import Foundation
import OTMKit
import os

let version = "0.1.0"

let usage = """
otm \(version): OpenTaskManager from the terminal

USAGE:
  otm ps [-n COUNT] [--sort cpu|mem|power|gpu|ane|disk|pid|name] [--json]
                                 Top processes; ANE MEM, the memory each holds
                                 for the Neural Engine (not how busy it is),
                                 shows once any process has held some
  otm top [-n COUNT] [--sort KEY] [--interval SECONDS]
  otm system [--json]
  otm system report [--all] [--json]
                                 The app's System page as Markdown, or as the
                                 versioned JSON its Save Report writes; --all
                                 adds serial numbers, UUIDs and addresses
  otm power [--json]           System, CPU/GPU/ANE/DRAM and cluster power,
                                 clocks, adapter and battery flow
  otm sensors [--json]           Every temperature, fan speed, clock and power
                                 rail this Mac reports, grouped by part; --json
                                 gives the raw temperatures, fans and rails
  otm sensors --extremes SECONDS [--interval SECONDS] [--json]
                                 Sample that long and show each reading's
                                 lowest and highest, and the worst thermal
                                 pressure, as the Thermals page's table does
  otm ports [--json]             Listening TCP/UDP ports of your processes
  otm net [-n COUNT] [--interval SECONDS] [--json]
                                 Processes moving the most network traffic
  otm drivers [--all] [--json]   System extensions and third-party kernel
                                 extensions; --all adds Apple's kexts
  otm apps [--sizes] [--json]    Installed apps: version, kind, architecture,
                                 signer, last opened; --sizes adds disk space
  otm devices [--all] [--json]   USB, Thunderbolt, Bluetooth, audio and video
                                 devices; --all adds serial numbers and addresses
  otm netconfig [--all] [--json] Each network port's addresses, router, link,
                                 MTU and flags, then DNS, proxies, default
                                 routes, tunnels and service order; --all adds
                                 MAC addresses, and to --json (which leaves
                                 them out, like a saved report) addresses,
                                 routers, DNS servers and proxy hosts
  otm inspect PID [--json]       Arguments, environment, open files, memory
                                 (footprint, peak, resident), faults,
                                 scheduling and the processes that started it
  otm threads PID [--sort cpu|time|name|id|state|priority] [--interval SECONDS] [--json]
                                 Each thread's CPU over the interval, CPU time,
                                 state and priority (your own processes, or
                                 any with sudo)
  otm du [PATH] [--depth N] [-n COUNT] [--changes] [--json]
                                 What's using the space under PATH (default: the
                                 current folder): biggest folders and files,
                                 space by category; --changes saves the scan
                                 (as the Storage page does) and shows what grew
                                 and shrank since the last saved one
  otm netquality [INTERFACE] [--json]
                                 Internet download and upload capacity and
                                 responsiveness (macOS's networkQuality); fills
                                 the connection for about 20 s
  otm diskspeed [PATH] [--size MB] [--json]
                                 Sequential and 4K random read/write speed where
                                 PATH is (default: a temporary folder on your
                                 home volume), on a test file it always deletes:
                                 1024 MB unless --size, never over a tenth of
                                 the free space
  otm cpubench [layout] [--json]
                                 Integer, floating-point and memory speed on one
                                 worker and on every core, about 20 s; layout
                                 shows the chip's core types, clusters and caches
  otm gpubench [--json]          FP32 compute, memory bandwidth and fill rate on
                                 the GPU (Metal), timed by the GPU, about 10 s
  otm bench [list|compare A B] [--json]
                                 Every saved CPU, GPU, disk and Internet result,
                                 numbered newest first; compare shows each
                                 figure's change between runs A and B of one
                                 test, and refuses runs that don't compare
  otm kill PID [--signal NAME]   NAME: term (default), kill, int, hup, stop, cont
  otm --version
"""

struct Options {
    var command = "ps"
    var positional: [String] = []
    var count = 20
    var sort = "cpu"
    var json = false
    var all = false
    var interval = 1.0
    var signal = "term"
    var depth = 1
    var sizes = false
    var changes = false
    var extremes: Double?
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
        case "-d", "--depth": options.depth = iterator.next().flatMap(Int.init) ?? options.depth
        case "--json": options.json = true
        case "-a", "--all": options.all = true
        case "--sizes": options.sizes = true
        case "--changes": options.changes = true
        case "--extremes":
            guard let seconds = iterator.next().flatMap(Double.init), seconds >= 0 else { fail("--extremes needs a number of seconds") }
            options.extremes = seconds
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
        // The ANE and DRAM have no figure but the power manager's counters.
        let why = components.energyCountersStalled ? ": this Mac's energy counters aren't updating live" : ""
        for (component, name) in names {
            guard let watts = components.watts(component) else {
                lines.append("  \(pad(name, 6))—  not measured\(why)")
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

/// TCP listeners and bound UDP sockets, from the system-wide connection walk.
func listeningPorts(_ connections: [Connection]) -> [ListeningPort] {
    connections.compactMap { connection -> ListeningPort? in
        guard connection.kind.acceptsInbound, let port = connection.local.port else { return nil }
        return ListeningPort(pid: connection.pid, process: connection.processName, proto: connection.transport.rawValue,
                             address: connection.local.address, port: port)
    }
    .sorted { ($0.port, $0.pid, $0.proto) < ($1.port, $1.pid, $1.proto) }
}

/// System extensions, then kexts, with what needs approval called out.
func extensionTable(_ items: [ExtensionItem]) -> String {
    var lines = [" " + pad("STATUS", 21) + pad("KIND", 21) + pad("PUBLISHER", 13) + pad("VERSION", 14) + "NAME (BUNDLE ID)"]
    for item in items {
        let marker = item.status.needsAttention ? "!" : " "
        lines.append(marker + pad(item.status.title, 21) + pad(item.kind, 21) + pad(item.publisher.title, 13)
            + pad(item.version.isEmpty ? "-" : item.version, 14) + "\(item.name) (\(item.bundleID))")
    }
    return lines.joined(separator: "\n")
}

/// An installed app with its disk space, flattened into one JSON object.
struct AppReport: Encodable {
    enum Key: String, CodingKey { case allocatedBytes }

    let app: InstalledApp
    let allocatedBytes: UInt64?

    func encode(to encoder: any Encoder) throws {
        try app.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encodeIfPresent(allocatedBytes, forKey: .allocatedBytes)
    }
}

func appTable(_ apps: [InstalledApp], sizes: [String: UInt64]?) -> String {
    let day = Date.ISO8601FormatStyle().year().month().day()
    var lines = [
        pad("NAME", 30) + pad("VERSION", 16) + pad("KIND", 12) + pad("ARCH", 14) + pad("SIGNER", 14) + pad("OPENED", 11)
            + (sizes == nil ? "" : pad("SIZE", 10, right: true)) + "  STARTS",
    ]
    for app in apps {
        lines.append(
            pad(app.name, 30) + pad(app.versionText, 16) + pad(app.kind.title, 12) + pad(app.architecture.title, 14)
                + pad(app.signature.signer.title, 14) + pad(app.lastOpened.map { $0.formatted(day) } ?? "-", 11)
                + (sizes.map { pad($0[app.id].map(Format.bytes) ?? "-", 10, right: true) } ?? "")
                + "  " + (app.startsItself ? "yes" : "")
        )
    }
    return lines.joined(separator: "\n")
}

/// `otm du --json`: the scanned folder, its biggest children to `--depth`,
/// the largest files and the space by category.
struct DiskUsageReport: Encodable {
    struct Entry: Encodable {
        let name: String
        let kind: String
        let allocatedSize: UInt64
        let logicalSize: UInt64
        let itemCount: Int
        let category: String
        let children: [Entry]?
    }

    struct CategoryEntry: Encodable {
        let category: String
        let title: String
        let allocatedSize: UInt64
    }

    let path: String
    let allocatedSize: UInt64
    let logicalSize: UInt64
    let fileCount: Int
    let folderCount: Int
    let unreadableFolders: Int
    let hardLinkDuplicates: Int
    let seconds: Double
    let children: [Entry]
    let largestFiles: [DiskFile]
    let categories: [CategoryEntry]
    /// With `--changes`, when an earlier scan was saved.
    let changes: DiskChangesReport?

    init(_ usage: DiskUsage, depth: Int, count: Int, changes: DiskChangesReport? = nil) {
        self.changes = changes
        func entries(_ item: DiskItem, depth: Int) -> [Entry] {
            usage.children(of: item).prefix(count).map { child in
                Entry(name: child.kind == .smallerItems ? "\(child.itemCount) smaller items" : child.name, kind: child.kind.rawValue,
                      allocatedSize: child.allocatedSize, logicalSize: child.logicalSize, itemCount: child.itemCount,
                      category: String(describing: child.category),
                      children: depth > 1 && child.isFolder && !child.children.isEmpty ? entries(child, depth: depth - 1) : nil)
            }
        }
        path = usage.rootPath
        allocatedSize = usage.root.allocatedSize
        logicalSize = usage.root.logicalSize
        fileCount = usage.fileCount
        folderCount = usage.folderCount
        unreadableFolders = usage.unreadableFolders
        hardLinkDuplicates = usage.hardLinkDuplicates
        seconds = usage.duration
        children = entries(usage.root, depth: max(depth, 1))
        largestFiles = usage.largestFiles
        categories = usage.categories.filter { $0.allocatedSize > 0 }.map {
            CategoryEntry(category: String(describing: $0.category), title: $0.category.title, allocatedSize: $0.allocatedSize)
        }
    }
}

func diskUsageSummary(_ usage: DiskUsage, depth: Int, count: Int) -> String {
    let root = usage.root
    var lines = [
        "\(usage.rootPath): \(Format.bytes(root.allocatedSize)) on disk, \(Format.bytes(root.logicalSize)) of data"
            + " · \(usage.fileCount.formatted()) files, \(usage.folderCount.formatted()) folders · \(Format.fixed(usage.duration, 1)) s",
        "",
        pad("ON DISK", 10, right: true) + pad("SHARE", 8, right: true) + pad("ITEMS", 11, right: true) + "  NAME",
    ]
    func list(_ item: DiskItem, level: Int) {
        for child in usage.children(of: item).prefix(count) {
            let name: String
            switch child.kind {
            case .folder: name = child.name + "/" + (child.contentsOmitted ? "  (contents not kept)" : child.isUnreadable ? "  (unreadable)" : "")
            case .package, .file: name = child.name
            case .smallerItems: name = "(\(child.itemCount.formatted()) smaller items)"
            }
            let share = Double(child.allocatedSize) / Double(max(root.allocatedSize, 1))
            lines.append(pad(Format.bytes(child.allocatedSize), 10, right: true) + pad(Format.percent(share, digits: 1), 8, right: true)
                + pad(child.kind == .file ? "" : child.itemCount.formatted(), 11, right: true)
                + "  " + String(repeating: "  ", count: level) + name)
            if level + 1 < depth, child.isFolder { list(child, level: level + 1) }
        }
    }
    list(root, level: 0)
    if !usage.largestFiles.isEmpty {
        lines += ["", "Largest files"]
        for file in usage.largestFiles.prefix(min(count, 10)) {
            lines.append(pad(Format.bytes(file.allocatedSize), 10, right: true) + "  " + file.path + (file.isPackage ? "/" : ""))
        }
    }
    lines += ["", "By category"]
    for total in usage.categories where total.allocatedSize > 0 {
        let share = Double(total.allocatedSize) / Double(max(root.allocatedSize, 1))
        lines.append(pad(Format.bytes(total.allocatedSize), 10, right: true) + pad(Format.percent(share), 6, right: true)
            + "  " + total.category.title)
    }
    if usage.unreadableFolders > 0 {
        lines += ["", "\(usage.unreadableFolders.formatted()) folders couldn't be read, so their contents aren't counted."
            + " Give your terminal Full Disk Access to include them."]
    }
    return lines.joined(separator: "\n")
}

/// `otm du --changes --json`: what changed since the last saved scan.
/// Sizes a saved scan only bounds have a `low` and a `high` (none when
/// unknown); growth and shrinkage are only what both scans prove.
struct DiskChangesReport: Encodable {
    struct Size: Encodable {
        let low: UInt64
        let high: UInt64?

        init(_ estimate: DiskSizeEstimate) {
            low = estimate.low
            high = estimate.isBounded ? estimate.high : nil
        }
    }

    struct Change: Encodable {
        let path: String
        let kind: String
        let before: Size
        let after: Size
        let growth: UInt64
        let shrinkage: UInt64
        let exact: Bool

        init(_ change: DiskSizeChange) {
            path = change.path
            kind = String(describing: change.kind)
            before = Size(change.before)
            after = Size(change.after)
            growth = change.growth
            shrinkage = change.shrinkage
            exact = change.isExact
        }
    }

    let since: Date
    let ignoredUnder: UInt64
    let total: Change
    let grew: [Change]
    let shrank: [Change]
    let filesAdded: [Change]
    let filesRemoved: [Change]
    let becameUnreadable: [Change]
    let becameReadable: [Change]

    init(_ comparison: DiskScanComparison, count: Int) {
        let threshold = DiskScanComparison.noiseFloor(for: comparison.later.allocatedSize)
        let report = comparison.report(limit: count, ignoringUnder: threshold)
        since = comparison.earlier.scannedAt
        ignoredUnder = threshold
        total = Change(report.total)
        grew = report.grew.map(Change.init)
        shrank = report.shrank.map(Change.init)
        filesAdded = report.filesAdded.map(Change.init)
        filesRemoved = report.filesRemoved.map(Change.init)
        becameUnreadable = report.becameUnreadable.map(Change.init)
        becameReadable = report.becameReadable.map(Change.init)
    }
}

func diskChangesSummary(_ comparison: DiskScanComparison, count: Int) -> String {
    let threshold = DiskScanComparison.noiseFloor(for: comparison.later.allocatedSize)
    let report = comparison.report(limit: count, ignoringUnder: threshold)
    let total = report.total
    let direction = total.direction(ignoringUnder: threshold)
    let amount = switch direction {
    case .grew: Format.byteChange(total.growth, grew: true, exact: total.isExact)
    case .shrank: Format.byteChange(total.shrinkage, grew: false, exact: total.isExact)
    case .same: "no change"
    case .unclear: "can't tell"
    }
    var lines = ["", "Changes since \(comparison.earlier.scannedAt.formatted(date: .abbreviated, time: .shortened)): \(amount)"
        + " (\(Format.bytes(total.before)) → \(Format.bytes(total.after)))"]
    func section(_ title: String, _ changes: [DiskSizeChange], grew: Bool?) {
        guard !changes.isEmpty else { return }
        lines += ["", title]
        for change in changes {
            let figure = grew.map { Format.byteChange($0 ? change.growth : change.shrinkage, grew: $0, exact: change.isExact) } ?? ""
            let suffix = change.kind == .file ? "" : "/"
            let note = change.isNew && change.before.isExact ? "  (new)" : change.isGone && change.after.isExact ? "  (removed)" : ""
            lines.append(pad(figure, 18, right: true) + "  " + change.path + suffix + note)
        }
    }
    section("Grew", report.grew, grew: true)
    section("Shrank", report.shrank, grew: false)
    section("Large files added", report.filesAdded, grew: true)
    section("Large files removed", report.filesRemoved, grew: false)
    section("Couldn't be read this time (not counted as space freed)", report.becameUnreadable, grew: nil)
    section("Could be read this time (not counted as growth)", report.becameReadable, grew: nil)
    if report.isEmpty { lines.append("Nothing changed by more than \(Format.bytes(threshold)).") }
    return lines.joined(separator: "\n")
}

/// Samples the sensors, and the power figures read alongside them, every
/// `interval` seconds until `seconds` have passed (at least once), keeping
/// each reading's range as the app's Thermals table does.
func sensorReport(over seconds: Double, interval: Double) async throws -> SensorExtremesReport {
    var sampling = SystemMonitor.Options()
    sampling.includeProcesses = false
    await monitor.setOptions(sampling)
    let sensorMonitor = SensorMonitor()
    let interval = max(interval, 0.25)
    if seconds >= 5 {
        FileHandle.standardError.write(Data("Sampling every \(Format.timeSpan(interval)) for \(Format.timeSpan(seconds))…\n".utf8))
    }
    // The baseline: clocks and component power are rates over an interval.
    _ = await monitor.sample()
    var extremes = SensorExtremes(since: Date())
    var readings: [SensorReading] = []
    var thermalState: ThermalState?
    var sensors: SensorSample?
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: .seconds(seconds))
    repeat {
        try await Task.sleep(for: .seconds(interval))
        async let reading = sensorMonitor.sample()
        let snapshot = await monitor.sample()
        sensors = await reading
        readings = SensorTable.readings(sensors: sensors, power: snapshot.power, gpus: snapshot.gpus)
        thermalState = snapshot.power.thermalState
        extremes.record(readings, thermalState: thermalState)
    } while clock.now < end
    return SensorExtremesReport(extremes: extremes, rows: readings, thermalState: thermalState, until: Date(),
                                interval: interval, sensors: sensors)
}

/// The report as a table by group: each reading now, with its lowest and
/// highest when `extremes`, or where it came from otherwise.
func sensorTable(_ report: SensorExtremesReport, extremes: Bool) -> String {
    func value(_ number: Double?, _ reading: SensorReading) -> String {
        number.map(reading.unit.format) ?? reading.note ?? "—"
    }
    var lines: [String] = []
    let pressure = report.thermalPressure
    var line = "\(pad("Thermal pressure", 26))\(pressure.now?.rawValue ?? "unknown")"
    if extremes, let mildest = pressure.mildest, let worst = pressure.worst {
        line += "  (mildest \(mildest.rawValue), worst \(worst.rawValue))"
    }
    lines.append(line)
    var group: SensorGroup?
    for row in report.rows {
        let reading = row.reading
        if reading.group != group {
            group = reading.group
            let columns = extremes
                ? pad("NOW", 12, right: true) + pad("LOWEST", 12, right: true) + pad("HIGHEST", 12, right: true)
                : pad("NOW", 12, right: true) + "  SOURCE"
            lines += ["", pad(reading.group.title.uppercased(), 26) + columns]
        }
        var text = "  " + pad(reading.label, 24) + pad(value(reading.value, reading), 12, right: true)
        if extremes {
            text += pad(value(row.lowest, reading), 12, right: true) + pad(value(row.highest, reading), 12, right: true)
        } else {
            text += "  " + reading.source.shortTitle + (reading.origin.map { " \($0)" } ?? "")
        }
        lines.append(text)
    }
    if report.rows.isEmpty {
        lines += ["", "No temperatures, fan speeds, clocks or power rails found."]
    }
    if extremes {
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        lines += ["", "\(report.samples) samples every \(Format.timeSpan(report.interval)), "
            + "\(report.since.formatted(time)) to \(report.until.formatted(time))."]
    }
    return lines.joined(separator: "\n")
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

case "system" where options.positional.first == "report":
    // What the System page reads, the same way; the tool name stands in for the app's.
    async let security = SecurityReader.read()
    let devices = PeripheralReader.read()
    let report = SystemReportDocument(info: SystemInfoReader.read(topology: monitor.topology), displays: DisplayReader.read(),
                                      devices: devices, devicesCollectedAt: Date(), security: await security,
                                      generator: "otm \(version)")
    if options.json {
        guard let data = try? report.json(includeIdentifiers: options.all) else { fail("could not encode JSON") }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
        print(report.markdown(includeIdentifiers: options.all), terminator: "")
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

case "sensors":
    if options.json, options.extremes == nil {
        printJSON(await SensorMonitor().sample())
        break
    }
    let report = try await sensorReport(over: options.extremes ?? 0, interval: options.interval)
    if options.json {
        printJSON(report)
    } else {
        print(sensorTable(report, extremes: options.extremes != nil))
    }

case "apps":
    let apps = InstalledApps.scan()
    var sizes: [String: UInt64]?
    if options.sizes {
        let measured = OSAllocatedUnfairLock(initialState: [String: UInt64]())
        BoundedWork.forEach(apps.map(\.resolvedPath), width: 4) { path in
            if let size = InstalledApps.allocatedSize(ofBundleAt: path) { measured.withLock { $0[path] = size } }
        }
        sizes = measured.withLock { $0 }
    }
    if options.json {
        printJSON(apps.map { AppReport(app: $0, allocatedBytes: sizes?[$0.id]) })
    } else {
        print(appTable(apps, sizes: sizes))
        let intel = apps.filter { $0.architecture == .intel }.count
        var footer = "\n\(apps.count) apps"
        if intel > 0 { footer += ", \(intel) Intel only (run under Rosetta)" }
        if let sizes { footer += ", \(Format.bytes(sizes.values.reduce(0, +))) on disk" }
        print(footer)
    }

case "netconfig":
    // The System page's two network cards, read the same way.
    let ports = SystemInfoReader.readNetwork()
    let configuration = NetworkConfigurationReader.read()
    if options.json {
        guard let data = try? SystemReportDocument.networkJSON(ports, configuration: configuration, includeIdentifiers: options.all) else {
            fail("could not encode JSON")
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else {
        print(SystemReport.networkText(ports, configuration: configuration, includeIdentifiers: options.all), terminator: "")
    }

case "devices":
    let devices = PeripheralReader.read()
    if options.json {
        printJSON(devices)
    } else {
        print(SystemReport.deviceText(devices, includeIdentifiers: options.all), terminator: "")
    }

case "ports":
    let sample = ConnectionSampler.sample()
    let ports = listeningPorts(sample.connections)
    if options.json {
        printJSON(ports)
    } else {
        print(pad("PROTO", 6) + pad("ADDRESS", 26) + pad("PORT", 7, right: true) + pad("PID", 8, right: true) + "  PROCESS")
        for port in ports {
            print(pad(port.proto, 6) + pad(port.address, 26) + pad(String(port.port), 7, right: true)
                + pad(String(port.pid), 8, right: true) + "  " + port.process)
        }
        if sample.hiddenProcesses > 0 {
            print("\n\(sample.hiddenProcesses) processes of root and other users hidden (macOS restricts them; try sudo)")
        }
    }

case "net":
    guard let before = ProcessNetwork.read() else { fail("nettop couldn't run") }
    let started = Date()
    try await Task.sleep(for: .seconds(options.interval))
    guard let after = ProcessNetwork.read() else { fail("nettop couldn't run") }
    let rates = Array(ProcessNetwork.rates(from: before, to: after, interval: Date().timeIntervalSince(started)).prefix(options.count))
    if options.json {
        printJSON(rates)
    } else if rates.isEmpty {
        print("No process sent or received anything in \(Format.timeSpan(options.interval)).")
    } else {
        print(pad("PID", 7, right: true) + pad("RECEIVED", 13, right: true) + pad("SENT", 13, right: true) + "  PROCESS")
        for rate in rates {
            print(pad(String(rate.pid), 7, right: true) + pad(Format.bitsPerSecond(rate.bytesInPerSecond), 13, right: true)
                + pad(Format.bitsPerSecond(rate.bytesOutPerSecond), 13, right: true) + "  " + rate.name)
        }
    }

case "drivers":
    let scan = Extensions.scan()
    let shown = options.all ? scan.items : scan.items.filter { $0.category.isSystemExtension || $0.publisher == .thirdParty }
    if options.json {
        printJSON(shown)
    } else {
        if shown.isEmpty {
            print("No system extensions or third-party kernel extensions are loaded.")
        } else {
            print(extensionTable(shown))
        }
        var notes: [String] = []
        if !scan.readSystemExtensions { notes.append("System extensions couldn't be read: systemextensionsctl failed.") }
        if !scan.readKernelExtensions { notes.append("Kernel extensions couldn't be read.") }
        let waiting = scan.summary.needsAttention
        if waiting > 0 {
            notes.append("! \(waiting) waiting for approval in System Settings > General > Login Items & Extensions.")
        }
        let apple = scan.items.filter { $0.category == .kernel && $0.publisher == .apple }.count
        if !options.all && apple > 0 { notes.append("\(apple) Apple kernel extensions are loaded too (--all lists them).") }
        if !notes.isEmpty { print("\n" + notes.joined(separator: "\n")) }
    }

case "inspect":
    await inspectCommand(options, monitor: monitor)

case "du":
    let path = ((options.positional.first ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { fail("no folder at \(path)") }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let request = url.path == "/" ? DiskScanRequest.volume(mountPoint: "/", isRoot: true) : DiskScanRequest(root: url)
    let showsProgress = isatty(STDERR_FILENO) == 1 && !options.json
    guard let usage = DiskUsageScanner.scan(request, progress: { progress in
        guard showsProgress else { return }
        let line = "Scanning: \(progress.itemCount.formatted()) items, \(Format.bytes(progress.allocatedSize))"
        FileHandle.standardError.write(Data("\u{1B}[2K\r\(line)".utf8))
    }) else { fail("scan cancelled") }
    if showsProgress { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) }
    var comparison: DiskScanComparison?
    if options.changes {
        // The same history the Storage page keeps, so either can follow the other.
        let summary = DiskScanSummary(usage, scope: DiskScanScope(usage, request: request))
        let history = DiskScanHistory()
        let earlier = history.summaries(of: summary.scope).first { $0.scannedAt < summary.scannedAt }
        do {
            try history.save(summary)
        } catch {
            FileHandle.standardError.write(Data("otm: couldn't save this scan: \(error.localizedDescription)\n".utf8))
        }
        comparison = earlier.map { DiskScanComparison(earlier: $0, later: summary) }
    }
    if options.json {
        printJSON(DiskUsageReport(usage, depth: options.depth, count: options.count,
                                  changes: comparison.map { DiskChangesReport($0, count: options.count) }))
    } else {
        print(diskUsageSummary(usage, depth: options.depth, count: options.count))
        if let comparison {
            print(diskChangesSummary(comparison, count: options.count))
        } else if options.changes {
            print("\nNo earlier scan of this folder was saved. This one is, so the next `otm du --changes` can compare with it.")
        }
    }

case "netquality":
    await netQualityCommand(options)

case "diskspeed":
    diskSpeedCommand(options)

case "cpubench":
    cpuBenchCommand(options)

case "gpubench":
    gpuBenchCommand(options)

case "bench":
    benchCommand(options)

case "threads":
    try await threadsCommand(options)

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
