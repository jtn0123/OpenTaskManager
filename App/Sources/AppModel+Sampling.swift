import Foundation
import OTMKit

extension AppModel {
    func visibilityChanged() {
        SpikeCaptureStore.shared.setVisible(samplingDemand.hasVisibleWindow)
        if !samplingDemand.hasVisibleWindow { ConnectionStore.shared.stopUnlessBackground() }
        // Cancellation interrupts the wait, so showing a window takes a
        // fresh sample immediately instead of waiting for an idle deadline.
        stop()
        start()
    }

    func start() {
        guard samplingTask == nil, !isPaused else { return }
        samplingTask = Task { [weak self, monitor, sensorMonitor] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                let demand = samplingDemand
                let policy = BackgroundSamplingPolicy(
                    visible: demand.hasVisibleWindow, updateInterval: updateSpeed.rawValue,
                    recording: recorder != nil, spikes: SpikeCaptureStore.shared.needsSamples,
                    restrictedDemand: demand.contains(.restrictedProcesses), sensorDemand: demand.contains(.sensors)
                )
                // The step the hidden points were kept at, before this tick's.
                let hiddenStep = backgroundSampling.interval
                backgroundSampling.interval = policy.interval
                if policy.publishesViews, samplingInterval != policy.interval { samplingCadenceChanged(to: policy.interval) }
                // Hidden graph points can only be reused at their real step.
                // A different display step starts with the unrecorded look.
                if policy.publishesViews, backgroundSampling.wasHidden,
                   !BackgroundGraphPolicy.canRestore(hiddenStep: hiddenStep, visibleStep: policy.interval) {
                    backgroundSampling.points.removeAll()
                    backgroundSampling.hasGap = true
                }
                async let readings = sensorMonitor.sample(live: policy.sensorsLive)
                let snapshot = await monitor.sample(restrictedProcessesLive: policy.restrictedProcessesLive,
                                                    processFigures: policy.processFigures, processDetails: policy.processDetails,
                                                    processGPU: policy.processGPU)
                let sensors = await readings
                guard !Task.isCancelled else { return }
                ingest(snapshot, sensors: sensors)
                sampleLaunchHistory(processes: snapshot.processes)
                sampleConnectionHistory(processes: snapshot.processes)
                deadline = max(deadline.advanced(by: .seconds(policy.interval)), clock.now)
                try? await Task.sleep(until: deadline, clock: clock)
            }
        }
    }
}
