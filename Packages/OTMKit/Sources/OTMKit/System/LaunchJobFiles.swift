import Foundation

public struct LaunchJobFileCheck: Sendable, Hashable {
    public let label: String
    public let path: String?
    public let status: String
    public let lines: [String]

    public init(label: String, path: String?, status: String, lines: [String] = []) {
        self.label = label
        self.path = path
        self.status = status
        self.lines = lines
    }
}

/// An allowlist avoids even probing paths that could raise a privacy prompt.
/// Both the spelling and the resolved path must qualify, including symlinks.
public enum LaunchJobFiles {
    public static func allows(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        let roots = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/opt",
                     "/private/var/log", "/var/log", "/private/tmp", "/tmp", home + "/Library/Logs", home + "/Library/LaunchAgents",
                     home + "/Applications", home + "/bin", home + "/.local/bin"]
        let blocked = ["/System/Volumes", "/Library/Application Support/com.apple.TCC", "/Library/Containers", "/Library/Group Containers"]
        guard !blocked.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func safeURL(_ path: String, home: String) -> URL? {
        guard allows(path, home: home) else { return nil }
        var candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        // Read each link's destination without following it. Check the whole
        // substituted path before touching its target, so an allowed folder's
        // link into Documents cannot raise a privacy prompt while resolving it.
        for _ in 0..<32 {
            let parts = candidate.split(separator: "/").map(String.init)
            var prefix = ""
            var followed = false
            for (index, part) in parts.enumerated() {
                prefix += "/" + part
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix) else { continue }
                let destination = target.hasPrefix("/") ? target
                    : URL(fileURLWithPath: prefix).deletingLastPathComponent().appendingPathComponent(target).path
                let remainder = parts.dropFirst(index + 1).joined(separator: "/")
                let base = URL(fileURLWithPath: destination)
                candidate = (remainder.isEmpty ? base : base.appendingPathComponent(remainder)).standardizedFileURL.path
                guard allows(candidate, home: home) else { return nil }
                followed = true
                break
            }
            if !followed { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Reads at most 64 KiB from the end, then keeps at most 20 complete lines.
    /// Regular local files only: a FIFO, device or network mount must never wait here.
    public static func log(_ path: String?, label: String, home: String = NSHomeDirectory()) -> LaunchJobFileCheck {
        guard let path else { return LaunchJobFileCheck(label: label, path: nil, status: "Not configured") }
        guard let url = safeURL(path, home: home),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .volumeIsLocalKey]),
              values.isRegularFile == true, values.volumeIsLocal == true,
              FileManager.default.isReadableFile(atPath: url.path), let file = try? FileHandle(forReadingFrom: url) else {
            return LaunchJobFileCheck(label: label, path: path, status: "Not readable")
        }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            let offset = size > 65_536 ? size - 65_536 : 0
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: 65_536) ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if offset > 0 {
                // The first chunk may begin halfway through a line.
                text = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? ""
            }
            if text.hasSuffix("\n") { text.removeLast() }
            let lines = text.isEmpty ? [] : Array(text.components(separatedBy: "\n").suffix(20))
            return LaunchJobFileCheck(label: label, path: path, status: "Readable · last \(lines.count) lines", lines: lines)
        } catch {
            return LaunchJobFileCheck(label: label, path: path, status: "Not readable")
        }
    }

    /// Re-reads just this plist, rather than using the page's possibly older configuration.
    public static func currentItem(_ item: LaunchItem, home: String = NSHomeDirectory()) -> LaunchItem? {
        guard let url = safeURL(item.plistPath, home: home),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .volumeIsLocalKey,
                                                            .contentModificationDateKey]),
              values.isRegularFile == true, values.volumeIsLocal == true, (values.fileSize ?? Int.max) <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return LaunchItems.item(plist: data, path: item.plistPath, scope: item.scope, modified: values.contentModificationDate)
    }

    /// The plist and its program are checked only when an inspector opens or refreshes.
    public static func check(_ item: LaunchItem, home: String = NSHomeDirectory()) -> [LaunchJobFileCheck] {
        var checks: [LaunchJobFileCheck] = []
        if let program = item.program, let url = safeURL(program, home: home),
           (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            let executable = regular && FileManager.default.isExecutableFile(atPath: url.path)
            checks.append(LaunchJobFileCheck(label: "Program", path: program,
                                            status: !exists ? "Not found" : executable ? "Exists · executable" : "Exists · not executable"))
            checks.append(LaunchJobFileCheck(label: "Code signature", path: program,
                                            status: regular ? CodeSigning.validity(atPath: url.path).title : "Not readable"))
        } else {
            checks.append(LaunchJobFileCheck(label: "Program", path: item.program, status: "Not readable"))
            checks.append(LaunchJobFileCheck(label: "Code signature", path: item.program, status: "Not readable"))
        }
        var plist: [String: Any]?
        if let url = safeURL(item.plistPath, home: home),
           let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .volumeIsLocalKey]),
           values.isRegularFile == true, values.volumeIsLocal == true, (values.fileSize ?? Int.max) <= 1_048_576,
           let data = try? Data(contentsOf: url) {
            // Foundation owns the decoded property list; no format pointer is supplied.
            plist = unsafe try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }
        for key in ["StandardOutPath", "StandardErrorPath"] {
            checks.append(plist == nil ? LaunchJobFileCheck(label: key, path: nil, status: "Not readable")
                : log(plist?[key] as? String, label: key, home: home))
        }
        return checks
    }
}
