import Foundation
@testable import OTMKit
import Testing

/// Wraps dictionary entries in an XML property list, the way they sit on disk.
private func plist(_ body: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \(body)
    </dict>
    </plist>
    """.utf8)
}

private func item(_ body: String, path: String = "/Library/LaunchAgents/test.plist",
                  scope: LaunchItemScope = .systemAgent) -> LaunchItem {
    LaunchItems.item(plist: plist(body), path: path, scope: scope)
}

struct LaunchPlistTests {
    @Test func readsAKeepAliveDaemon() {
        let daemon = item("""
            <key>Label</key><string>wifiman-desktop</string>
            <key>ProgramArguments</key><array><string>/Library/Application Support/WiFiman/wifiman-desktopd</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>Disabled</key><false/>
            """, path: "/Library/LaunchDaemons/wifiman-desktop.plist", scope: .daemon)
        #expect(daemon.label == "wifiman-desktop")
        #expect(daemon.name == "Wifiman Desktop")
        #expect(daemon.program == "/Library/Application Support/WiFiman/wifiman-desktopd")
        #expect(daemon.arguments == ["/Library/Application Support/WiFiman/wifiman-desktopd"])
        #expect(daemon.publisher == .thirdParty)
        #expect(daemon.triggers.keepAlive == .always)
        #expect(daemon.timing == .keepAlive)
        #expect(daemon.launchSummary == "Keep alive")
        #expect(daemon.startsAutomatically)
        #expect(!daemon.isDisabled)
        #expect(daemon.state == .notLoaded)
        #expect(daemon.appBundlePath == nil)
    }

    @Test func prefersProgramOverTheFirstArgument() {
        let helper = item("""
            <key>Label</key><string>com.microsoft.OneDriveUpdaterDaemon</string>
            <key>Program</key><string>/Applications/OneDrive.app/Contents/Updater.xpc/Contents/MacOS/Updater</string>
            <key>ProgramArguments</key><array/>
            <key>MachServices</key><dict><key>com.microsoft.OneDriveUpdaterDaemon</key><true/></dict>
            """, scope: .daemon)
        #expect(helper.program == "/Applications/OneDrive.app/Contents/Updater.xpc/Contents/MacOS/Updater")
        #expect(helper.arguments.isEmpty)
        #expect(helper.appBundlePath == "/Applications/OneDrive.app")
        #expect(helper.triggers.hasOnDemandEndpoints)
        #expect(helper.timing == .onDemand)
        #expect(helper.launchSummary == "On demand")
        #expect(!helper.startsAutomatically)
        #expect(helper.triggers.details(for: .daemon) == ["On demand, when another process calls on it"])
    }

    @Test func agentsStartAtLoginAndDaemonsAtBoot() {
        let body = "<key>Label</key><string>x</string><key>RunAtLoad</key><true/>"
        #expect(item(body, scope: .userAgent).launchSummary == "At login")
        #expect(item(body, scope: .daemon).launchSummary == "At boot")
    }

    @Test func describesSchedules() {
        let daily = item("""
            <key>Label</key><string>com.user.refresh</string>
            <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>17</integer></dict>
            """)
        #expect(daily.triggers.calendar == [CalendarInterval(minute: 17, hour: 4)])
        #expect(daily.timing == .calendar)
        #expect(daily.launchSummary == "Daily at 04:17")

        let twice = item("""
            <key>Label</key><string>com.example.twice</string>
            <key>StartCalendarInterval</key><array>
              <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>3</integer><key>Minute</key><integer>15</integer></dict>
              <dict><key>Minute</key><integer>30</integer></dict>
            </array>
            """)
        #expect(twice.launchSummary == "2 schedules")
        #expect(twice.triggers.details(for: .systemAgent) == ["Sundays at 03:15", "Hourly at :30"])

        let hourly = item("<key>Label</key><string>com.google.updater.wake</string><key>StartInterval</key><integer>3600</integer>")
        #expect(hourly.timing == .interval)
        #expect(hourly.launchSummary == "Every hour")
    }

    @Test func watchedPathsAndConditionalKeepAlive() {
        let watcher = item("""
            <key>Label</key><string>com.valvesoftware.steamclean</string>
            <key>WatchPaths</key><array><string>/Users/me/Steam</string></array>
            """)
        #expect(watcher.timing == .fileChange)
        #expect(watcher.launchSummary == "On file change")
        #expect(watcher.triggers.details(for: .userAgent) == ["When this changes: /Users/me/Steam"])

        // SuccessfulExit implies RunAtLoad, so this one starts at login.
        let restarter = item("""
            <key>Label</key><string>com.example.restarter</string>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            """, scope: .userAgent)
        #expect(restarter.triggers.keepAlive == .conditional(["SuccessfulExit"]))
        #expect(restarter.timing == .atLoad)
        #expect(restarter.startsAutomatically)

        let networked = item("""
            <key>Label</key><string>com.example.net</string>
            <key>KeepAlive</key><dict><key>NetworkState</key><true/></dict>
            """)
        #expect(networked.timing == .conditional)
        #expect(!networked.startsAutomatically)
        #expect(networked.triggers.details(for: .systemAgent) == ["Kept alive depending on network state"])
    }

    @Test func plistDisabledKeyAndBinaryFormat() throws {
        let dictionary: [String: Any] = ["Label": "com.example.off", "Program": "/usr/local/bin/off", "RunAtLoad": true, "Disabled": true]
        let binary = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        let off = LaunchItems.item(plist: binary, path: "/Library/LaunchAgents/com.example.off.plist", scope: .systemAgent)
        #expect(off.label == "com.example.off")
        #expect(off.disabledInPlist)
        #expect(off.state == .disabled)
        #expect(!off.startsAutomatically)
    }

    @Test func plistWithoutALabelIsKeptButNeverLoads() {
        let empty = LaunchItems.item(plist: plist(""), path: "/Users/me/Library/LaunchAgents/com.google.keystone.agent.plist",
                                     scope: .userAgent)
        #expect(empty.isMissingLabel)
        #expect(empty.label == "com.google.keystone.agent")
        #expect(empty.name == "Google Keystone Agent")
        #expect(empty.program == nil)
        let running = LaunchJobStatus(label: "com.google.keystone.agent", pid: 9, lastExit: nil)
        let correlated = LaunchItems.correlate([empty], userJobs: [running.label: running], systemJobs: [:],
                                               userOverrides: [:], systemOverrides: [:])
        #expect(correlated[0].state == .notLoaded)
    }

    @Test func unreadablePlistIsListedByFileName() {
        let unreadable = LaunchItems.item(plist: nil, path: "/Library/LaunchDaemons/com.vendor.secret.plist", scope: .daemon)
        #expect(unreadable.isUnreadable)
        #expect(unreadable.label == "com.vendor.secret")
        #expect(unreadable.timing == .unknown)
        #expect(unreadable.launchSummary == "Unknown")

        let garbage = LaunchItems.item(plist: Data("not a plist".utf8), path: "/Library/LaunchAgents/junk.plist", scope: .systemAgent)
        #expect(garbage.isUnreadable)
    }

    @Test(arguments: [
        ("/System/Library/LaunchDaemons/com.apple.runningboardd.plist", "com.apple.runningboardd", LaunchItemPublisher.apple),
        ("/System/Library/LaunchAgents/org.cups.cups-notifier.plist", "org.cups.cups-notifier", .apple),
        ("/Library/LaunchDaemons/com.apple.installer.plist", "com.apple.installer", .apple),
        ("/Library/LaunchDaemons/com.docker.vmnetd.plist", "com.docker.vmnetd", .thirdParty),
        ("/Users/me/Library/LaunchAgents/com.applesauce.agent.plist", "com.applesauce.agent", .thirdParty),
    ])
    func classifiesPublisher(path: String, label: String, publisher: LaunchItemPublisher) {
        #expect(LaunchItems.publisher(plistPath: path, label: label) == publisher)
    }

    @Test(arguments: [
        ("com.microsoft.update.agent", "Microsoft Update Agent"),
        ("com.apple.Safari.SafeBrowsing.Service", "Safari Safe Browsing Service"),
        ("com.apple.Finder", "Finder"),
        ("homebrew.mxcl.grafana", "Grafana"),
        ("com.ollama.ollama", "Ollama"),
        ("com.google.GoogleUpdater.wake", "Google Updater Wake"),
        ("com.apple.iCloudHelper", "iCloud Helper"),
        ("com.apple.XPCService", "XPC Service"),
        ("com.wiheads.paste.mac-helper", "Wiheads Paste Mac Helper"),
        ("wifiman-desktop", "Wifiman Desktop"),
        ("com.apple", "Apple"),
        ("...", "..."),
    ])
    func prettifiesLabels(label: String, name: String) {
        #expect(LaunchItems.displayName(forLabel: label) == name)
    }

    @Test func findsTheOutermostAppBundle() {
        #expect(LaunchItems.appBundlePath(forProgram: "/Applications/OneDrive.app/Contents/SyncReporter.app/Contents/MacOS/SyncReporter")
            == "/Applications/OneDrive.app")
        #expect(LaunchItems.appBundlePath(forProgram: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
            == "/System/Library/CoreServices/Finder.app")
        #expect(LaunchItems.appBundlePath(forProgram: "/usr/libexec/logd") == nil)
        #expect(LaunchItems.appBundlePath(forProgram: "relative/Thing.app/x") == nil)
        #expect(LaunchItems.appBundlePath(forProgram: nil) == nil)
    }

    @Test(arguments: [
        (3600, "Every hour"), (7200, "Every 2 h"), (86_400, "Every day"), (172_800, "Every 2 days"),
        (900, "Every 15 min"), (60, "Every minute"), (5400, "Every 90 min"), (30, "Every 30 s"), (1, "Every second"),
        (0, "On a timer"),
    ])
    func describesIntervals(seconds: Int, text: String) {
        #expect(LaunchTriggers.every(seconds) == text)
    }

    @Test func describesCalendarIntervals() {
        #expect(CalendarInterval().description == "Every minute")
        #expect(CalendarInterval(minute: 0).description == "Hourly at :00")
        #expect(CalendarInterval(minute: 5, hour: 23).description == "Daily at 23:05")
        #expect(CalendarInterval(hour: 4).description == "Daily, each minute from 04:00 to 04:59")
        #expect(CalendarInterval(minute: 0, hour: 9, day: 1).description == "Day 1 of each month at 09:00")
        #expect(CalendarInterval(minute: 0, hour: 9, day: 15, month: 3).description == "March 15 at 09:00")
        #expect(CalendarInterval(minute: 30, hour: 2, weekday: 7).description == "Sundays at 02:30")
        #expect(CalendarInterval(minute: 10, weekday: 1).description == "Mondays, hourly at :10")
    }
}

struct LaunchctlTests {
    @Test func parsesLaunchctlList() {
        let output = """
        PID\tStatus\tLabel
        -\t0\tcom.apple.SafariHistoryServiceAgent
        62371\t-9\tcom.apple.progressd
        1412\t0\tcom.apple.Finder
        -\t78\tcom.example.crashy
        -\t0\tcom.example.with space
        -\t0\tcom.example.twice
        4242\t0\tcom.example.twice
        """
        let jobs = Launchctl.parseList(output)
        #expect(jobs.count == 6)
        #expect(jobs["com.apple.SafariHistoryServiceAgent"]?.pid == nil)
        #expect(jobs["com.apple.SafariHistoryServiceAgent"]?.lastExit == .code(0))
        #expect(jobs["com.apple.progressd"] == LaunchJobStatus(label: "com.apple.progressd", pid: 62371, lastExit: .code(-9)))
        #expect(jobs["com.example.crashy"]?.lastExit == .code(78))
        #expect(jobs["com.example.with space"] != nil)
        // The running copy wins when a label appears twice.
        #expect(jobs["com.example.twice"]?.pid == 4242)
        #expect(jobs["PID"] == nil && jobs["Label"] == nil)
    }

    @Test func parsesTheSystemDomainServices() {
        let output = """
        system = {
        \ttype = system
        \tservice stats = {
        \t\ttotal = 1
        \t}
        \tservices = {
        \t\t   51188   (pe) \tcom.apple.AppleVirtualPlatform.SystemService
        \t\t       0      - \tcom.apple.backgroundassets.managed.relay.service
        \t\t     624      - \tcom.apple.runningboardd
        \t\t       0     -9 \tcom.apple.Kerberos.digest-service
        \t\t   20090   (jt) \tcom.apple.gamepolicyd
        \t\t       0      0 \tcom.docker.vmnetd
        \t}

        \tattractive services = {
        \t\tcom.apple.MessagesBlastDoorService
        \t}

        \tdisabled services = {
        \t\t"com.apple.ftpd" => disabled
        \t\t"com.docker.socket" => enabled
        \t}
        }
        """
        let jobs = Launchctl.parseServices(output)
        #expect(jobs.count == 6)
        #expect(jobs["com.apple.AppleVirtualPlatform.SystemService"] ==
            LaunchJobStatus(label: "com.apple.AppleVirtualPlatform.SystemService", pid: 51188, lastExit: .reason("pe")))
        #expect(jobs["com.apple.backgroundassets.managed.relay.service"]?.pid == nil)
        #expect(jobs["com.apple.runningboardd"] == LaunchJobStatus(label: "com.apple.runningboardd", pid: 624, lastExit: nil))
        #expect(jobs["com.apple.Kerberos.digest-service"]?.lastExit == .code(-9))
        #expect(jobs["com.apple.gamepolicyd"]?.lastExit == .reason("jt"))
        #expect(jobs["com.apple.MessagesBlastDoorService"] == nil)

        #expect(Launchctl.parseDisabled(output) == ["com.apple.ftpd": true, "com.docker.socket": false])
    }

    @Test func parsesPrintDisabled() {
        let modern = """

        \tdisabled services = {
        \t\t"com.apple.ScriptMenuApp" => disabled
        \t\t"homebrew.mxcl.grafana" => enabled
        \t\t"com.example.odd label" => disabled
        \t}

        \tlogin item associations = {
        \t\t"com.example.helper" => enabled
        \t}
        """
        #expect(Launchctl.parseDisabled(modern) == [
            "com.apple.ScriptMenuApp": true, "homebrew.mxcl.grafana": false, "com.example.odd label": true,
        ])

        let older = """
        disabled services = {
        \t"com.apple.ftpd" => true
        \t"org.example.thing" => false
        }
        """
        #expect(Launchctl.parseDisabled(older) == ["com.apple.ftpd": true, "org.example.thing": false])
        #expect(Launchctl.parseDisabled("").isEmpty)
    }

    @Test func describesExits() {
        #expect(LaunchExitStatus.code(0).description == "Exited normally (0)")
        #expect(LaunchExitStatus.code(78).description == "Exited with code 78")
        #expect(LaunchExitStatus.code(-9).description == "Killed by signal 9 (SIGKILL)")
        #expect(LaunchExitStatus.code(-31).description == "Killed by signal 31")
        #expect(LaunchExitStatus.reason("jt").description == "Ended by the system for using too much memory")
        #expect(LaunchExitStatus.reason("zz").description == "Ended for reason \"zz\"")
        #expect(Launchctl.exitStatus("-") == nil)
        #expect(Launchctl.exitStatus("(pe)") == .reason("pe"))
    }

    @Test func correlatesEachScopeWithItsOwnDomain() {
        let agent = item("<key>Label</key><string>com.example.agent</string><key>RunAtLoad</key><true/>", scope: .userAgent)
        let daemon = item("<key>Label</key><string>com.example.daemon</string><key>KeepAlive</key><true/>", scope: .daemon)
        let idle = item("<key>Label</key><string>com.example.idle</string><key>Disabled</key><true/>", scope: .systemAgent)
        let userJobs = [
            "com.example.agent": LaunchJobStatus(label: "com.example.agent", pid: 501, lastExit: .code(0)),
            // A daemon's label in your own session doesn't make the daemon loaded.
            "com.example.daemon": LaunchJobStatus(label: "com.example.daemon", pid: 7, lastExit: nil),
            "com.example.idle": LaunchJobStatus(label: "com.example.idle", pid: nil, lastExit: .code(0)),
        ]
        let items = LaunchItems.correlate([agent, daemon, idle], userJobs: userJobs, systemJobs: [:],
                                          userOverrides: ["com.example.idle": false], systemOverrides: ["com.example.daemon": true])
        #expect(items[0].state == .running(pid: 501))
        #expect(items[0].pid == 501)
        #expect(items[1].state == .disabled)
        #expect(items[1].job == nil)
        #expect(!items[1].startsAutomatically)
        // `launchctl enable` overrides the plist's Disabled key.
        #expect(!items[2].isDisabled)
        #expect(items[2].state == .loaded)
    }

    @Test func saysWhetherALoadedJobIsRunning() {
        let agent = item("<key>Label</key><string>com.example.otm-demo</string>", scope: .userAgent)
        #expect(agent.statusSummary == "Not loaded")
        #expect(agent.stateDetail == nil)

        var idle = agent
        idle.job = LaunchJobStatus(label: "com.example.otm-demo", pid: nil, lastExit: .code(0))
        #expect(idle.statusSummary == "Loaded · Not running")

        var running = agent
        running.job = LaunchJobStatus(label: "com.example.otm-demo", pid: 12345, lastExit: nil)
        // The PID isn't grouped like a quantity.
        #expect(running.statusSummary == "Running · PID 12345")

        var disabled = agent
        disabled.disabledOverride = true
        #expect(disabled.statusSummary == "Disabled · Not loaded")
        disabled.job = idle.job
        #expect(disabled.statusSummary == "Disabled · Not running")
    }

    @Test func statesSortRunningFirst() {
        let states: [LaunchItemState] = [.notLoaded, .disabled, .running(pid: 9), .loaded, .running(pid: 2)]
        #expect(states.sorted() == [.running(pid: 2), .running(pid: 9), .loaded, .disabled, .notLoaded])
        #expect(LaunchItemPublisher.thirdParty < .apple)
        #expect(LaunchItemScope.allCases.sorted() == [.userAgent, .systemAgent, .daemon])
    }
}

/// Reads this Mac's real launchd folders, so it checks invariants only.
struct LaunchItemsLiveTests {
    @Test func scansThisMac() {
        let items = LaunchItems.scan()
        #expect(items.contains { $0.publisher == .apple && $0.scope == .daemon })
        #expect(items.contains { $0.publisher == .apple && $0.scope == .systemAgent })
        #expect(items.allSatisfy { !$0.label.isEmpty && !$0.name.isEmpty })
        #expect(items.allSatisfy { ($0.pid ?? 1) > 0 })
        #expect(Set(items.map(\.id)).count == items.count)
        if !Launchctl.userJobs().isEmpty {
            #expect(items.contains { $0.job != nil })
        }
    }
}

struct LaunchControlTests {
    private let label = "<key>Label</key><string>com.vendor.updater</string><key>Program</key><string>/opt/vendor/updater</string>"

    @Test func switchesOnlyThirdPartyAgents() {
        let agent = item(label, path: "/Library/LaunchAgents/com.vendor.updater.plist")
        let mine = item(label, path: "/Users/me/Library/LaunchAgents/com.vendor.updater.plist", scope: .userAgent)
        let daemon = item(label, path: "/Library/LaunchDaemons/com.vendor.updater.plist", scope: .daemon)
        let apple = item("<key>Label</key><string>com.apple.Safari.agent</string>",
                         path: "/System/Library/LaunchAgents/com.apple.Safari.agent.plist")
        let broken = item("", path: "/Library/LaunchAgents/com.vendor.broken.plist")
        #expect(LaunchControl.restriction(for: agent) == nil)
        #expect(LaunchControl.restriction(for: mine) == nil)
        #expect(LaunchControl.restriction(for: daemon)?.contains("administrator") == true)
        #expect(LaunchControl.restriction(for: apple)?.contains("Apple") == true)
        #expect(LaunchControl.restriction(for: broken) != nil)
    }

    @Test func disablingUnloadsAndEnablingLoadsInYourSession() {
        let agent = item(label, path: "/Library/LaunchAgents/com.vendor.updater.plist")
        #expect(LaunchControl.commands(.disable, for: agent, uid: 501)
            == [["disable", "gui/501/com.vendor.updater"], ["bootout", "gui/501/com.vendor.updater"]])
        #expect(LaunchControl.commands(.enable, for: agent, uid: 501)
            == [["enable", "gui/501/com.vendor.updater"], ["bootstrap", "gui/501", "/Library/LaunchAgents/com.vendor.updater.plist"]])
    }

    @Test func startsRestartsAndStopsTheJobInYourSession() {
        let agent = item(label, path: "/Library/LaunchAgents/com.vendor.updater.plist")
        #expect(LaunchControl.commands(.start, for: agent, uid: 501) == [["kickstart", "gui/501/com.vendor.updater"]])
        #expect(LaunchControl.commands(.restart, for: agent, uid: 501) == [["kickstart", "-k", "gui/501/com.vendor.updater"]])
        #expect(LaunchControl.commands(.stop, for: agent, uid: 501) == [["kill", "SIGTERM", "gui/501/com.vendor.updater"]])
    }

    @Test func refusesRestrictedItemsWithoutRunningLaunchctl() {
        let daemon = item(label, path: "/Library/LaunchDaemons/com.vendor.updater.plist", scope: .daemon)
        #expect(throws: LaunchControlError.self) { try LaunchControl.perform(.disable, for: daemon) }
    }
}

struct LaunchServiceTests {
    @Test func readsTheTopLevelOfLaunchctlPrint() {
        let output = """
        gui/501/com.vendor.sync = {
        \tactive count = 1
        \tpath = /Library/LaunchAgents/com.vendor.sync.plist
        \tstate = running

        \tprogram = /opt/vendor/sync
        \targuments = {
        \t\t/opt/vendor/sync
        \t}

        \tenvironment = {
        \t\tstate => not this one
        \t}

        \truns = 350
        \tpid = 4353
        \timmediate reason = ipc (socket)
        \tlast exit code = (never exited)
        \tlast exit reason = JETSAM_REASON_MEMORY_IDLE_EXIT
        \tlast terminating signal = Terminated: 15

        \tresource coalition = {
        \t\tstate = active
        \t\tpid = 1
        \t}

        \tspawn type = adaptive (6)
        \trun interval = 300 seconds
        \tproperties = runatload | inferred program | supports transactions
        }
        """
        let info = LaunchServiceInfo.parse(output)
        #expect(info.state == "running")
        #expect(info.pid == 4353)
        #expect(info.isRunning)
        #expect(info.runs == 350)
        #expect(info.startReason == "ipc (socket)")
        #expect(info.lastExitReason == "JETSAM_REASON_MEMORY_IDLE_EXIT")
        #expect(info.lastSignal == "Terminated: 15")
        #expect(info.priority == .adaptive)
        #expect(info.runInterval == 300)
        #expect(info.properties == ["runatload", "inferred program", "supports transactions"])
    }

    @Test func readsAnIdleJob() {
        let info = LaunchServiceInfo.parse("""
        gui/501/com.vendor.weather = {
        \tstate = not running
        \truns = 0
        \tspawn type = daemon (3)
        }
        """)
        #expect(info.state == "not running")
        #expect(info.pid == nil)
        #expect(!info.isRunning)
        #expect(info.runs == 0)
        #expect(info.priority == .standard)
        #expect(info.startReason == nil)
        #expect(info.properties.isEmpty)
    }

    @Test func countsRunsSinceLoginOrStartup() {
        #expect(LaunchServiceInfo.describe(runs: 0, scope: .userAgent) == "Not since login")
        #expect(LaunchServiceInfo.describe(runs: 1, scope: .systemAgent) == "Once since login")
        #expect(LaunchServiceInfo.describe(runs: 3, scope: .userAgent) == "3 times since login")
        #expect(LaunchServiceInfo.describe(runs: 12, scope: .daemon) == "12 times since startup")
    }

    @Test func describesStartReasons() {
        #expect(LaunchServiceInfo.describe(startReason: "ipc (socket)") == "A connection to its socket")
        #expect(LaunchServiceInfo.describe(startReason: "speculative").contains("runs at load"))
        #expect(LaunchServiceInfo.describe(startReason: "something new") == "something new")
    }

    @Test func describesExitReasons() {
        #expect(LaunchServiceInfo.describe(exitReason: "JETSAM_REASON_MEMORY_IDLE_EXIT") == "Quit while idle, to free memory")
        #expect(LaunchServiceInfo.describe(exitReason: "OS_REASON_CODESIGNING") == "Codesigning")
        #expect(LaunchServiceInfo.describe(exitReason: "JETSAM_REASON_SOMETHING_NEW") == "Something new")
    }

    @Test func readsALoadedJobOnThisMac() throws {
        // ssh-agent ships with macOS and is loaded in every login session.
        let info = try #require(Launchctl.service("com.openssh.ssh-agent", scope: .systemAgent))
        #expect(info.state != nil)
        #expect(Launchctl.service("com.example.not-loaded-\(UUID().uuidString)", scope: .userAgent) == nil)
    }
}
