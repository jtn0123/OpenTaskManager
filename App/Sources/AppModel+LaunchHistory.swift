import OTMKit

extension AppModel {
    /// Uses the existing sampler's wakeups, never another timer. A page read
    /// moves the same deadline on, so leaving Startup doesn't add a read.
    func sampleLaunchHistory(processes: [ProcessSample]) {
        launchJobs.sampleHistory(recorder: recorder, enabled: !showsSensorFixture, processes: processes)
    }
}
