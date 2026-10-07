import AppKit
import Observation
import OTMKit

/// Per-process values kept for the inspector's graphs and the "by app" charts.
struct ProcessPoint: Sendable {
    let cpuPercent: Double
    let memory: UInt64
    let gpuFraction: Double
    let powerWatts: Double
}

/// One app's use of a resource over time, for the stacked "by app" graphs.
struct AppSeries: Identifiable {
    let id: Int64
    let name: String
    let icon: NSImage
    let values: [Double]

    var current: Double { values.last ?? 0 }
}

/// Memory composition over time, one history per kind of page.
struct MemoryHistory {
    var app = History<Double>(capacity: AppModel.historyCapacity)
    var wired = History<Double>(capacity: AppModel.historyCapacity)
    var compressed = History<Double>(capacity: AppModel.historyCapacity)
    var cached = History<Double>(capacity: AppModel.historyCapacity)
    var swapUsed = History<Double>(capacity: AppModel.historyCapacity)
    /// 0...1, from the kernel's "memory available" level.
    var pressure = History<Double>(capacity: AppModel.historyCapacity)
    /// Bytes per second.
    var pageIns = History<Double>(capacity: AppModel.historyCapacity)
    var pageOuts = History<Double>(capacity: AppModel.historyCapacity)
    var swapIns = History<Double>(capacity: AppModel.historyCapacity)
    var swapOuts = History<Double>(capacity: AppModel.historyCapacity)
    var compressions = History<Double>(capacity: AppModel.historyCapacity)
    var decompressions = History<Double>(capacity: AppModel.historyCapacity)

    mutating func append(_ memory: MemorySample) {
        app.append(Double(memory.app))
        wired.append(Double(memory.wired))
        compressed.append(Double(memory.compressed))
        cached.append(Double(memory.cached))
        swapUsed.append(Double(memory.swapUsed))
        pressure.append(memory.availablePercent.map { 1 - Double($0) / 100 } ?? memory.usedFraction)
        pageIns.append(memory.pageInRate)
        pageOuts.append(memory.pageOutRate)
        swapIns.append(memory.swapInRate)
        swapOuts.append(memory.swapOutRate)
        compressions.append(memory.compressionRate)
        decompressions.append(memory.decompressionRate)
    }
}

/// Renderer, tiler and memory history for one GPU.
struct GPUHistory {
    var renderer = History<Double>(capacity: AppModel.historyCapacity)
    var tiler = History<Double>(capacity: AppModel.historyCapacity)
    var memoryInUse = History<Double>(capacity: AppModel.historyCapacity)
    /// Average clock while powered on, in MHz. An idle interval has no clock,
    /// so it repeats the last one rather than dropping the line to zero.
    var frequency = History<Double>(capacity: AppModel.historyCapacity)

    mutating func append(_ gpu: GPUSample) {
        renderer.append(gpu.rendererUtilization ?? 0)
        tiler.append(gpu.tilerUtilization ?? 0)
        memoryInUse.append(Double(gpu.memoryInUse ?? 0))
        frequency.append(gpu.frequencyMHz ?? frequency.last ?? 0)
    }
}

/// Whole-system power split into parts of the chip, and energy used since launch.
struct PowerHistory {
    var cpu = History<Double>(capacity: AppModel.historyCapacity)
    var gpu = History<Double>(capacity: AppModel.historyCapacity)
    var ane = History<Double>(capacity: AppModel.historyCapacity)
    var dram = History<Double>(capacity: AppModel.historyCapacity)
    /// The system figure minus the chip's parts: display, SSD, radios, fans,
    /// power conversion. Never negative, though the system figure lags a beat.
    var rest = History<Double>(capacity: AppModel.historyCapacity)
    /// Per CPU cluster, keyed by name: watts, average clock (MHz) and share of
    /// time running. An idle cluster repeats its last clock, like `GPUHistory`.
    var clusterWatts: [String: History<Double>] = [:]
    var clusterFrequency: [String: History<Double>] = [:]
    var clusterActive: [String: History<Double>] = [:]
    var adapterInput = History<Double>(capacity: AppModel.historyCapacity)
    /// Into the battery; negative while it discharges.
    var battery = History<Double>(capacity: AppModel.historyCapacity)
    /// Joules since launch, for the whole system and for each measured part.
    private(set) var energy = 0.0
    private(set) var componentEnergy: [PowerComponent: Double] = [:]
    private(set) var seconds = 0.0

