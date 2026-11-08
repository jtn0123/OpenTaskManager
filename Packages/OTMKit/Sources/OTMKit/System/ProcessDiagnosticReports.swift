import Foundation

/// Reads reports only for a requested lifetime. No report work belongs in sampling.
public enum ProcessDiagnosticReports {
    public static let byteLimit = 256 * 1_024

    public static var folders: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
         URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)]
    }

    public static func read(for lifetime: ProcessLifetime, in folders: [URL] = folders) -> [ProcessEnding.Evidence] {
        let end = (lifetime.ended ?? lifetime.lastSeen).addingTimeInterval(ProcessEnding.reportMargin)
        let names = Set([lifetime.name, lifetime.path.map { URL(fileURLWithPath: $0).lastPathComponent }]
            .compactMap { $0?.lowercased() }.filter { !$0.isEmpty })
        var found: [ProcessEnding.Evidence] = []
        for folder in folders {
            // One listing supplies modification times; unrelated reports are never opened.
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "ips" {
                let filename = file.deletingPathExtension().lastPathComponent.lowercased()
                let matchesName = names.contains { filename == $0 || filename.hasPrefix($0 + "-") || filename.hasPrefix($0 + "_") }
                guard matchesName || filename.hasPrefix("jetsamevent-"),
                      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate,
                      modified >= lifetime.started, modified <= end,
                      let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let data = try? handle.read(upToCount: byteLimit)
                try? handle.close()
                if let data, let evidence = parse(data, report: file, lifetime: lifetime) { found.append(evidence) }
            }
        }
        return found.sorted { $0.time < $1.time }
    }

    /// A capped prefix is enough even when the report's threads and images run on for megabytes.
    static func parse(_ data: Data, report: URL, lifetime: ProcessLifetime) -> ProcessEnding.Evidence? {
        guard let newline = data.firstIndex(of: 10), newline < 16 * 1_024,
              let header = try? JSONDecoder().decode(Header.self, from: data[..<newline]),
              let time = timestamp(header.timestamp), time >= lifetime.started,
              time <= (lifetime.ended ?? lifetime.lastSeen).addingTimeInterval(ProcessEnding.reportMargin) else { return nil }
        let fields = DiagnosticJSONFields.read(Data(data[data.index(after: newline)...]),
                                              keeping: ["pid", "procName", "procPath", "exception", "termination"],
                                              processPID: header.bugType.value == "298" ? lifetime.identity.pid : nil)
        guard let body = try? JSONDecoder().decode(Body.self, from: fields) else { return nil }
        let jetsam = body.jetsamProcess
        guard (jetsam?.pid ?? body.pid) == lifetime.identity.pid else { return nil }
        let reportPath = jetsam?.procPath ?? body.procPath
        if let path = lifetime.path, !path.isEmpty, let reportPath, !reportPath.isEmpty {
            guard reportPath == path else { return nil }
        } else {
            let name = jetsam?.procName ?? jetsam?.name ?? body.procName ?? header.appName ?? header.name
            guard name == lifetime.name else { return nil }
        }
        let kind = kind(header.bugType.value)
        var details = [body.exception?.type, body.exception?.signal, body.termination?.indicator,
                       body.termination?.reason, jetsam?.reason].compactMap { $0 }.filter { !$0.isEmpty }
        // "SIGNAL code 11" only repeats the exception's SIGSEGV; other namespaces
        // (code signing, a library's own reason) say something the rest doesn't.
        if let namespace = body.termination?.namespace, namespace != "SIGNAL" || body.exception?.signal == nil {
            let code = body.termination?.code.map { " code \($0)" } ?? ""
            details.append(namespace + code)
        }
        let summary = kind + (details.isEmpty ? "" : " · " + details.joined(separator: " · "))
        return ProcessEnding.Evidence(source: .diagnosticReport, time: time, summary: summary, report: report)
    }

    static func kind(_ type: String) -> String {
        switch type {
        case "309": "Crash report"
        case "298": "Jetsam / memory report"
        case "288", "299": "Hang / spin report"
        default: "Diagnostic report"
        }
    }

    private static func timestamp(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private struct Header: Decodable {
        let appName: String?
        let name: String?
        let bugType: ReportValue
        let timestamp: String
        enum CodingKeys: String, CodingKey { case appName = "app_name", name, bugType = "bug_type", timestamp }
    }

    private struct Body: Decodable {
        let pid: Int32?
        let jetsamProcess: JetsamProcess?
        let procName: String?
        let procPath: String?
        let exception: Exception?
        let termination: Termination?
    }

    private struct JetsamProcess: Decodable {
        let pid: Int32
        let name: String?
        let procName: String?
        let procPath: String?
        let reason: String?
    }

    private struct Exception: Decodable {
        let type: String?
        let signal: String?
    }

    private struct Termination: Decodable {
        let namespace: String?
        let code: ReportValue?
        let indicator: String?
        let reason: String?
    }
}

/// Apple's report fields may use either numbers or strings.
private struct ReportValue: Decodable, CustomStringConvertible {
    let value: String
    var description: String { value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text } else {
            value = String(try container.decode(Int64.self))
        }
    }
}
