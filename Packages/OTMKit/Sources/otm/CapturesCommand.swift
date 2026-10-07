import Foundation
import OTMKit

/// `otm captures`: the spike captures the app has kept, newest first.
func capturesCommand(_ options: Options) {
    let library = SpikeCaptureLibrary()
    let entries = library.entries()
    if options.json {
        printJSON(entries.map(CaptureReport.init))
    } else {
        print(capturesList(entries, directory: library.directory))
    }
}

/// `otm captures --json`: a capture's file, span and incident.
struct CaptureReport: Encodable {
    struct Trigger: Encodable {
        let kind: String
        let time: Date
        let since: Date
        let figure: Double
        let threshold: Double
        let level: String?
        let baseline: Double?
        let summary: String
    }

    struct Contributor: Encodable {
        let name: String
        let pid: Int32
        let startTime: Date?
        let measure: String
        let average: Double
        let peak: Double
        let share: Double?
    }

    let path: String
    let bytes: Int64
    let start: Date
    let end: Date
    let note: String
    let kind: String?
    let incidentStart: Date?
    let incidentEnd: Date?
    let ongoing: Bool?
    let triggers: [Trigger]
    let contributors: [Contributor]

    init(_ entry: SpikeCaptureEntry) {
        path = entry.url.path
        bytes = entry.bytes
        start = entry.session.start
        end = entry.session.end
        note = entry.session.note
        let incident = entry.incident
        kind = incident?.kind.rawValue
        incidentStart = incident?.start
        incidentEnd = incident?.end
        ongoing = incident?.ongoing
        triggers = (incident?.triggers ?? []).map {
            Trigger(kind: $0.kind.rawValue, time: $0.time, since: $0.since, figure: $0.figure, threshold: $0.threshold, level: $0.level,
                    baseline: $0.baseline, summary: $0.summary)
        }
        contributors = (incident?.contributors ?? []).map {
            Contributor(name: $0.name, pid: $0.identity.pid, startTime: $0.identity.startTime, measure: $0.measure.rawValue,
                        average: $0.average, peak: $0.peak, share: $0.share)
        }
    }
}

func capturesList(_ entries: [SpikeCaptureEntry], directory: URL) -> String {
    let folder = directory.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    guard !entries.isEmpty else {
        return "No spike captures in \(folder). Turn on Capture spikes automatically in OpenTaskManager's settings "
            + "or History's Spikes list."
    }
    let time = Date.FormatStyle(date: .abbreviated, time: .standard)
    var lines = ["\(entries.count) spike \(entries.count == 1 ? "capture" : "captures") in \(folder), newest first", ""]
    for entry in entries {
        let headline = entry.incident?.headline ?? (entry.session.note.isEmpty ? "Recording" : entry.session.note)
        lines.append("\(pad(entry.session.start.formatted(time), 26))\(headline)")
        var detail = ["\(Format.roughDuration(entry.session.duration)) captured", Format.bytes(UInt64(max(entry.bytes, 0)))]
        if let incident = entry.incident, incident.triggers.count > 1 {
            detail.append("also " + incident.triggers.dropFirst().map(\.kind.label).joined(separator: ", "))
        }
        lines.append(String(repeating: " ", count: 26) + detail.joined(separator: " · "))
        for contributor in entry.incident?.contributors.prefix(3) ?? [] {
            lines.append(String(repeating: " ", count: 28) + "\(contributor.name) (PID \(contributor.identity.pid)): \(contributor.figureText)")
        }
        lines.append(String(repeating: " ", count: 26) + entry.url.lastPathComponent)
        lines.append("")
    }
    lines.removeLast()
    return lines.joined(separator: "\n")
}