    mutating func append(_ power: PowerSample, interval: TimeInterval) {
        let parts = power.components
        cpu.append(parts?.watts(.cpu) ?? 0)
        gpu.append(parts?.watts(.gpu) ?? 0)
        ane.append(parts?.watts(.ane) ?? 0)
        dram.append(parts?.watts(.dram) ?? 0)
        if let system = power.systemWatts, let parts {
            rest.append(max(system - parts.total, 0))
        } else {
            rest.append(0)
        }
        for cluster in parts?.clusters ?? [] {
            clusterWatts[cluster.name, default: Self.history()].append(cluster.watts ?? 0)
            var clock = clusterFrequency[cluster.name] ?? Self.history()
            clock.append(cluster.frequencyMHz ?? clock.last ?? 0)
            clusterFrequency[cluster.name] = clock
            clusterActive[cluster.name, default: Self.history()].append(cluster.activeFraction ?? 0)
        }
        adapterInput.append(power.adapter?.inputWatts ?? 0)
        battery.append(power.adapter?.batteryWatts ?? power.battery?.watts ?? 0)

        if let system = power.systemWatts {
            energy += system * interval
            seconds += interval
        }
        for component in PowerComponent.allCases {
            if let watts = parts?.watts(component) { componentEnergy[component, default: 0] += watts * interval }
        }
    }

    /// Average whole-system draw since launch.
    var averageWatts: Double? { seconds > 0 ? energy / seconds : nil }

    private static func history() -> History<Double> {
        History(capacity: AppModel.historyCapacity)
    }
}

/// One user's CPU (100 = one core) and summed process memory over time.
struct UserHistory {
    var cpu = History<Double>(capacity: AppModel.userHistoryCapacity)
    var memory = History<Double>(capacity: AppModel.userHistoryCapacity)

    mutating func append(_ totals: UsageTotals) {
        cpu.append(totals.cpuPercent)
        memory.append(Double(totals.memory))
    }
}

enum UpdateSpeed: Double, CaseIterable, Identifiable {
    case fast = 0.5
    case normal = 1
    case slow = 2
    case verySlow = 5

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .fast: "Fast (2× per second)"
        case .normal: "Normal (every second)"
        case .slow: "Slow (every 2 seconds)"
        case .verySlow: "Very slow (every 5 seconds)"
        }
    }
}

/// How per-process CPU is shown. macOS tools count 100% per core, so a busy
/// app on an 18-core Mac can read 1,200%; the default is share of the whole CPU.
struct CPUScale: Equatable {
    var relativeToSystem: Bool
    var logicalCores: Int

    /// Converts a per-process figure (100 = one core) to the chosen scale.
    func value(_ percentOfCore: Double) -> Double {
        guard relativeToSystem else { return percentOfCore }
        return min(percentOfCore / Double(max(logicalCores, 1)), 100)
    }

    func format(_ percentOfCore: Double) -> String {
        Format.fixed(value(percentOfCore), 1) + "%"
    }
}

/// Temperatures and fan speeds over time, plus each sensor's range since launch.
struct SensorHistory {
    private(set) var hottest: [SensorKind: History<Double>] = [:]
    private(set) var chipAverage = History<Double>(capacity: AppModel.historyCapacity)
    private(set) var fans: [Int: History<Double>] = [:]
    /// Lowest and highest reading of each sensor, by sensor name.
    private(set) var ranges: [String: ClosedRange<Double>] = [:]

