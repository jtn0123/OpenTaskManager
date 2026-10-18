import AppKit
import Observation
import OTMKit

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
    let samplingDemand = SamplingDemandStore()
    @ObservationIgnored let backgroundSampling = BackgroundSamplingState()
    let menuBarIcon = MenuBarIconStore()
    /// The on-disk history behind the History page. Nil if it can't be opened.
    let recorder = AppModel.makeIncidentRecorder()
    /// Network traffic by app, read with nettop only while a view shows it.
    let networkActivity = NetworkActivityStore()
    /// Restarts of launchd's jobs, counted from the Startup page's reads.
    let launchJobs = LaunchJobStore()
    var recording = HistoryAccumulator(span: FlightRecorder.span)
    /// Each process's figures over each record, from the counters the sampler
    /// already read, for History's process history.
    @ObservationIgnored var processTracker = ProcessHistoryTracker()
    /// launchd's label for each process it runs, gathered once per read of its
    /// list on the Startup page (`launchJobs`), and that read's time.
    @ObservationIgnored private var jobLabels: (read: Date?, labels: [ProcessIdentity: String]) = (nil, [:])
    /// Saves what happened beside the history: apps launched and quit, busy
    /// processes, network changes, sleep and wake.
    @ObservationIgnored lazy var historyEvents = recorder.map { HistoryEventMonitor(recorder: $0) }
    let topology: CPUTopology

    var snapshot: SystemSnapshot?
    /// The uptime of the sample `appGroups` were built from, unobserved: for
    /// a view their change redraws that must tell one sample from the next
    /// (`TopAppsCard`). Reading `snapshot` there as well drew it about twice
    /// a tick.
    @ObservationIgnored var appGroupsUptime: TimeInterval?
    /// Temperatures and fans, read alongside each snapshot. Empty in a VM.
    var sensors: SensorSample?
    var sensorHistory = SensorHistory()
    /// The Thermals table: rows published only while the detail is on screen.
    /// Readings and ranges still cover the session and feed History.
    var sensorRows: [SensorReading] = []
    /// Each row's lowest and highest since launch or the last Reset.
    var sensorExtremes = SensorExtremes(since: Date())
    /// This tick's readings without the rows kept for channels that stopped
    /// reporting, so Reset can start the ranges from them.
    @ObservationIgnored var sensorReadings: [SensorReading] = []
    #if DEBUG
    /// `-sensorFixture <file>`: a report from `otm sensors --extremes N --json`
    /// shown in place of this Mac's sensors, for screenshots in a VM that has none.
    @ObservationIgnored let sensorFixture = SensorFixture.load()
    #endif
    var cpuHistory = History<Double>(capacity: historyCapacity)
    /// The kernel's share of the whole CPU (`CPUSample.system`), for the
    /// Overview's CPU graph under the total and the CPU page's line in its busy time.
    var cpuSystemHistory = History<Double>(capacity: historyCapacity)
    var coreHistory: [History<Double>]
    /// Each logical CPU's kernel share, indexed as `coreHistory`.
    var coreSystemHistory: [History<Double>]
    var memoryHistory = History<Double>(capacity: historyCapacity)
    var memoryDetail = MemoryHistory()
    var gpuDetail: [String: GPUHistory] = [:]
    /// Sum over every process each tick, so "by app" graphs can show the rest as "Other".
    var processGPUHistory = History<Double>(capacity: processHistoryCapacity)
    var processPowerHistory = History<Double>(capacity: processHistoryCapacity)
    var processMemoryHistory = History<Double>(capacity: processHistoryCapacity)
    /// Apps with their helpers folded in (Safari includes its web content processes).
    var appGroups: [ProcessNode] = []
    var gpuHistory: [String: History<Double>] = [:]
    var powerHistory = History<Double>(capacity: historyCapacity)
    /// macOS's thermal pressure as `ThermalState.level`, for a Mac with no
    /// temperatures to graph.
    var thermalPressureHistory = History<Double>(capacity: historyCapacity)
    var powerDetail = PowerHistory()
    var diskReadHistory: [String: History<Double>] = [:]
    var diskWriteHistory: [String: History<Double>] = [:]
    /// Each disk's share of the time it was busy, 0 to 1.
    var diskActiveHistory: [String: History<Double>] = [:]
    var networkInHistory: [String: History<Double>] = [:]
    var networkOutHistory: [String: History<Double>] = [:]
    /// By PID and start time, so a PID macOS gives to a later process starts
    /// a graph of its own rather than carrying on the ended one's.
    var processHistory: [ProcessIdentity: History<ProcessPoint>] = [:]
    /// Each process's history added up, kept with `processHistory`, which
    /// is what views observe.
    @ObservationIgnored var processTotals: [ProcessIdentity: ProcessTotal] = [:]
    /// Each app group's figures as the group stood each tick, by the group's
    /// own process, for the "by app" graphs. A helper that quits leaves its
    /// part of the past in place, and a graph reads one ring per app rather
    /// than adding up every member's.
    @ObservationIgnored var groupHistory: [ProcessIdentity: History<ProcessPoint>] = [:]
    @ObservationIgnored var groupTotals: [ProcessIdentity: ProcessTotal] = [:]
    /// The latest tick's processes by PID, for pages that know only a PID
    /// (launchd's, on Startup).
    var processIdentityByPID: [Int32: ProcessIdentity] = [:]
    /// Each user's processes summed, for the Users page.
    let userUsage = UserUsageStore(historyCapacity: AppModel.userHistoryCapacity)
    var users: [UserUsage] { userUsage.users }
    var userHistory: [UInt32: UserHistory] { userUsage.histories }
    /// Directory lookups by uid, including misses, so each runs once.
    @ObservationIgnored private var accounts: [UInt32: UserAccount?] = [:]
    /// Regular (Dock) apps by PID, for grouping and icons.
    var regularApps: [Int32: NSRunningApplication] = [:]
    /// Set when NSWorkspace reports an app launching or quitting, so
    /// `regularApps` is rebuilt on the next tick; and when it last was.
    @ObservationIgnored var runningAppsChanged = true
    @ObservationIgnored private var runningAppsObservation: NSKeyValueObservation?
    @ObservationIgnored var regularAppsRead = Date.distantPast
    private(set) var lastError: String?
    /// A process another page asked the Processes page to select, such as
    /// the owner of a socket on the Connections page. Cleared once shown.
    var requestedProcess: Int32?
    /// A search the Apps page asked the Startup page to run ("Show in
    /// Startup" for an app's launch items). Cleared once applied.
    var requestedStartupSearch: String?
    /// One of those items to select there, by ID (its property list's
    /// path), from the app's details. Cleared once shown.
    var requestedStartupItem: String?
    /// A network interface ("en0") another page asked Performance to open
    /// ("Show traffic" on the System page). Cleared once shown.
    var requestedNetworkInterface: String?
    /// A filter another page asked the Connections page to show ("Show
    /// exposed sockets" on the System page's Firewall card). Cleared once applied.
    var requestedConnectionFilter: ConnectionFilter?
    /// Highest whole-system draw seen on this Mac, kept across launches.
    var peakSystemWatts = Settings.peakSystemWatts.get()
    /// `SystemSnapshot.measuresProcessEnergy`, read off the tick's walk over
    /// the processes and written only when it changes. Kept across launches,
    /// so a Mac without power sensors (a VM) hides its power figures from the
    /// first frame rather than a second later. nil until a sample has told.
    var measuresProcessEnergy = Settings.measuresProcessEnergy.get()
    /// Whether this Mac attributes GPU time to processes (`ProcessFigureReporting`),
    /// kept across launches and written only when it changes, like
    /// `measuresProcessEnergy`. nil until the samples have told.
    var reportsProcessGPU = Settings.reportsProcessGPU.get()
    @ObservationIgnored var gpuReporting = ProcessFigureReporting(
        isReported: Settings.reportsProcessGPU.get()
    )
    /// Whether any process has held Neural Engine memory, kept like `reportsProcessGPU`.
    var reportsProcessNeuralMemory = Settings.reportsProcessNeuralMemory.get()
    @ObservationIgnored var neuralMemoryReporting = ProcessFigureReporting(
        isReported: Settings.reportsProcessNeuralMemory.get()
    )

    var isPaused = false {
        didSet { isPaused ? stop() : start() }
    }

    var updateSpeed: UpdateSpeed {
        didSet {
            Settings.updateSpeed.set(updateSpeed)
            restart()
        }
    }

    var includeSystemProcesses: Bool {
        didSet {
            Settings.includeSystemProcesses.set(includeSystemProcesses)
            applyMonitorOptions()
        }
    }

    var cpuRelativeToSystem: Bool {
        didSet { Settings.cpuRelativeToSystem.set(cpuRelativeToSystem) }
    }

    /// Squeeze older time (`Settings.squeezesOlderTime`): Performance's main
    /// graphs keep their window at the right and squeeze older time to its
    /// left. Its figures are kept only while it's on.
    var squeezesOlderTime: Bool {
        didSet {
            Settings.squeezesOlderTime.set(squeezesOlderTime)
            if !squeezesOlderTime { olderTime.removeAll() }
        }
    }

    /// The main graphs' older time, in buckets, while `squeezesOlderTime` is on.
    @ObservationIgnored var olderTime = LongHistories<OlderSeries>(span: AppModel.graphSpan)

    var cpuScale: CPUScale {
        CPUScale(relativeToSystem: cpuRelativeToSystem, logicalCores: topology.logicalCores)
    }

    @ObservationIgnored var samplingTask: Task<Void, Never>?
    /// The actual visible graph step, capped at one second for spike captures.
    var samplingInterval = 1.0

    init() {
        topology = monitor.topology
        let cores = (0..<monitor.topology.logicalCores).map { _ in History<Double>(capacity: Self.historyCapacity) }
        coreHistory = cores
        coreSystemHistory = cores
        updateSpeed = Settings.updateSpeed.get()
        includeSystemProcesses = Settings.includeSystemProcesses.get()
        cpuRelativeToSystem = Settings.cpuRelativeToSystem.get()
        squeezesOlderTime = Settings.squeezesOlderTime.get()
        applyMonitorOptions()
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.runningAppsChanged = true }
        }
        samplingDemand.visibilityChanged = { [weak self] in self?.visibilityChanged() }
        SpikeCaptureStore.shared.samplingChanged = { [weak self] in self?.visibilityChanged() }
        BenchmarkContextFeed.attach(self)
        start()
    }

    // MARK: - Sampling

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

    // MARK: - Queries

    func process(_ pid: Int32) -> ProcessSample? {
        snapshot?.processes.first { $0.pid == pid }
    }

    /// The latest figures of the process running now with this PID.
    func latestProcessPoint(pid: Int32) -> ProcessPoint? {
        processIdentityByPID[pid].flatMap { processHistory[$0]?.last }
    }

    /// The app group `root` heads, as the group stood each tick (see
    /// `groupHistory`), for the process inspector's Group tab.
    func appGroupHistory(_ root: ProcessIdentity) -> History<ProcessPoint>? {
        groupHistory[root]
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
    /// window, each with its history as the app's processes added up each
    /// tick, multiplied by `scale`. Apps are ranked on the running totals,
    /// and only those that make the cut have their series built.
    func topApps(by figure: ProcessFigure, scale: Double = 1, count: Int) -> [AppSeries] {
        var ranked: [(score: Double, group: ProcessNode)] = []
        for group in appGroups {
            guard let identity = group.process?.identity else { continue }
            let score = groupTotals[identity]?[figure] ?? 0
            // Exactly zero for an app idle across the window (see RunningSum).
            if score > 0 { ranked.append((score, group)) }
        }
        return ranked.sorted { $0.score > $1.score }.prefix(count).compactMap { entry in
            guard let process = entry.group.process, let history = groupHistory[process.identity] else { return nil }
            var values = [Double](repeating: 0, count: history.count)
            history.addValues(to: &values) { $0[figure] * scale }
            return AppSeries(id: entry.group.id, name: displayName(for: process),
                             icon: IconCache.icon(for: process, app: regularApps[process.pid]), values: values)
        }
    }

    // MARK: - Actions

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

    func reportError(_ error: any Error) { lastError = error.localizedDescription }

    func dismissError() {
        lastError = nil
    }

    func refreshSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            refreshNow()
        }
    }

    @discardableResult
    func runAsAdministrator(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        guard let script else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = error[NSAppleScript.errorMessage] as? String ?? "The command failed."
        }
        return error == nil
    }
}

