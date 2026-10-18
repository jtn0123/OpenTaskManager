import AppKit
import OTMKit

extension AppModel {
    /// Asking every app for its activation policy, or even its PID, can wait
    /// on a LaunchServices round trip per app, more than the rest of a tick's
    /// bookkeeping, so the list is rebuilt only when NSWorkspace reports apps
    /// launching or quitting, and every 10 s for an app that changes policy.
    private func refreshRegularApps(publish: Bool = true) {
        let now = Date()
        guard runningAppsChanged || now.timeIntervalSince(regularAppsRead) >= 10 else { return }
        runningAppsChanged = false
        regularAppsRead = now
        let apps = Dictionary(
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        backgroundSampling.regularApps = apps
        if publish, apps != regularApps { regularApps = apps }
    }

    func ingest(_ snapshot: SystemSnapshot, sensors: SensorSample?, processesRead: Bool = true) {
        let visible = samplingDemand.hasVisibleWindow
        recentProcesses.update(processesRead ? snapshot.processes : nil,
                               at: .init(date: snapshot.timestamp, uptime: ProcessInfo.processInfo.systemUptime),
                               step: backgroundSampling.interval,
                               userID: includeSystemProcesses ? nil : UInt32(getuid()), publishes: visible)
        let held = fixture(or: sensors) ?? backgroundSampling.sensors
        backgroundSampling.sensors = held
        backgroundSampling.readings = SensorTable.readings(sensors: held, power: snapshot.power,
                                                          gpus: snapshot.gpus, ordered: false)
        backgroundSampling.extremes.record(backgroundSampling.readings, thermalState: snapshot.power.thermalState)
        refreshRegularApps(publish: visible)
        backgroundSampling.power.add(snapshot.power, interval: snapshot.interval)
        if let watts = snapshot.power.systemWatts { backgroundSampling.peakWatts = max(backgroundSampling.peakWatts, watts) }
        if BackgroundGraphPolicy.isGap(interval: snapshot.interval, step: max(samplingInterval, 1)) {
            backgroundSampling.points.removeAll()
            backgroundSampling.hasGap = true
            if visible { resetViewHistories() }
        }
        if visible {
            if backgroundSampling.wasHidden {
                if backgroundSampling.hasGap { resetViewHistories() } else { resetProcessViewHistories() }
                for point in backgroundSampling.points.values {
                    publish(point.snapshot, sensors: point.sensors, processes: false)
                }
                backgroundSampling.points.removeAll()
                backgroundSampling.wasHidden = false
                backgroundSampling.hasGap = false
                regularApps = backgroundSampling.regularApps
            }
            publish(snapshot, sensors: held)
            powerDetail.integral = backgroundSampling.power
            if backgroundSampling.peakWatts > peakSystemWatts {
                peakSystemWatts = backgroundSampling.peakWatts
                Settings.peakSystemWatts.set(peakSystemWatts)
            }
        } else {
            backgroundSampling.keep(snapshot, sensors: held)
        }
        record(snapshot, sensors: held)
        recordOlderTime(snapshot, sensors: held)
    }

    private func publish(_ snapshot: SystemSnapshot, sensors: SensorSample?, processes: Bool = true) {
        // The first sample has no baseline, so its rates are all zero; keep it
        // for the process list but leave it out of the graphs.
        defer { self.snapshot = snapshot }
        if let sensors = fixture(or: sensors) { self.sensors = sensors }
        // A slower sensor read holds its figure, so graphs keep one point per tick.
        if let held = self.sensors, !held.isEmpty, snapshot.interval > 0 { sensorHistory.append(held) }
        if processes { updateSensorTable(snapshot) }
        if processes { userUsage.ingest(snapshot.processes, interval: snapshot.interval, live: samplingDemand.contains(.users)) }
        guard BackgroundGraphPolicy.keepsTick(interval: snapshot.interval, step: max(samplingInterval, 1)) else { return }

        cpuHistory.append(snapshot.cpu.usage)
        cpuSystemHistory.append(snapshot.cpu.system)
        for (index, usage) in snapshot.cpu.coreUsage.enumerated() where index < coreHistory.count {
            coreHistory[index].append(usage)
        }
        for (index, system) in snapshot.cpu.coreSystem.enumerated() where index < coreSystemHistory.count {
            coreSystemHistory[index].append(system)
        }
        memoryHistory.append(snapshot.memory.usedFraction)
        memoryDetail.append(snapshot.memory)
        powerHistory.append(snapshot.power.systemWatts ?? 0)
        thermalPressureHistory.append(snapshot.power.thermalState.level)
        powerDetail.append(snapshot.power, interval: snapshot.interval, keepingEnergy: false)
        if let watts = snapshot.power.systemWatts, watts > peakSystemWatts {
            peakSystemWatts = watts
            Settings.peakSystemWatts.set(watts)
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
            diskActiveHistory[disk.id, default: History(capacity: Self.historyCapacity)].append(disk.activeFraction)
        }
        for link in snapshot.network {
            networkInHistory[link.id, default: History(capacity: Self.historyCapacity)].append(link.receivedBytesPerSecond)
            networkOutHistory[link.id, default: History(capacity: Self.historyCapacity)].append(link.sentBytesPerSecond)
        }

        guard processes else { return }
        _ = appendProcessHistories(snapshot.processes)
        appendProcessFigures(snapshot)
    }

    private func appendProcessFigures(_ snapshot: SystemSnapshot) {
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
        appGroupsUptime = snapshot.uptime
        appendGroupHistories()
    }

    /// Adds each app group's totals to its history and running total, as
    /// `appendProcessHistories` does for processes. A group whose process
    /// has quit leaves both.
    private func appendGroupHistories() {
        var previous = groupHistory
        groupHistory = [:]
        var previousTotals = groupTotals
        groupTotals = [:]
        var histories: [ProcessIdentity: History<ProcessPoint>] = [:]
        histories.reserveCapacity(appGroups.count)
        var totals: [ProcessIdentity: ProcessTotal] = [:]
        totals.reserveCapacity(appGroups.count)
        for group in appGroups {
            guard let identity = group.process?.identity else { continue }
            var history = previous.removeValue(forKey: identity) ?? History(capacity: Self.processHistoryCapacity)
            var total = previousTotals.removeValue(forKey: identity) ?? ProcessTotal()
            let point = ProcessPoint(cpuPercent: group.totals.cpuPercent, memory: group.totals.memory,
                                     gpuFraction: group.totals.gpuFraction, powerWatts: group.totals.powerWatts)
            if let dropped = history.append(point) { total.remove(dropped) }
            total.add(point)
            histories[identity] = history
            totals[identity] = total
        }
        groupHistory = histories
        groupTotals = totals
    }

    /// Adds each process's sample to its history and running total. A process
    /// that has quit leaves both. The histories are taken out of the model
    /// while they grow, so each is appended to in place, not copied whole
    /// every tick. Returns the processes new since the last tick, and the
    /// last tick's samples of those gone since.
    private func appendProcessHistories(_ samples: [ProcessSample]) -> (appeared: [ProcessSample], gone: [ProcessSample]) {
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
        var appeared: [ProcessSample] = []
        for process in samples {
            let identity = process.identity
            identities[process.pid] = identity
            // Bound only within the `if`, so `history` holds the only reference when it's appended to.
            var history: History<ProcessPoint>
            if let kept = previous.removeValue(forKey: identity) {
                history = kept
            } else {
                history = History(capacity: Self.processHistoryCapacity)
                appeared.append(process)
            }
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
        // What's left of the last tick's histories is the processes gone since; `snapshot` is still that tick's.
        var gone: [ProcessSample] = []
        if !previous.isEmpty, let last = snapshot?.processes {
            for process in last where previous[process.identity] != nil { gone.append(process) }
        }
        return (appeared, gone)
    }

    /// Whether this Mac measures energy, GPU time and Neural Engine memory per
    /// process, from the tick's walk over the processes (any reading at all),
    /// saved when it changes.
    private func noteWhatProcessesReport(_ snapshot: SystemSnapshot, anyPower: Bool, anyGPU: Bool, anyNeural: Bool) {
        guard !snapshot.processes.isEmpty else { return }
        // The rule in `ProcessSample.measuresEnergy`, without a second walk.
        if snapshot.interval > 0, anyPower != measuresProcessEnergy {
            measuresProcessEnergy = anyPower
            Settings.measuresProcessEnergy.set(anyPower)
        }
        gpuReporting.record(anyProcess: anyGPU)
        if let reported = gpuReporting.isReported, reported != reportsProcessGPU {
            reportsProcessGPU = reported
            Settings.reportsProcessGPU.set(reported)
        }
        neuralMemoryReporting.record(anyProcess: anyNeural)
        if let reported = neuralMemoryReporting.isReported, reported != reportsProcessNeuralMemory {
            reportsProcessNeuralMemory = reported
            Settings.reportsProcessNeuralMemory.set(reported)
        }
    }

    /// Records this tick's sensors, clocks and power rails in the Thermals
    /// table's ranges: a few dozen dictionary updates, so it runs every tick
    /// and the ranges cover the whole session, not just while the page shows.
    private func updateSensorTable(_ snapshot: SystemSnapshot) {
        let live = samplingDemand.contains(.sensorTable)
        let readings = fixtureReadings() ?? SensorTable.readings(sensors: sensors, power: snapshot.power,
                                                               gpus: snapshot.gpus, ordered: live)
        sensorReadings = readings
        if showsSensorFixture {
            sensorExtremes.record(readings, thermalState: snapshot.power.thermalState)
        } else {
            sensorExtremes = backgroundSampling.extremes
        }
        if live { sensorRows = sensorExtremes.rows(readings) }
    }

    /// Whether a debug build's `-sensorFixture` stands in for this Mac's
    /// sensors. Its readings were some other Mac's, so the run records
    /// nothing to History, which it still shows.
    var showsSensorFixture: Bool {
        #if DEBUG
        sensorFixture != nil
        #else
        false
        #endif
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
        backgroundSampling.extremes = sensorExtremes
    }

    /// Recording owns its baselines independently of the views, so hidden
    /// ticks never need to touch a view's process rings or groups.
    private func record(_ snapshot: SystemSnapshot, sensors: SensorSample?) {
        let state = backgroundSampling
        if snapshot.interval > 0 {
            state.iconHistory.append(snapshot.cpu.usage)
            if samplingDemand.contains(.menuBarIcon) && samplingDemand.displayIsAwake {
                menuBarIcon.update(history: state.iconHistory, usage: snapshot.cpu.usage,
                                   at: ProcessInfo.processInfo.systemUptime)
            }
            miniMonitor.add(MiniMonitorFigures(snapshot), interval: snapshot.interval, step: updateSpeed.rawValue,
                            publishes: samplingDemand.contains(.miniMonitor) && samplingDemand.displayIsAwake)
        }
        guard !showsSensorFixture, !Self.usesIncidentFixture else { return }
        let values = HistoryValues(snapshot, chipCelsius: sensors?.hottest(.chip))
        SpikeCaptureStore.shared.add(values, snapshot: snapshot, history: recorder)
        guard let recorder else { return }
        let previous = state.previousProcesses
        let identities = Set(snapshot.processes.map(\.identity))
        let appeared = snapshot.processes.filter { previous[$0.identity] == nil }
        let gone = previous.values.filter { !identities.contains($0.identity) }
        state.previousProcesses = Dictionary(snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        processTracker.watchesRestricted = includeSystemProcesses
        processTracker.add(snapshot.processes, appeared: appeared, disappeared: gone, interval: snapshot.interval, at: snapshot.timestamp)
        historyEvents?.update(snapshot.processes, apps: Set(state.regularApps.keys), at: snapshot.timestamp)
        let groups = ProcessTreeBuilder.build(snapshot.processes, mode: .grouped, appPIDs: Set(state.regularApps.keys)).flatMap(\.children)
        let apps = groups.compactMap { group in
            group.process.map { AppUsage(name: state.regularApps[$0.pid]?.localizedName ?? $0.name,
                                        cpuPercent: group.totals.cpuPercent, memory: Double(group.totals.memory)) }
        }
        let hardware = HistoryHardwareSample(readings: state.readings, cpu: snapshot.cpu, topology: topology,
                                             sensorsRead: sensors?.isEmpty == false)
        guard let record = recording.add(values, hardware: hardware, apps: apps, interval: snapshot.interval,
                                         at: snapshot.timestamp) else { return }
        let processes = processTracker.close(at: record.time, samples: snapshot.processes, labels: launchdLabels())
        Task.detached(priority: .utility) {
            try? await recorder.append(record)
            try? await recorder.append(processes)
        }
    }

}

// Histories not sampled at the display cadence restart with the existing
// unrecorded look. Only actual retained system ticks are played back.
extension AppModel {
    func samplingCadenceChanged(to interval: TimeInterval) {
        resetViewHistories()
        // Its buckets are counted in samples, so a new step starts them again.
        olderTime.removeAll()
        samplingInterval = interval
    }

    private func resetViewHistories() {
        cpuHistory.removeAll()
        cpuSystemHistory.removeAll()
        coreHistory = coreHistory.map { History(capacity: $0.capacity) }
        coreSystemHistory = coreSystemHistory.map { History(capacity: $0.capacity) }
        memoryHistory.removeAll()
        memoryDetail = MemoryHistory()
        gpuHistory = [:]
        gpuDetail = [:]
        powerHistory.removeAll()
        thermalPressureHistory.removeAll()
        powerDetail = PowerHistory()
        sensorHistory = SensorHistory()
        diskReadHistory = [:]
        diskWriteHistory = [:]
        diskActiveHistory = [:]
        networkInHistory = [:]
        networkOutHistory = [:]
        resetProcessViewHistories()
    }

    private func resetProcessViewHistories() {
        processHistory = [:]
        processTotals = [:]
        groupHistory = [:]
        groupTotals = [:]
        processGPUHistory.removeAll()
        processPowerHistory.removeAll()
        processMemoryHistory.removeAll()
        userUsage.resetHistories()
    }
}
