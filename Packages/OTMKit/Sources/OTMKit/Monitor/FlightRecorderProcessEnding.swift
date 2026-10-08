import Foundation

extension FlightRecorder {
    /// Called for a selected lifetime or a CLI result, never while recording.
    public func processEnding(_ lifetime: ProcessLifetime, reportFolders: [URL] = ProcessDiagnosticReports.folders)
        throws(FlightRecorderError) -> ProcessEnding {
        let end = lifetime.ended ?? lifetime.lastSeen
        let actions = try events(from: max(lifetime.started, lifetime.lastSeen.addingTimeInterval(-ProcessEnding.launchMargin)), to: end)
        let jobs: [LaunchHistoryEvent]
        if let label = lifetime.jobLabel {
            jobs = try launchJobEvents(label: label, from: lifetime.started, to: end.addingTimeInterval(ProcessEnding.launchMargin))
        } else {
            jobs = []
        }
        let reports = ProcessDiagnosticReports.read(for: lifetime, in: reportFolders)
        return ProcessEnding(lifetime: lifetime, reports: reports, events: actions, launchEvents: jobs)
    }
}
