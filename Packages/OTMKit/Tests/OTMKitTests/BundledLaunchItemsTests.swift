import Foundation
@testable import OTMKit
import Testing

struct BundledLaunchItemsTests {
    @Test func discoversOnlyTheThreeRegistrationFolders() throws {
        let fixture = try BundleFixture()
        defer { fixture.remove() }
        let read = LaunchItems.discoverBundled(in: [fixture.app, fixture.app])
        #expect(read.appCount == 1)
        #expect(read.directoryReads == 3)
        #expect(read.items.count == 5)
        let agent = try #require(read.items.first { $0.label == "org.example.agent" })
        let daemon = try #require(read.items.first { $0.label == "org.example.daemon" })
        #expect(agent.source == .bundledAgent && agent.scope == .userAgent)
        #expect(agent.program == "/opt/example/agent")
        #expect(agent.arguments == ["ignored", "--watch"])
        #expect(agent.appBundlePath == fixture.app)
        #expect(daemon.source == .bundledDaemon && daemon.scope == .daemon)
        #expect(daemon.program == fixture.app + "/Contents/MacOS/daemon")
        #expect(daemon.arguments == ["daemon", "--serve"])
        #expect(daemon.startsAutomatically && !daemon.startsAtLogin)
        #expect(read.items.first { $0.label == "unreadable" }?.isUnreadable == true)
        let helper = try #require(read.items.first { $0.label == "org.example.helper" })
        #expect(helper.source == .loginItem)
        #expect(helper.program == fixture.app + "/Contents/Library/LoginItems/Helper.app/Contents/MacOS/helper")
        #expect(helper.appBundlePath == fixture.app)
        #expect(!helper.hasPlist && helper.hasFile)
        #expect(helper.launchSummary == "Registered state unknown")
        #expect(!helper.startsAutomatically)
        #expect(LaunchItemStatus(item: helper, health: .healthy).title == "Not loaded")
        #expect(LaunchControl.restriction(for: helper) != nil)
        #expect(LaunchControl.restriction(for: agent) != nil)
        #expect(LaunchControl.restriction(for: daemon) != nil)
        let app = InstalledApp(path: fixture.app, resolvedPath: fixture.app, name: "Example", bundleIdentifier: "unrelated.owner",
                               version: nil, build: nil, minimumSystemVersion: nil, executablePath: nil, kind: .thirdParty,
                               hasAppStoreReceipt: false, isiOSApp: false, slices: nil, signature: CodeSignature(signer: .unsigned),
                               lastOpened: nil, added: nil)
        #expect(InstalledApps.launchItems(for: app, in: read.items).count == 5)
    }

    @Test func correlatesFixturesAndKeepsUnlistedHelpersUnknown() throws {
        let fixture = try BundleFixture()
        defer { fixture.remove() }
        let files = LaunchItems.discoverBundled(in: [fixture.app]).items
        let userJobs = Launchctl.parseList("""
        PID Status Label
        51 0 org.example.agent
        - 0 org.example.helper
        82 -9 org.example.fileless
        92 0 application.org.example.Editor.92
        93 0 0x123.anonymous.worker.93
        - 0 org.example.version.2
        - 0 com.apple.mdworker.shared.0D000000-0700-0000-0000-000000000000
        61 0 org.example.agent.678B4C0B-014D-4089-8003-3CF92B67E05D
        """)
        let systemJobs = Launchctl.parseServices("""
        system = {
            services = {
                101 - org.example.daemon
                0 78 org.example.fileless
            }
        }
        """)
        let reading = LaunchJobReading(time: .now, domains: ["gui/501": userJobs, "system": systemJobs])
        let inventory = LaunchItems.inventory(files, reading: reading, userOverrides: ["org.example.unlisted": true], uid: 501)
        let agent = try #require(inventory.items.first { $0.label == "org.example.agent" })
        let daemon = try #require(inventory.items.first { $0.label == "org.example.daemon" })
        #expect(agent.pid == 51 && agent.startsAtLogin)
        #expect(daemon.pid == 101)
        #expect(inventory.items.first { $0.label == "org.example.helper" }?.startsAtLogin == true)
        let unlisted = try #require(inventory.items.first { $0.label == "org.example.unlisted" })
        #expect(!unlisted.isDisabled && !unlisted.startsAtLogin)
        #expect(LaunchItemStatus(item: unlisted, health: .healthy).registration.explanation.contains("unknown"))
        #expect(!inventory.items.contains { $0.label.hasPrefix("application.") || $0.label.contains("anonymous") })
        // Apple's on-demand services without a file are macOS internals, not startup items.
        #expect(!inventory.items.contains { $0.label.hasPrefix("com.apple.") })
        // A per-connection copy of a listed job (sshd per SSH session) is a run of it, not an item.
        #expect(!inventory.items.contains { $0.label.hasPrefix("org.example.agent.") })
        #expect(!LaunchItems.isInstance("org.example.version.2", ofOneOf: ["org.example.version"]))
        let fileless = inventory.items.filter { $0.label == "org.example.fileless" }
        #expect(fileless.count == 2 && Set(fileless.map(\.id)).count == 2)
        #expect(fileless.allSatisfy { $0.source == .loadedWithoutFile && !$0.hasFile && !$0.startsAutomatically })
        #expect(fileless.allSatisfy { LaunchControl.restriction(for: $0) != nil })
        #expect(inventory.items.contains { $0.label == "org.example.version.2" })
        var watch = LaunchJobWatch()
        watch.observe(inventory.items, startTimes: [:], at: Date(timeIntervalSince1970: 100))
        #expect(fileless.contains { watch.health(of: $0).needsAttention })
        let reread = LaunchItems.inventory(inventory.items,
                                          reading: LaunchJobReading(time: .now, domains: ["gui/501": [:]]),
                                          userOverrides: [:], uid: 501)
        #expect(reread.items.contains { $0.label == "org.example.daemon" && $0.pid == 101 })
        #expect(reread.items.filter { $0.label == "org.example.fileless" }.count == 1)
        #expect(reread.items.first { $0.label == "org.example.helper" }?.startsAtLogin == false)
    }