    mutating func append(_ sample: SensorSample) {
        for kind in SensorKind.allCases {
            if let celsius = sample.hottest(kind) {
                hottest[kind, default: History(capacity: AppModel.historyCapacity)].append(celsius)
            }
        }
        if let average = sample.average(.chip) { chipAverage.append(average) }
        for fan in sample.fans {
            fans[fan.id, default: History(capacity: AppModel.historyCapacity)].append(fan.rpm)
        }
        for reading in sample.temperatures {
            let range = ranges[reading.name] ?? reading.celsius...reading.celsius
            ranges[reading.name] = min(range.lowerBound, reading.celsius)...max(range.upperBound, reading.celsius)
        }
    }
}

/// Live state shared by every window: the latest snapshot plus graph history.
@Observable
@MainActor
final class AppModel {
    /// Samples across a full-width graph.
    nonisolated static let graphSpan = 300
    /// Two more than a graph shows, so its left edge stays filled while it scrolls.
    nonisolated static let historyCapacity = graphSpan + 2
    nonisolated static let processHistoryCapacity = 122
    /// The Users page shows a minute or so per user, so keep it short.
    nonisolated static let userHistoryCapacity = 62

    let monitor = SystemMonitor()
    let sensorMonitor = SensorMonitor()
    /// The on-disk history behind the History page. Nil if it can't be opened.
    let recorder = try? FlightRecorder(url: FlightRecorder.defaultURL)
    private var recording = HistoryAccumulator(span: FlightRecorder.span)
    let topology: CPUTopology

    private(set) var snapshot: SystemSnapshot?
    /// Temperatures and fans, read alongside each snapshot. Empty in a VM.
    private(set) var sensors: SensorSample?
    private(set) var sensorHistory = SensorHistory()
    private(set) var cpuHistory = History<Double>(capacity: historyCapacity)
    private(set) var coreHistory: [History<Double>]
    private(set) var memoryHistory = History<Double>(capacity: historyCapacity)
    private(set) var memoryDetail = MemoryHistory()
    private(set) var gpuDetail: [String: GPUHistory] = [:]
    /// Sum over every process each tick, so "by app" graphs can show the rest as "Other".
    private(set) var processGPUHistory = History<Double>(capacity: processHistoryCapacity)
    private(set) var processPowerHistory = History<Double>(capacity: processHistoryCapacity)
    private(set) var processMemoryHistory = History<Double>(capacity: processHistoryCapacity)
    /// Apps with their helpers folded in (Safari includes its web content processes).
    private(set) var appGroups: [ProcessNode] = []
    private(set) var gpuHistory: [String: History<Double>] = [:]
    private(set) var powerHistory = History<Double>(capacity: historyCapacity)
    private(set) var powerDetail = PowerHistory()
    private(set) var diskReadHistory: [String: History<Double>] = [:]
    private(set) var diskWriteHistory: [String: History<Double>] = [:]
    private(set) var networkInHistory: [String: History<Double>] = [:]
    private(set) var networkOutHistory: [String: History<Double>] = [:]
    private(set) var processHistory: [Int32: History<ProcessPoint>] = [:]
    /// Each user's processes summed, for the Users page.
    private(set) var users: [UserUsage] = []
    private(set) var userHistory: [UInt32: UserHistory] = [:]
    /// Directory lookups by uid, including misses, so each runs once.
    @ObservationIgnored private var accounts: [UInt32: UserAccount?] = [:]
    /// Regular (Dock) apps by PID, refreshed each tick for grouping and icons.
    private(set) var regularApps: [Int32: NSRunningApplication] = [:]
    private(set) var lastError: String?
    /// A process another page asked the Processes page to select, such as
    /// the owner of a socket on the Connections page. Cleared once shown.
    var requestedProcess: Int32?
    /// Highest whole-system draw seen on this Mac, kept across launches.
    private(set) var peakSystemWatts = UserDefaults.standard.double(forKey: "peakSystemWatts")

    var isPaused = false {
        didSet { isPaused ? stop() : start() }
    }

    var updateSpeed: UpdateSpeed {
        didSet {
            UserDefaults.standard.set(updateSpeed.rawValue, forKey: "updateSpeed")
            restart()
        }
    }