extension AppModel {
    /// launchd's label for each process it was running at the Startup page's
    /// latest read of its list, gathered again only after another read.
    func launchdLabels() -> [ProcessIdentity: String] {
        let watch = launchJobs.watch
        guard watch.lastRead != jobLabels.read else { return jobLabels.labels }
        var labels: [ProcessIdentity: String] = [:]
        for (key, record) in watch.records {
            guard let instance = record.instance else { continue }
            labels[ProcessIdentity(pid: instance.pid, startTime: instance.started)] = key.label
        }
        jobLabels = (watch.lastRead, labels)
        return labels
    }
}

extension AppModel {
    /// Average load of one core tier over time, aligned on the newest sample;
    /// with `kernel`, the part of it spent in the kernel.
    func tierHistory(level: Int, kernel: Bool = false) -> [Double] {
        let source = kernel ? coreSystemHistory : coreHistory
        let histories = topology.tierForCPU.indices
            .filter { topology.tierForCPU[$0] == level && source.indices.contains($0) }
            .map { source[$0].values }
        guard !histories.isEmpty else { return [] }
        let length = histories.map(\.count).min() ?? 0
        return (0..<length).map { index in
            histories.reduce(0) { $0 + $1[$1.count - length + index] } / Double(histories.count)
        }
    }
}
