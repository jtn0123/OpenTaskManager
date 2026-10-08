import Foundation

extension FlightRecorder {
    /// Called for a selected lifetime or a CLI result, never while recording.
    public func processEnding(_ lifetime: ProcessLifetime, reportFolders: [URL] = ProcessDiagnosticReports.folders, limit: Int = -1)
        throws(FlightRecorderError) -> ProcessEnding {
        let end = lifetime.ended ?? lifetime.lastSeen
        let queried = limit < 0 ? -1 : limit + 1
        let actions = try events(from: max(lifetime.started, lifetime.lastSeen.addingTimeInterval(-ProcessEnding.launchMargin)),
                                 to: end, limit: queried)
        let jobs: [LaunchHistoryEvent]
        if let label = lifetime.jobLabel {
            jobs = try launchJobEvents(label: label, from: lifetime.started, to: end.addingTimeInterval(ProcessEnding.launchMargin), limit: queried)
        } else {
            jobs = []
        }
        let reports = ProcessDiagnosticReports.read(for: lifetime, in: reportFolders)
        let cut = limit < 0 ? nil : actions.count > limit || jobs.count > limit
        return ProcessEnding(lifetime: lifetime, reports: reports,
                             events: limit < 0 ? actions : Array(actions.prefix(limit)),
                             launchEvents: limit < 0 ? jobs : Array(jobs.prefix(limit)), evidenceCut: cut)
    }
}