    var includeSystemProcesses: Bool {
        didSet {
            UserDefaults.standard.set(includeSystemProcesses, forKey: "includeSystemProcesses")
            applyMonitorOptions()
        }
    }

    var cpuRelativeToSystem: Bool {
        didSet { UserDefaults.standard.set(cpuRelativeToSystem, forKey: "cpuRelativeToSystem") }
    }

    var cpuScale: CPUScale {
        CPUScale(relativeToSystem: cpuRelativeToSystem, logicalCores: topology.logicalCores)
    }

    private var samplingTask: Task<Void, Never>?

    init() {
        topology = monitor.topology
        coreHistory = (0..<monitor.topology.logicalCores).map { _ in History(capacity: Self.historyCapacity) }
        let defaults = UserDefaults.standard
        updateSpeed = UpdateSpeed(rawValue: defaults.double(forKey: "updateSpeed")) ?? .normal
        includeSystemProcesses = defaults.object(forKey: "includeSystemProcesses") as? Bool ?? true
        cpuRelativeToSystem = defaults.object(forKey: "cpuRelativeToSystem") as? Bool ?? true
        applyMonitorOptions()
        start()
    }

    // MARK: - Sampling

    func start() {
        guard samplingTask == nil, !isPaused else { return }
        let interval = updateSpeed.rawValue
        samplingTask = Task { [weak self, monitor, sensorMonitor] in
            // Keep a steady cadence (sleep until the next deadline rather than
            // for a fixed time) so the graphs scroll at an even speed.
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                // The temperature sensors are slow to answer, so read them
                // alongside the snapshot rather than after it.
                async let readings = sensorMonitor.sample()
                let snapshot = await monitor.sample()
                let sensors = await readings
                guard let self else { return }
                self.ingest(snapshot, sensors: sensors)
                deadline = max(deadline.advanced(by: .seconds(interval)), clock.now)
                try? await Task.sleep(until: deadline, clock: clock)
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    func refreshNow() {
        Task {
            ingest(await monitor.sample(), sensors: nil)
        }
    }

    private func restart() {
        stop()
        start()
    }

    private func applyMonitorOptions() {
        var options = SystemMonitor.Options()
        options.includeRestrictedProcesses = includeSystemProcesses
        Task { [monitor] in await monitor.setOptions(options) }
    }

    private func ingest(_ snapshot: SystemSnapshot, sensors: SensorSample?) {
        // The first sample has no baseline, so its rates are all zero; keep it
        // for the process list but leave it out of the graphs.
        defer { self.snapshot = snapshot }
        if let sensors, !sensors.isEmpty {
            self.sensors = sensors
            if snapshot.interval > 0 { sensorHistory.append(sensors) }
        }
        regularApps = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        users = UserUsageBuilder.build(snapshot.processes)
        guard snapshot.interval > 0 else { return }

        var histories: [UInt32: UserHistory] = [:]
        for user in users {
            var history = userHistory[user.uid] ?? UserHistory()
            history.append(user.totals)
            histories[user.uid] = history
        }
        userHistory = histories

        cpuHistory.append(snapshot.cpu.usage)
        for (index, usage) in snapshot.cpu.coreUsage.enumerated() where index < coreHistory.count {
            coreHistory[index].append(usage)
        }
        memoryHistory.append(snapshot.memory.usedFraction)
        memoryDetail.append(snapshot.memory)
        powerHistory.append(snapshot.power.systemWatts ?? 0)
        powerDetail.append(snapshot.power, interval: snapshot.interval)
        if let watts = snapshot.power.systemWatts, watts > peakSystemWatts {
            peakSystemWatts = watts
            UserDefaults.standard.set(watts, forKey: "peakSystemWatts")
        }
        for gpu in snapshot.gpus {
            // An unreported load stays out of the history, so no graph draws it as 0%.
            if let busy = gpu.deviceUtilization {
                gpuHistory[gpu.id, default: History(capacity: Self.historyCapacity)].append(busy)
            }
            gpuDetail[gpu.id, default: GPUHistory()].append(gpu)
        }
        for disk in snapshot.disks {
            diskReadHistory[disk.id, default: History(capacity: Self.historyCapacity)].append(disk.readBytesPerSecond)
            diskWriteHistory[disk.id, default: History(capacity: Self.historyCapacity)].append(disk.writeBytesPerSecond)
        }
        for link in snapshot.network {
            networkInHistory[link.id, default: History(capacity: Self.historyCapacity)].append(link.receivedBytesPerSecond)
            networkOutHistory[link.id, default: History(capacity: Self.historyCapacity)].append(link.sentBytesPerSecond)
        }

        var processes: [Int32: History<ProcessPoint>] = [:]
        processes.reserveCapacity(snapshot.processes.count)
        var totalGPU = 0.0
        var totalPower = 0.0
        var totalMemory = 0.0
        for process in snapshot.processes {
            var history = processHistory[process.pid] ?? History(capacity: Self.processHistoryCapacity)
            let point = ProcessPoint(cpuPercent: process.cpuPercent, memory: process.memory,
                                     gpuFraction: process.gpuFraction ?? 0, powerWatts: process.powerWatts ?? 0)
            history.append(point)
            processes[process.pid] = history
            totalGPU += point.gpuFraction
            totalPower += point.powerWatts
            totalMemory += Double(point.memory)
        }
        processHistory = processes
        processGPUHistory.append(totalGPU)
        processPowerHistory.append(totalPower)
        processMemoryHistory.append(totalMemory)
        appGroups = ProcessTreeBuilder.build(snapshot.processes, mode: .grouped, appPIDs: Set(regularApps.keys))
            .flatMap(\.children)
        record(snapshot)
    }

    /// Feeds the flight recorder, which writes a record every few seconds.
    private func record(_ snapshot: SystemSnapshot) {
        guard let recorder else { return }
        let apps = appGroups.compactMap { group in
            group.process.map { AppUsage(name: displayName(for: $0), cpuPercent: group.totals.cpuPercent, memory: Double(group.totals.memory)) }
        }
        let values = HistoryValues(snapshot, chipCelsius: sensors?.hottest(.chip))
        guard let record = recording.add(values, apps: apps, interval: snapshot.interval, at: snapshot.timestamp) else { return }
        Task.detached(priority: .utility) {
            try? await recorder.append(record)
        }
    }

    // MARK: - Queries

    func process(_ pid: Int32) -> ProcessSample? {
        snapshot?.processes.first { $0.pid == pid }
    }

    func displayName(for process: ProcessSample) -> String {
        regularApps[process.pid]?.localizedName ?? process.name
    }

    func account(for uid: UInt32) -> UserAccount? {
        if let cached = accounts[uid] { return cached }
        let account = UserAccounts.account(uid: uid)
        accounts[uid] = .some(account)
        return account
    }

    /// The `count` apps that used the most of a resource over the last
    /// `window` samples, each with its history summed over the app's processes.
    func topApps(by metric: (ProcessPoint) -> Double, count: Int, window: Int = processHistoryCapacity) -> [AppSeries] {
        var ranked: [(score: Double, series: AppSeries)] = []
        for group in appGroups {
            guard let process = group.process else { continue }
            var pids: [Int32] = []
            func collect(_ node: ProcessNode) {
                if let pid = node.process?.pid { pids.append(pid) }
                node.children.forEach(collect)
            }
            collect(group)
            let values = Self.tailSum(pids.compactMap { processHistory[$0]?.values.suffix(window).map(metric) })
            let score = values.reduce(0, +)
            guard score > 0 else { continue }
            let series = AppSeries(id: group.id, name: displayName(for: process),
                                   icon: IconCache.icon(for: process, app: regularApps[process.pid]), values: values)
            ranked.append((score, series))
        }
        return ranked.sorted { $0.score > $1.score }.prefix(count).map(\.series)
    }

    /// Adds histories element-wise, aligned on their newest values.
    static func tailSum(_ series: [[Double]]) -> [Double] {
        let length = series.map(\.count).max() ?? 0
        var result = [Double](repeating: 0, count: length)
        for values in series {
            let offset = length - values.count
            for (index, value) in values.enumerated() { result[offset + index] += value }
        }
        return result
    }

    /// `total` minus the sum of `parts`, aligned on the newest value and never negative.
    static func remainder(of total: [Double], minus parts: [[Double]]) -> [Double] {
        let used = tailSum(parts)
        return total.enumerated().map { index, value in
            let offset = index - (total.count - used.count)
            return max(value - (offset >= 0 ? used[offset] : 0), 0)
        }
    }

    /// Average load of one core tier over time, aligned on the newest sample.
    func tierHistory(level: Int) -> [Double] {
        let histories = topology.tierForCPU.indices
            .filter { topology.tierForCPU[$0] == level && coreHistory.indices.contains($0) }
            .map { coreHistory[$0].values }
        guard !histories.isEmpty else { return [] }
        let length = histories.map(\.count).min() ?? 0
        return (0..<length).map { index in
            histories.reduce(0) { $0 + $1[$1.count - length + index] } / Double(histories.count)
        }
    }

    // MARK: - Actions

    /// Quits apps politely (like ⌘Q) and sends SIGTERM to everything else.
    func endTask(_ pids: [Int32]) {
        var signalled: [Int32] = []
        for pid in pids {
            if let app = regularApps[pid] {
                app.terminate()
            } else {
                signalled.append(pid)
            }
        }
        send(.terminate, to: signalled)
    }

    func forceQuit(_ pids: [Int32]) {
        send(.kill, to: pids)
    }

    /// Ends each process and everything it started, children first.
    func endProcessTree(_ pids: [Int32], force: Bool) {
        guard let processes = snapshot?.processes else { return }
        let children = Dictionary(grouping: processes, by: \.parentPID)
        var ordered: [Int32] = []
        func visit(_ pid: Int32) {
            for child in children[pid] ?? [] where child.pid != pid { visit(child.pid) }
            if !ordered.contains(pid) { ordered.append(pid) }
        }
        pids.forEach(visit)
        send(force ? .kill : .terminate, to: ordered)
    }

    func send(_ signal: ProcessSignal, to pids: [Int32]) {
        var denied: [Int32] = []
        for pid in pids {
            do {
                try ProcessControl.send(signal, to: pid)
            } catch .permissionDenied {
                denied.append(pid)
            } catch {
                lastError = error.localizedDescription
            }
        }
        if !denied.isEmpty {
            runAsAdministrator(ProcessControl.shellCommand(for: signal, pids: denied))
        }
        refreshSoon()
    }

    func setNice(_ value: Int32, for pid: Int32) {
        do {
            try ProcessControl.setNice(value, for: pid)
        } catch .permissionDenied {
            runAsAdministrator(ProcessControl.shellCommand(nice: value, pid: pid))
        } catch {
            lastError = error.localizedDescription
        }
        refreshSoon()
    }

    func revealInFinder(_ pid: Int32) {
        guard let process = process(pid), let path = process.bundlePath ?? process.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func searchOnline(_ pid: Int32) {
        guard let process = process(pid),
              let query = "\(process.name) macOS process".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://duckduckgo.com/?q=\(query)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Runs `/usr/bin/sample` for three seconds and opens the report.
    func sampleProcess(_ pid: Int32) {
        guard let process = process(pid) else { return }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(process.name)-\(pid)-sample.txt")
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            task.arguments = [String(pid), "3", "-file", output.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                return
            }
            if task.terminationStatus == 0 {
                await MainActor.run { _ = NSWorkspace.shared.open(output) }
            }
        }
    }

    func dismissError() {
        lastError = nil
    }

    private func refreshSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            refreshNow()
        }
    }

    private func runAsAdministrator(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = error[NSAppleScript.errorMessage] as? String ?? "The command failed."
        }
    }
}
