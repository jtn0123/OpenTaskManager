import AppKit
import Observation
import OTMKit

/// Per-process values kept for the inspector's graphs and the "by app" charts.
/// There's one per process per sample across a whole graph window, so they're
/// held as `Float`, half the size of `Double`, which no graph can tell apart:
/// a window of 300 costs about what 120 did before.
struct ProcessPoint: Sendable {
    private let cpu: Float
    private let footprint: Float
    private let gpu: Float
    private let power: Float

    init(cpuPercent: Double, memory: UInt64, gpuFraction: Double, powerWatts: Double) {
        cpu = Float(cpuPercent)
        footprint = Float(memory)
        gpu = Float(gpuFraction)
        power = Float(powerWatts)
    }

    /// 100 = one core, as `ProcessSample.cpuPercent`.
    var cpuPercent: Double { Double(cpu) }
    /// Bytes, as `ProcessSample.memory`.
    var memory: UInt64 { UInt64(max(footprint, 0)) }
    var gpuFraction: Double { Double(gpu) }
    var powerWatts: Double { Double(power) }

    subscript(figure: ProcessFigure) -> Double {
        switch figure {
        case .cpu: Double(cpu)
        case .memory: Double(footprint)
        case .gpu: Double(gpu)
        case .power: Double(power)
        }
    }
}

/// A figure a process's history keeps, to rank and graph apps by.
enum ProcessFigure {
    /// Activity Monitor-style percent: 100 = one core.
    case cpu
    /// Footprint in bytes.
    case memory
    /// Share of the GPU's time.
    case gpu
    /// Watts.
    case power
}

/// A process's figures added up over its history, kept as samples come and
/// go, so ranking apps over the window reads one total per process instead
/// of walking every history every tick.
struct ProcessTotal: Sendable {
    private var cpu = RunningSum()
    private var memory = RunningSum()
    private var gpu = RunningSum()
    private var power = RunningSum()

    subscript(figure: ProcessFigure) -> Double {
        switch figure {
        case .cpu: cpu.value
        case .memory: memory.value
        case .gpu: gpu.value
        case .power: power.value
        }
    }

    /// Counts `point` in as its history takes it.
    mutating func add(_ point: ProcessPoint) {
        cpu.add(point[.cpu])
        memory.add(point[.memory])
        gpu.add(point[.gpu])
        power.add(point[.power])
    }

    /// Takes `point` out as its history drops it.
    mutating func remove(_ point: ProcessPoint) {
        cpu.remove(point[.cpu])
        memory.remove(point[.memory])
        gpu.remove(point[.gpu])
        power.remove(point[.power])
    }
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

/// Temperatures and fan speeds over time.
struct SensorHistory {
    private(set) var hottest: [SensorKind: History<Double>] = [:]
    private(set) var chipAverage = History<Double>(capacity: AppModel.historyCapacity)
    private(set) var fans: [Int: History<Double>] = [:]

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
    /// Each process's history, behind the "by app" graphs: as long as the
    /// graphs above them on a Performance page, so both cover the same minutes.
    nonisolated static let processHistoryCapacity = historyCapacity
    /// Samples across Overview's small graphs, which share it so they cover
    /// the same minutes.
    nonisolated static let shortGraphSpan = 120
    /// The Users page shows a minute or so per user, so keep it short.
    nonisolated static let userHistoryCapacity = 62

    let monitor = SystemMonitor()
    let sensorMonitor = SensorMonitor()
    /// The on-disk history behind the History page. Nil if it can't be opened.
    let recorder = try? FlightRecorder(url: FlightRecorder.defaultURL)
    /// Network traffic by app, read with nettop only while a view shows it.
    let networkActivity = NetworkActivityStore()
    /// Restarts of launchd's jobs, counted from the Startup page's reads.
    let launchJobs = LaunchJobStore()
    private var recording = HistoryAccumulator(span: FlightRecorder.span)
    /// Saves what happened beside the history: apps launched and quit, busy
    /// processes, network changes, sleep and wake.
    @ObservationIgnored private lazy var historyEvents = recorder.map { HistoryEventMonitor(recorder: $0) }
    let topology: CPUTopology

