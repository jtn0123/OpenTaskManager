import Darwin
import Foundation
@testable import OTMKit
import Testing

private func process(
    _ pid: Int32, uid: UInt32, user: String, cpu: Double = 0, memory: UInt64 = 0, restricted: Bool = false,
    power: Double? = nil, gpu: Double? = nil, threads: Int = 1
) -> ProcessSample {
    var sample = ProcessSample(
        pid: pid, parentPID: 1, responsiblePID: pid, uid: uid, userName: user, name: "p\(pid)", executablePath: nil,
        state: .running, nice: 0, startTime: nil, isTranslated: false, isRestricted: restricted, cpuPercent: cpu, cpuTime: 0,
        memory: memory, residentMemory: memory, threadCount: threads, diskReadRate: 0, diskWriteRate: 0, diskReadTotal: 0,
        diskWriteTotal: 0
    )
    sample.powerWatts = power
    sample.gpuFraction = gpu
    return sample
}

struct UserUsageTests {
    @Test func sumsEachUsersProcesses() throws {
        let users = UserUsageBuilder.build([
            process(10, uid: 501, user: "justin", cpu: 12.5, memory: 100, power: 1.5, gpu: 0.2, threads: 4),
            process(11, uid: 501, user: "justin", cpu: 7.5, memory: 50, power: 0.5, threads: 2),
            process(1, uid: 0, user: "root", cpu: 3, memory: 400, restricted: true),
        ])
        let justin = try #require(users.first { $0.uid == 501 })
        #expect(justin.name == "justin")
        #expect(justin.totals.processCount == 2)
        #expect(justin.totals.cpuPercent == 20)
        #expect(justin.totals.memory == 150)
        #expect(justin.totals.powerWatts == 2)
        #expect(justin.totals.gpuFraction == 0.2)
        #expect(justin.totals.threads == 6)
        #expect(!justin.totals.isRestricted)
        #expect(!justin.totals.includesResidentMemory)
    }

    @Test func hiddenPageHistoryTotalsMatchTheLiveDisplay() {
        let processes = [
            process(10, uid: 501, user: "me", cpu: 30, memory: 100, power: 2, threads: 4),
            process(11, uid: 501, user: "me", cpu: 20, memory: 200),
            process(1, uid: 0, user: "root", cpu: 10, memory: 300, restricted: true),
        ]
        let hidden = UserUsageBuilder.historyTotals(processes)
        for user in UserUsageBuilder.build(processes) {
            #expect(hidden[user.uid]?.cpuPercent == user.totals.cpuPercent)
            #expect(hidden[user.uid]?.memory == user.totals.memory)
            #expect(hidden[user.uid]?.powerWatts == nil)
            #expect(hidden[user.uid]?.threads == 0)
        }
        #expect(UserUsageBuilder.historyTotals([]).isEmpty)
    }

    @Test func restrictedUsersHaveNoPowerRatherThanZero() throws {
        let users = UserUsageBuilder.build([
            process(1, uid: 0, user: "root", cpu: 3, memory: 400, restricted: true),
            process(2, uid: 0, user: "root", cpu: 1, memory: 100, restricted: true),
            process(88, uid: 88, user: "_windowserver", cpu: 9, memory: 300, restricted: true, gpu: 0.15),
        ])
        let root = try #require(users.first { $0.uid == 0 })
        #expect(root.totals.isRestricted)
        #expect(root.totals.includesResidentMemory)
        #expect(root.totals.powerWatts == nil)
        #expect(root.totals.gpuFraction == nil)
        #expect(root.totals.memory == 500)

        // GPU time comes from the IORegistry for every process, so it can be known even when power isn't.
        let windowServer = try #require(users.first { $0.uid == 88 })
        #expect(windowServer.totals.powerWatts == nil)
        #expect(windowServer.totals.gpuFraction == 0.15)
    }

    @Test func ownProcessesWithoutPowerReadingsStayUnknown() throws {
        let users = UserUsageBuilder.build([process(10, uid: 501, user: "justin", cpu: 1)])
        #expect(try #require(users.first).totals.powerWatts == nil)
    }

    @Test(arguments: [
        (UInt32(0), true), (88, true), (499, true), (500, false), (501, false), (UInt32(bitPattern: -2), true),
    ])
    func classifiesSystemAccounts(uid: UInt32, isSystem: Bool) {
        #expect(UserUsage.isSystemAccount(uid: uid) == isSystem)
    }

    @Test func ordersSignedInUserThenPeopleThenRootThenDaemons() {
        let users = UserUsageBuilder.build([
            process(1, uid: 0, user: "root"),
            process(2, uid: 88, user: "_windowserver"),
            process(3, uid: 65, user: "_mdnsresponder"),
            process(4, uid: 1, user: "daemon"),
            process(5, uid: 502, user: "alex"),
            process(6, uid: 503, user: "zoe"),
            process(7, uid: 501, user: "justin"),
        ], consoleUID: 503)
        #expect(users.map(\.name) == ["zoe", "alex", "justin", "root", "daemon", "_mdnsresponder", "_windowserver"])
    }

