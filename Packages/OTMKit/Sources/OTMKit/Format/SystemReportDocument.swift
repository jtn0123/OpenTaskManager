import Foundation

/// Everything the System page shows, as of one moment: what its Save Report
/// writes and `otm system report` prints, as Markdown or as versioned JSON.
/// Serial numbers, the hardware UUID, and MAC, Bluetooth and IP addresses
/// stay out unless `includeIdentifiers` is set, since a report gets shared.
public struct SystemReportDocument: Sendable {
    /// Marks the JSON as a system report, whatever the file's name.
    public static let format = "io.github.jtn0123.OpenTaskManager.system-report"
    /// The JSON's version. Raised when a field changes meaning or goes away;
    /// adding fields doesn't raise it.
    public static let schemaVersion = 1

    public var info: SystemInfo
    public var displays: [DisplayInfo]
    /// nil while the device report is still being read.
    public var devices: PeripheralInventory?
    /// When `system_profiler` ran: the page keeps its last run until Refresh.
    public var devicesCollectedAt: Date?
    /// nil while it's still being checked.
    public var security: SecurityStatus?
    public var collectedAt: Date
    /// What wrote it: "OpenTaskManager 0.1.0", "otm 0.1.0".
    public var generator: String

    public init(info: SystemInfo, displays: [DisplayInfo], devices: PeripheralInventory?, devicesCollectedAt: Date?,
                security: SecurityStatus?, collectedAt: Date = Date(), generator: String) {
        self.info = info
        self.displays = displays
        self.devices = devices
        self.devicesCollectedAt = devicesCollectedAt
        self.security = security
        self.collectedAt = collectedAt
        self.generator = generator
    }

    /// The JSON report: pretty-printed with sorted keys, times in ISO 8601.
    /// Every field is always there; a fact this Mac didn't report, or an
    /// identifier left out, is `null`.
    public func json(includeIdentifiers: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(SystemReportJSON(self, includeIdentifiers: includeIdentifiers))
    }

    /// The page as Markdown: the Mac's summary, then a heading for each card
    /// with its rows as a list. A device's facts nest under it, and a USB
    /// device under the hub it's plugged into.
    public func markdown(includeIdentifiers: Bool) -> String {
        let hardware = info.hardware
        var lines = [
            "# " + Self.escaped(hardware.displayName),
            "",
            Self.escaped(SystemReport.summaryLine(info)),
            "",
            "- Collected: " + Self.escaped(collectedAt.formatted(date: .long, time: .complete)),
            "- Written by: " + Self.escaped(generator),
        ]
        if includeIdentifiers {
            lines += SystemReport.identifiers(hardware).map { "- \(Self.escaped($0.label)): " + Self.value($0) }
        } else {
            lines.append("- Left out: serial numbers, the hardware UUID, and MAC, Bluetooth and IP addresses")
        }
        let sections = SystemReport.sections(info, displays: displays, devices: devices, security: security, now: collectedAt)
        for section in sections {
            let rows = section.rows.filter { includeIdentifiers || !($0.isSensitive || $0.isAddress) }
            guard !rows.isEmpty else { continue }
            lines += ["", "## " + Self.escaped(section.title), ""]
            // A device's facts are flagged; elsewhere everything after a heading belongs to it.
            let nestsDetailsOnly = section.hasDetails
            var indent = ""
            for row in rows {
                if row.isHeading {
                    let pad = String(repeating: "  ", count: row.depth)
                    let note = row.headingNote
                    lines.append(pad + "- **" + Self.escaped(row.label) + "**" + (note.isEmpty ? "" : " (" + Self.escaped(note) + ")"))
                    indent = pad + "  "
                } else {
                    let nested = nestsDetailsOnly ? row.isDetail : !indent.isEmpty
                    lines.append((nested ? indent : "") + "- " + Self.escaped(row.label) + ": " + Self.value(row))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A row's value on one line: several addresses become a list, and
    /// addresses and identifiers are code.
    private static func value(_ row: InfoRow) -> String {
        let parts = row.value.split(separator: "\n").map(String.init)
        guard row.isCode else { return escaped(parts.joined(separator: ", ")) }
        return parts.map { $0.contains("`") ? escaped($0) : "`\($0)`" }.joined(separator: ", ")
    }

    /// Backslashes the characters Markdown would read as formatting. An
    /// underscore inside a word ("RELEASE_ARM64") is left alone: it can't
    /// start emphasis there, and the file stays readable as plain text.
    static func escaped(_ text: String) -> String {
        let characters = Array(text)
        func isWordCharacter(_ index: Int) -> Bool {
            characters.indices.contains(index) && (characters[index].isLetter || characters[index].isNumber)
        }
        var result = ""
        for (index, character) in characters.enumerated() {
            if character == "_" {
                if !(isWordCharacter(index - 1) && isWordCharacter(index + 1)) { result.append("\\") }
            } else if "\\`*[]<>|".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
