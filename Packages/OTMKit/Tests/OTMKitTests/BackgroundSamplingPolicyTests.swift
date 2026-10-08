import OTMKit
import Testing

struct BackgroundSamplingPolicyTests {
    @Test(arguments: [0.5, 1, 2, 5])
    func visibleWindowsKeepTheirChosenSpeed(step: Double) {
        let policy = BackgroundSamplingPolicy(visible: true, updateInterval: step, recording: true, spikes: false,
                                              restrictedDemand: true, sensorDemand: true)
        #expect(policy.interval == step)
        #expect(policy.publishesViews && policy.processFigures && policy.processDetails && policy.processGPU)
        #expect(policy.restrictedProcessesLive && policy.sensorsLive)
        #expect(!policy.recordsSpikes)
    }

    @Test(arguments: [0.5, 1, 2, 5])
    func hiddenFlightRecorderKeepsPeaksWithoutDisplayOnlyReads(step: Double) {
        let policy = BackgroundSamplingPolicy(visible: false, updateInterval: step, recording: true, spikes: false,
                                              restrictedDemand: true, sensorDemand: true)
        #expect(policy.interval == max(step, 1), "the chosen speed, never faster than once a second")
        #expect(policy.processFigures)
        #expect(!policy.publishesViews && !policy.processDetails && !policy.processGPU)
        #expect(!policy.restrictedProcessesLive && !policy.sensorsLive)
    }

    @Test(arguments: [false, true])
    func spikesNeedLiveRestrictedFiguresAndAtLeastOneSamplePerSecond(visible: Bool) {
        let policy = BackgroundSamplingPolicy(visible: visible, updateInterval: 5, recording: false, spikes: true)
        #expect(policy.interval == 1)
        #expect(policy.processFigures && policy.restrictedProcessesLive && policy.recordsSpikes)
        #expect(policy.processDetails == visible && policy.processGPU == visible)
        #expect(policy.publishesViews == visible)
    }

    @Test func fastVisibleSpikeCaptureKeepsItsFinerStep() {
        let policy = BackgroundSamplingPolicy(visible: true, updateInterval: 0.5, recording: true, spikes: true)
        #expect(policy.interval == 0.5)
    }

    @Test func withoutRecordingOrWindowsTheIconNeedsNoProcesses() {
        let policy = BackgroundSamplingPolicy(visible: false, updateInterval: 1, recording: false, spikes: false)
        #expect(!policy.processFigures && !policy.processDetails && !policy.processGPU)
    }

    @Test func everyVisibilityGateOverridesWindowDemand() {
        var visibility = SamplingVisibility()
        #expect(!visibility.isVisible(windowDemand: false))
        #expect(visibility.isVisible(windowDemand: true))
        visibility.applicationHidden = true
        #expect(!visibility.isVisible(windowDemand: true))
        visibility.applicationHidden = false
        visibility.displayAsleep = true
        #expect(!visibility.isVisible(windowDemand: true))
        visibility.screenLocked = true
        visibility.displayAsleep = false
        #expect(!visibility.isVisible(windowDemand: true), "display wake does not unlock the screen")
        visibility.screenLocked = false
        #expect(visibility.isVisible(windowDemand: true))
    }

    @Test func theMenuIconDoesNotCountAsAVisibleWindow() {
        var demand = SamplingDemand()
        demand.add(.menuBarIcon)
        let visibility = SamplingVisibility()
        #expect(!visibility.isVisible(windowDemand: demand.contains(.window)))
        demand.add(.window)
        demand.add(.window)
        demand.remove(.window)
        #expect(visibility.isVisible(windowDemand: demand.contains(.window)))
        demand.remove(.window)
        #expect(!visibility.isVisible(windowDemand: demand.contains(.window)))
    }

    @Test func retainedTicksNeverChangeTheirTimeStep() {
        #expect(BackgroundGraphPolicy.canRestore(hiddenStep: 1, visibleStep: 1))
        #expect(!BackgroundGraphPolicy.canRestore(hiddenStep: 1, visibleStep: 0.5))
        #expect(!BackgroundGraphPolicy.canRestore(hiddenStep: 1, visibleStep: 2))
        #expect(BackgroundGraphPolicy.keepsTick(interval: 1.02, step: 1))
        #expect(!BackgroundGraphPolicy.keepsTick(interval: 0, step: 1))
        #expect(!BackgroundGraphPolicy.keepsTick(interval: 600, step: 1))
        #expect(BackgroundGraphPolicy.isGap(interval: 600, step: 1))
    }
}
