import Foundation
import Testing
@testable import OTMKit

struct LaunchJobFilesTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("otm-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func protectedPathsAndTraversalAreRejectedBeforeReading() {
        let home = "/Users/example"
        for path in [home + "/Documents/log", home + "/Desktop/log", home + "/Downloads/log",
                     home + "/Library/Containers/app/log", home + "/Library/Mail/log", "/Volumes/Share/log",
                     "/Library/../Users/example/Documents/log", "/System/Volumes/Data/Users/example/Documents/log",
                     "/Library/Application Support/com.apple.TCC/TCC.db", "relative.log"] {
            #expect(!LaunchJobFiles.allows(path, home: home))
            #expect(LaunchJobFiles.log(path, label: "log", home: home).status == "Not readable")
        }
        #expect(LaunchJobFiles.allows(home + "/Library/Logs/job.log", home: home))
        #expect(LaunchJobFiles.allows("/var/log/job.log", home: home))
    }

    @Test func onlyLastTwentyLinesAreReadAndEmptyMissingAndDirectoryArePlain() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("output.log")
        try Data((1...50).map { "line \($0)" }.joined(separator: "\n").appending("\n").utf8).write(to: log)
        let checked = LaunchJobFiles.log(log.path, label: "StandardOutPath")
        #expect(checked.lines == (31...50).map { "line \($0)" })
        // /tmp and /var are links into /private: both spellings read, without looping.
        let viaLink = "/tmp/" + log.path.dropFirst("/private/tmp/".count)
        #expect(LaunchJobFiles.log(viaLink, label: "StandardOutPath").lines == checked.lines)
        try Data().write(to: log)
        #expect(LaunchJobFiles.log(log.path, label: "log").lines.isEmpty)
        #expect(LaunchJobFiles.log(log.path, label: "log").status == "Readable · last 0 lines")
        #expect(LaunchJobFiles.log(folder.path, label: "log").status == "Not readable")
        #expect(LaunchJobFiles.log(folder.appendingPathComponent("missing").path, label: "log").status == "Not readable")
        #expect(LaunchJobFiles.log(nil, label: "log").status == "Not configured")
    }

    @Test func boundedTailDiscardsAnIncompleteFirstLineAndRejectsProtectedSymlinks() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("output.log")
        try Data((String(repeating: "x", count: 100_000) + "\nlast line\n").utf8).write(to: log)
        #expect(LaunchJobFiles.log(log.path, label: "log").lines == ["last line"])
        let link = folder.appendingPathComponent("protected.log")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Users/example/Documents/secret.log")
        #expect(LaunchJobFiles.log(link.path, label: "log", home: "/Users/example").status == "Not readable")
    }

    @Test func inspectorRereadsProgramAndModificationDateOnDemand() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("job.plist")
        let before: [String: Any] = ["Label": "job", "Program": "/usr/bin/true"]
        let after: [String: Any] = ["Label": "job", "Program": folder.appendingPathComponent("missing").path]
        let oldData = try PropertyListSerialization.data(fromPropertyList: before, format: .xml, options: 0)
        let newData = try PropertyListSerialization.data(fromPropertyList: after, format: .xml, options: 0)
        let original = LaunchItems.item(plist: oldData, path: path.path, scope: .userAgent)
        try newData.write(to: path)
        let current = try #require(LaunchJobFiles.currentItem(original))
        #expect(current.program == after["Program"] as? String)
        #expect(current.modified != nil)
        #expect(LaunchJobFiles.check(current).first?.status == "Not found")
    }
}