    private(set) var snapshot: SystemSnapshot?
    /// Temperatures and fans, read alongside each snapshot. Empty in a VM.
    private(set) var sensors: SensorSample?
    private(set) var sensorHistory = SensorHistory()
    /// The Thermals table: every sensor, clock and power rail, rebuilt each
    /// tick from what the samplers read (`SensorTable` in OTMKit).
    private(set) var sensorRows: [SensorReading] = []
    /// Each row's lowest and highest since launch or the last Reset.
    private(set) var sensorExtremes = SensorExtremes(since: Date())
    /// This tick's readings without the rows kept for channels that stopped
    /// reporting, so Reset can start the ranges from them.
    @ObservationIgnored private var sensorReadings: [SensorReading] = []
    #if DEBUG
    /// `-sensorFixture <file>`: a report from `otm sensors --extremes N --json`
    /// shown in place of this Mac's sensors, for screenshots in a VM that has none.
    @ObservationIgnored private let sensorFixture = SensorFixture.load()
    #endif
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
    /// By PID and start time, so a PID macOS gives to a later process starts
    /// a graph of its own rather than carrying on the ended one's.
    private(set) var processHistory: [ProcessIdentity: History<ProcessPoint>] = [:]
    /// Each process's history added up, kept with `processHistory`, which
    /// is what views observe.
    @ObservationIgnored private var processTotals: [ProcessIdentity: ProcessTotal] = [:]
    /// The latest tick's processes by PID, for pages that know only a PID
    /// (launchd's, on Startup).
    private(set) var processIdentityByPID: [Int32: ProcessIdentity] = [:]
    /// Each user's processes summed, for the Users page.
    private(set) var users: [UserUsage] = []
    private(set) var userHistory: [UInt32: UserHistory] = [:]
    /// Directory lookups by uid, including misses, so each runs once.
    @ObservationIgnored private var accounts: [UInt32: UserAccount?] = [:]
    /// Regular (Dock) apps by PID, for grouping and icons.
    private(set) var regularApps: [Int32: NSRunningApplication] = [:]
    /// The running apps `regularApps` was last built from, and when.
    @ObservationIgnored private var runningAppPIDs: [Int32] = []
    @ObservationIgnored private var regularAppsRead = Date.distantPast
    private(set) var lastError: String?
    /// A process another page asked the Processes page to select, such as
    /// the owner of a socket on the Connections page. Cleared once shown.
    var requestedProcess: Int32?
    /// A search the Apps page asked the Startup page to run ("Show in
    /// Startup" for an app's launch items). Cleared once applied.
    var requestedStartupSearch: String?
    /// A network interface ("en0") another page asked Performance to open
    /// ("Show traffic" on the System page). Cleared once shown.
    var requestedNetworkInterface: String?
    /// A filter another page asked the Connections page to show ("Show
    /// exposed sockets" on the System page's Firewall card). Cleared once applied.
    var requestedConnectionFilter: ConnectionFilter?
    /// Highest whole-system draw seen on this Mac, kept across launches.
    private(set) var peakSystemWatts = UserDefaults.standard.double(forKey: "peakSystemWatts")
    /// `SystemSnapshot.measuresProcessEnergy`, read off the tick's walk over
    /// the processes and written only when it changes. Kept across launches,
    /// so a Mac without power sensors (a VM) hides its power figures from the
    /// first frame rather than a second later. nil until a sample has told.
    private(set) var measuresProcessEnergy = UserDefaults.standard.object(forKey: "measuresProcessEnergy") as? Bool
    /// Whether this Mac attributes GPU time to processes (`ProcessFigureReporting`),
    /// kept across launches and written only when it changes, like
    /// `measuresProcessEnergy`. nil until the samples have told.
    private(set) var reportsProcessGPU = UserDefaults.standard.object(forKey: "reportsProcessGPU") as? Bool
    @ObservationIgnored private var gpuReporting = ProcessFigureReporting(
        isReported: UserDefaults.standard.object(forKey: "reportsProcessGPU") as? Bool
    )
    /// Whether any process has held Neural Engine memory, kept like `reportsProcessGPU`.
    private(set) var reportsProcessNeuralMemory = UserDefaults.standard.object(forKey: "reportsProcessNeuralMemory") as? Bool
    @ObservationIgnored private var neuralMemoryReporting = ProcessFigureReporting(
        isReported: UserDefaults.standard.object(forKey: "reportsProcessNeuralMemory") as? Bool
    )

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

