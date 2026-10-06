import AppKit
import Observation
import OTMKit

/// Per-process values kept for the inspector's mini graphs.
struct ProcessPoint: Sendable {
    let cpuPercent: Double
    let memory: UInt64
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

    /// Top of a graph of this process's CPU.
    func graphCeiling(for values: [Double]) -> Double {
        relativeToSystem ? 100 : max(100, GraphView.niceCeiling(values.max() ?? 0))
    }
}

/// Live state shared by every window: the latest snapshot plus graph history.
@Observable
@MainActor
final class AppModel {
    static let historyCapacity = 300

    let monitor = SystemMonitor()
    let topology: CPUTopology

    private(set) var snapshot: SystemSnapshot?
    private(set) var cpuHistory = History<Double>(capacity: historyCapacity)
    private(set) var coreHistory: [History<Double>]
    private(set) var memoryHistory = History<Double>(capacity: historyCapacity)
    private(set) var gpuHistory: [String: History<Double>] = [:]
    private(set) var powerHistory = History<Double>(capacity: historyCapacity)
    private(set) var diskReadHistory: [String: History<Double>] = [:]
    private(set) var diskWriteHistory: [String: History<Double>] = [:]
    private(set) var networkInHistory: [String: History<Double>] = [:]
    private(set) var networkOutHistory: [String: History<Double>] = [:]
    private(set) var processHistory: [Int32: History<ProcessPoint>] = [:]
    /// Regular (Dock) apps by PID, refreshed each tick for grouping and icons.
    private(set) var regularApps: [Int32: NSRunningApplication] = [:]
    private(set) var lastError: String?
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
        samplingTask = Task { [weak self, monitor] in
            while !Task.isCancelled {
                let snapshot = await monitor.sample()
                guard let self else { return }
                self.ingest(snapshot)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    func refreshNow() {
        Task {
            ingest(await monitor.sample())
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

    private func ingest(_ snapshot: SystemSnapshot) {
        // The first sample has no baseline, so its rates are all zero; keep it
        // for the process list but leave it out of the graphs.
        defer { self.snapshot = snapshot }
        regularApps = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard snapshot.interval > 0 else { return }

        cpuHistory.append(snapshot.cpu.usage)
        for (index, usage) in snapshot.cpu.coreUsage.enumerated() where index < coreHistory.count {
            coreHistory[index].append(usage)
        }
        memoryHistory.append(snapshot.memory.usedFraction)
        powerHistory.append(snapshot.power.systemWatts ?? 0)
        if let watts = snapshot.power.systemWatts, watts > peakSystemWatts {
            peakSystemWatts = watts
            UserDefaults.standard.set(watts, forKey: "peakSystemWatts")
        }
        for gpu in snapshot.gpus {
            gpuHistory[gpu.id, default: History(capacity: Self.historyCapacity)].append(gpu.deviceUtilization)
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
        for process in snapshot.processes {
            var history = processHistory[process.pid] ?? History(capacity: 120)
            history.append(ProcessPoint(cpuPercent: process.cpuPercent, memory: process.memory))
            processes[process.pid] = history
        }
        processHistory = processes
    }

    // MARK: - Queries

    func process(_ pid: Int32) -> ProcessSample? {
        snapshot?.processes.first { $0.pid == pid }
    }

    func displayName(for process: ProcessSample) -> String {
        regularApps[process.pid]?.localizedName ?? process.name
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