    @Test func filelessJobsRestartWhileLoadedAndResetAfterUnloading() throws {
        let first = LaunchItems.loadedWithoutFiles([], userJobs: [
            "org.example.fileless": LaunchJobStatus(label: "org.example.fileless", pid: 51, lastExit: .code(1)),
        ], systemJobs: [:])
        var watch = LaunchJobWatch()
        watch.observe(first, startTimes: [:], at: Date(timeIntervalSince1970: 100))
        var changed = try #require(first.first)
        changed.job = LaunchJobStatus(label: changed.label, pid: 52, lastExit: .code(1))
        watch.observe([changed], startTimes: [:], at: Date(timeIntervalSince1970: 110))
        #expect(watch.record(for: changed)?.restartCount == 1)
        watch.observe([], startTimes: [:], at: Date(timeIntervalSince1970: 120))
        changed.job = LaunchJobStatus(label: changed.label, pid: 53, lastExit: nil)
        watch.observe([changed], startTimes: [:], at: Date(timeIntervalSince1970: 130))
        #expect(watch.record(for: changed)?.restartCount == 1)
    }

    @Test func refusesSystemBundlesAndLinksBeforeListingThem() throws {
        let fixture = try BundleFixture()
        defer { fixture.remove() }
        let link = fixture.root + "/Protected.app"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/System/Applications/Utilities/Terminal.app")
        let discovery = LaunchItems.discoverBundled(in: ["/System/Applications/Utilities/Terminal.app", link])
        #expect(discovery.appCount == 0 && discovery.directoryReads == 0 && discovery.items.isEmpty)
    }

    @Test func sourcesHaveStableNamesAndJSONKeepsTheExistingFields() throws {
        for source in LaunchItemSource.allCases {
            #expect(LaunchItemSource(name: source.rawValue) == source)
            #expect(LaunchItemSource(name: source.title.uppercased()) == source)
        }
        #expect(LaunchItemSource(name: "unknown") == nil)
        let item = LaunchItems.item(plist: nil, path: "/System/Library/LaunchAgents/unreadable.plist", scope: .systemAgent)
        #expect(item.source == .macOS)
        let data = try JSONEncoder().encode(item)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["source"] as? String == "macOS")
        #expect(json["plistPath"] as? String == item.plistPath)
        #expect(json["label"] as? String == item.label)
        #expect(json["scope"] as? String == "systemAgent")
    }
}

private struct BundleFixture {
    let root: String
    var app: String { root + "/Example.app" }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try write("Contents/Library/LaunchAgents/agent.plist", body: """
        <key>Label</key><string>org.example.agent</string>
        <key>Program</key><string>/opt/example/agent</string>
        <key>ProgramArguments</key><array><string>ignored</string><string>--watch</string></array>
        <key>RunAtLoad</key><true/>
        """)
        try write("Contents/Library/LaunchDaemons/daemon.plist", body: """
        <key>Label</key><string>org.example.daemon</string>
        <key>BundleProgram</key><string>Contents/MacOS/daemon</string>
        <key>ProgramArguments</key><array><string>daemon</string><string>--serve</string></array>
        <key>KeepAlive</key><true/>
        """)
        for (name, identifier) in [("Helper", "org.example.helper"), ("Unlisted", "org.example.unlisted")] {
            try write("Contents/Library/LoginItems/\(name).app/Contents/Info.plist", body: """
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleExecutable</key><string>helper</string>
            """)
        }
        // A dangling plist is unreadable regardless of the test runner's file permissions.
        try FileManager.default.createSymbolicLink(atPath: app + "/Contents/Library/LaunchAgents/unreadable.plist",
                                                   withDestinationPath: root + "/missing.plist")
        try write("Contents/Library/LaunchAgents/ignored.txt", body: "<key>Label</key><string>ignored</string>")
        try write("Contents/Other.app/Contents/Library/LaunchAgents/hidden.plist", body: "<key>Label</key><string>hidden</string>")
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    private func write(_ relative: String, body: String) throws {
        let url = URL(fileURLWithPath: app).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<plist version=\"1.0\"><dict>\(body)</dict></plist>".utf8).write(to: url)
    }
}
