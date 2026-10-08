import Foundation

extension AppModel {
    func start() {
        guard samplingTask == nil, !isPaused else { return }
        let interval = updateSpeed.rawValue
        samplingTask = Task { [weak self, monitor, sensorMonitor] in
            // Keep a steady cadence so the graphs scroll at an even speed.
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let demand = self?.samplingDemand else { return }
                let liveSensors = demand.contains(.sensors)
                let liveProcesses = demand.contains(.restrictedProcesses)
                // The sensors answer slowly, so their occasional read still
                // runs alongside the system sample rather than after it.
                async let readings = sensorMonitor.sample(live: liveSensors)
                let snapshot = await monitor.sample(restrictedProcessesLive: liveProcesses)
                let sensors = await readings
                guard let self, !Task.isCancelled else { return }
                ingest(snapshot, sensors: sensors)
                deadline = max(deadline.advanced(by: .seconds(interval)), clock.now)
                try? await Task.sleep(until: deadline, clock: clock)
            }
        }
    }
}