    /// Asking every app for its activation policy costs more than the rest
    /// of a tick's bookkeeping, so the list is rebuilt when apps launch or
    /// quit, and every 10 s for an app that changes policy.
    private func refreshRegularApps() {
        let running = NSWorkspace.shared.runningApplications
        let pids = running.map(\.processIdentifier)
        let now = Date()
        guard pids != runningAppPIDs || now.timeIntervalSince(regularAppsRead) >= 10 else { return }
        runningAppPIDs = pids
        regularAppsRead = now
        let apps = Dictionary(
            running.filter { $0.activationPolicy == .regular }.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if apps != regularApps { regularApps = apps }
    }

    private func ingest(_ snapshot: SystemSnapshot, sensors: SensorSample?) {
        // The first sample has no baseline, so its rates are all zero; keep it
        // for the process list but leave it out of the graphs.
        defer { self.snapshot = snapshot }
        if let sensors = fixture(or: sensors), !sensors.isEmpty {
            self.sensors = sensors
            if snapshot.interval > 0 { sensorHistory.append(sensors) }
        }
        updateSensorTable(snapshot)
        refreshRegularApps()
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

        appendProcessHistories(snapshot.processes)
        var totalGPU = 0.0
        var totalPower = 0.0
        var totalMemory = 0.0
        var anyPower = false
        var anyGPU = false
        var anyNeural = false
        for process in snapshot.processes {
            totalGPU += process.gpuFraction ?? 0
            totalPower += process.powerWatts ?? 0
            totalMemory += Double(process.memory)
            if process.powerWatts != nil { anyPower = true }
            if process.gpuTime != nil { anyGPU = true }
            if process.hasHeldNeuralMemory { anyNeural = true }
        }
        noteWhatProcessesReport(snapshot, anyPower: anyPower, anyGPU: anyGPU, anyNeural: anyNeural)
        processGPUHistory.append(totalGPU)
        processPowerHistory.append(totalPower)
        processMemoryHistory.append(totalMemory)
        appGroups = ProcessTreeBuilder.build(snapshot.processes, mode: .grouped, appPIDs: Set(regularApps.keys))
            .flatMap(\.children)
        record(snapshot, sensorsRead: fixture(or: sensors)?.isEmpty == false)
    }

    /// Adds each process's sample to its history and running total. A process
    /// that has quit leaves both. The histories are taken out of the model
    /// while they grow, so each is appended to in place, not copied whole
    /// every tick.
    private func appendProcessHistories(_ samples: [ProcessSample]) {
        var previous = processHistory
        processHistory = [:]
        var previousTotals = processTotals
        processTotals = [:]
        var histories: [ProcessIdentity: History<ProcessPoint>] = [:]
        histories.reserveCapacity(samples.count)
        var totals: [ProcessIdentity: ProcessTotal] = [:]
        totals.reserveCapacity(samples.count)
        var identities: [Int32: ProcessIdentity] = [:]
        identities.reserveCapacity(samples.count)
        for process in samples {
            let identity = process.identity
            identities[process.pid] = identity
            var history = previous.removeValue(forKey: identity) ?? History(capacity: Self.processHistoryCapacity)
            var total = previousTotals.removeValue(forKey: identity) ?? ProcessTotal()
            let point = ProcessPoint(cpuPercent: process.cpuPercent, memory: process.memory,
                                     gpuFraction: process.gpuFraction ?? 0, powerWatts: process.powerWatts ?? 0)
            if let dropped = history.append(point) { total.remove(dropped) }
            total.add(point)
            histories[identity] = history
            totals[identity] = total
        }
        processHistory = histories
        processTotals = totals
        processIdentityByPID = identities
    }

    /// Whether this Mac measures energy, GPU time and Neural Engine memory per
    /// process, from the tick's walk over the processes (any reading at all),
    /// saved when it changes.
    private func noteWhatProcessesReport(_ snapshot: SystemSnapshot, anyPower: Bool, anyGPU: Bool, anyNeural: Bool) {
        guard !snapshot.processes.isEmpty else { return }
        // The rule in `ProcessSample.measuresEnergy`, without a second walk.
        if snapshot.interval > 0, anyPower != measuresProcessEnergy {
            measuresProcessEnergy = anyPower
            UserDefaults.standard.set(anyPower, forKey: "measuresProcessEnergy")
        }
        gpuReporting.record(anyProcess: anyGPU)
        if let reported = gpuReporting.isReported, reported != reportsProcessGPU {
            reportsProcessGPU = reported
            UserDefaults.standard.set(reported, forKey: "reportsProcessGPU")
        }
        neuralMemoryReporting.record(anyProcess: anyNeural)
        if let reported = neuralMemoryReporting.isReported, reported != reportsProcessNeuralMemory {
            reportsProcessNeuralMemory = reported
            UserDefaults.standard.set(reported, forKey: "reportsProcessNeuralMemory")
        }
    }

    /// Records this tick's sensors, clocks and power rails in the Thermals
    /// table's ranges: a few dozen dictionary updates, so it runs every tick
    /// and the ranges cover the whole session, not just while the page shows.
    private func updateSensorTable(_ snapshot: SystemSnapshot) {
        let readings = fixtureReadings() ?? SensorTable.readings(sensors: sensors, power: snapshot.power, gpus: snapshot.gpus)
        sensorReadings = readings
        sensorExtremes.record(readings, thermalState: snapshot.power.thermalState)
        sensorRows = sensorExtremes.rows(readings)
    }

    /// The sensors to show: this Mac's, or in a debug build the fixture's.
    private func fixture(or sensors: SensorSample?) -> SensorSample? {
        #if DEBUG
        if let sensorFixture { return sensorFixture.sensors }
        #endif
        return sensors
    }

    /// In a debug build with a fixture, its rows, with its ranges seeded into the table's.
    private func fixtureReadings() -> [SensorReading]? {
        #if DEBUG
        if let sensorFixture { return sensorFixture.readings(seeding: &sensorExtremes) }
        #endif
        return nil
    }

    /// Starts the Thermals table's lowest and highest again from the latest readings.
    func resetSensorExtremes() {
        sensorExtremes.reset(at: Date())
        sensorExtremes.record(sensorReadings, thermalState: snapshot?.power.thermalState)
        sensorRows = sensorExtremes.rows(sensorReadings)
    }

    /// Feeds the flight recorder, which writes a record every few seconds.
    /// `sensorsRead` is false when this tick didn't read the temperature
    /// sensors and fans, so their last readings aren't recorded again.
    private func record(_ snapshot: SystemSnapshot, sensorsRead: Bool) {
        guard let recorder else { return }
        // The apps NSWorkspace reports launching and quitting; background agents are left to the tracker.
        historyEvents?.update(snapshot.processes, apps: Set(regularApps.keys), at: snapshot.timestamp)
        let apps = appGroups.compactMap { group in
            group.process.map { AppUsage(name: displayName(for: $0), cpuPercent: group.totals.cpuPercent, memory: Double(group.totals.memory)) }
        }
        let values = HistoryValues(snapshot, chipCelsius: sensors?.hottest(.chip))
        // Core loads, clocks, fans, temperatures and power rails, picked from the Thermals table's rows.
        let hardware = HistoryHardwareSample(readings: sensorReadings, cpu: snapshot.cpu, topology: topology, sensorsRead: sensorsRead)
        guard let record = recording.add(values, hardware: hardware, apps: apps, interval: snapshot.interval,
                                         at: snapshot.timestamp) else { return }
        Task.detached(priority: .utility) {
            try? await recorder.append(record)
        }
    }

    // MARK: - Queries

    func process(_ pid: Int32) -> ProcessSample? {
        snapshot?.processes.first { $0.pid == pid }
    }

    /// The latest figures of the process running now with this PID.
    func latestProcessPoint(pid: Int32) -> ProcessPoint? {
        processIdentityByPID[pid].flatMap { processHistory[$0]?.last }
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

    /// The `count` apps that used the most of `figure` over the histories'
    /// window, each with its history summed over the app's processes and
    /// multiplied by `scale`. Apps are ranked on the running totals, and
    /// only those that make the cut have their series built.
    func topApps(by figure: ProcessFigure, scale: Double = 1, count: Int) -> [AppSeries] {
        func members(_ group: ProcessNode) -> [ProcessIdentity] {
            var members: [ProcessIdentity] = []
            func collect(_ node: ProcessNode) {
                if let process = node.process { members.append(process.identity) }
                node.children.forEach(collect)
            }
            collect(group)
            return members
        }
        var ranked: [(score: Double, group: ProcessNode)] = []
        for group in appGroups where group.process != nil {
            let score = members(group).reduce(0) { $0 + (processTotals[$1]?[figure] ?? 0) }
            // Exactly zero for an app idle across the window (see RunningSum).
            if score > 0 { ranked.append((score, group)) }
        }
        return ranked.sorted { $0.score > $1.score }.prefix(count).compactMap { entry in
            guard let process = entry.group.process else { return nil }
            let values = Self.tailSum(members(entry.group).compactMap { processHistory[$0]?.values.map { $0[figure] * scale } })
            return AppSeries(id: entry.group.id, name: displayName(for: process),
                             icon: IconCache.icon(for: process, app: regularApps[process.pid]), values: values)
        }
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

    /// Runs `/usr/bin/sample` for three seconds and opens the report. The
    /// task ends once the report is open or the run failed, so a button can
    /// say it's sampling until then.
    @discardableResult func sampleProcess(_ pid: Int32) -> Task<Void, Never>? {
        guard let process = process(pid) else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(process.name)-\(pid)-sample.txt")
        return Task.detached {
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