    @Test func orderingIgnoresLoadSoCardsDontJump() {
        let quiet = UserUsageBuilder.build([process(1, uid: 501, user: "b", cpu: 1), process(2, uid: 502, user: "a", cpu: 1)])
        let busy = UserUsageBuilder.build([process(1, uid: 501, user: "b", cpu: 90), process(2, uid: 502, user: "a", cpu: 1)])
        #expect(quiet.map(\.uid) == busy.map(\.uid))
    }

    @Test func totalsAcrossUsers() {
        let users = UserUsageBuilder.build([
            process(1, uid: 0, user: "root", cpu: 3, memory: 400, restricted: true),
            process(88, uid: 88, user: "_windowserver", cpu: 9, memory: 300, restricted: true, gpu: 0.15),
        ])
        let total = UserUsageBuilder.total(users)
        #expect(total.processCount == 2)
        #expect(total.cpuPercent == 12)
        #expect(total.memory == 700)
        #expect(total.powerWatts == nil)
        #expect(total.gpuFraction == 0.15)
        #expect(total.isRestricted)
    }

    @Test func topProcessesByCPUThenMemory() {
        let processes = [
            process(1, uid: 501, user: "justin", cpu: 0, memory: 900),
            process(2, uid: 501, user: "justin", cpu: 25, memory: 10),
            process(3, uid: 501, user: "justin", cpu: 0, memory: 50),
            process(4, uid: 0, user: "root", cpu: 99, memory: 999, restricted: true),
            process(5, uid: 501, user: "justin", cpu: 5, memory: 10),
        ]
        #expect(UserUsageBuilder.topProcesses(of: 501, in: processes, count: 3).map(\.pid) == [2, 5, 1])
        #expect(UserUsageBuilder.topProcesses(of: 0, in: processes, count: 3).map(\.pid) == [4])
        #expect(UserUsageBuilder.topProcesses(of: 501, in: processes, count: 0).isEmpty)
    }
}

struct UserAccountTests {
    @Test(arguments: [
        ("Justin Example,,,", "Justin Example"),
        ("System Administrator", "System Administrator"),
        ("", nil),
        ("justin", nil),
        ("  Spaced Name , office", "Spaced Name"),
    ] as [(String, String?)])
    func takesFullNameFromGecos(gecos: String, expected: String?) {
        #expect(UserAccounts.fullName(fromGecos: gecos, login: "justin") == expected)
    }

    @Test(arguments: [
        ("Justin Example", "JE"), ("Ada Byron King", "AK"), ("_windowserver", "W"), ("root", "R"), ("", ""), ("li", "L"),
    ])
    func makesInitials(name: String, initials: String) {
        #expect(UserAccounts.initials(name) == initials)
    }

    @Test func describesWhereASessionIs() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(LoginSession(user: "a", line: "console", host: nil, loginTime: start, pid: 1).place == "Console")
        #expect(LoginSession(user: "a", line: "ttys003", host: nil, loginTime: start, pid: 2).place == "ttys003")
        #expect(LoginSession(user: "a", line: "ttys004", host: "10.0.0.5", loginTime: start, pid: 3).place == "ttys004 from 10.0.0.5")
    }

    @Test func loginWindowIsNotASignedInUser() {
        #expect(UserAccounts.consoleUser(name: "loginwindow", uid: 0) == nil)
        #expect(UserAccounts.consoleUser(name: "", uid: 501) == nil)
        #expect(UserAccounts.consoleUser(name: "justin", uid: 501) == ConsoleUser(name: "justin", uid: 501))
    }

    @Test func decodesFixedSizeCharacterArrays() {
        var record = utmpx()
        withUnsafeMutableBytes(of: &record.ut_line) { $0.copyBytes(from: Array("tty\0junk".utf8)) }
        #expect(UserAccounts.string(record.ut_line) == "tty")
        withUnsafeMutableBytes(of: &record.ut_user) { $0.copyBytes(from: Array("justin".utf8)) }
        #expect(UserAccounts.string(record.ut_user) == "justin")
    }

    @Test func resolvesThisUserAndRoot() throws {
        let me = try #require(UserAccounts.account(uid: getuid()))
        #expect(me.name == NSUserName())
        #expect(me.homeDirectory != nil)
        #expect(UserAccounts.account(uid: 0)?.name == "root")
    }

    @Test func readsLoginSessions() {
        for session in UserAccounts.sessions() {
            #expect(!session.user.isEmpty)
            #expect(!session.line.isEmpty)
            #expect(session.loginTime <= Date())
        }
        if let console = UserAccounts.consoleUser() {
            #expect(console.uid != 0)
            #expect(!console.name.isEmpty)
        }
    }
}
