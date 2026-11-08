import Foundation
@testable import OTMKit
import Testing

struct PrivilegedSocketReadTests {
    /// lsof's fields for four processes: root's launchd, a service account's,
    /// the user's own and one whose UID has no login name.
    private static let fields = """
    p1
    claunchd
    u0
    Lroot
    f12
    tIPv4
    PTCP
    n*:22
    TST=LISTEN
    TQR=0
    TQS=0
    f13
    tIPv6
    PUDP
    n*:*
    p321
    cmDNSResponder
    u65
    L_mdnsresponder
    f40
    tIPv6
    PUDP
    n[fe80::1%en0]:5353
    f41
    tIPv4
    PTCP
    n192.168.1.5:50123->17.253.1.2:443
    TST=ESTABLISHED
    f42
    tIPv4
    PTCP
    n10.0.0.2:5000->10.0.0.3:6000
    TST=SYN_RCVD
    f43
    tIPv4
    PICMP
    n*:*
    p900
    cSafari
    u501
    Ljustin
    f9
    tIPv6
    PTCP
    n[::1]:631
    TST=LISTEN
    p901
    cnologin
    u502
    f4
    tIPv4
    PUDP
    n127.0.0.1:5000
    """

    private let read = PrivilegedSocketRead(lsofFields: fields, readAt: Date(timeIntervalSince1970: 0))

    @Test func readsEachProcessesSocketsWithItsAccount() {
        #expect(read.rows.map(\.connection.pid) == [1, 1, 321, 321, 321, 900, 901])
        #expect(read.rows.map(\.user) == ["root", "root", "_mdnsresponder", "_mdnsresponder", "_mdnsresponder", "justin", "502"])
        #expect(Set(read.rows.map(\.id)).count == read.rows.count)
        #expect(read.rows(notRunningAs: "justin").count == 6)

        let listener = read.rows[0].connection
        #expect(listener.processName == "launchd")
        #expect(listener.id.fd == 12)
        #expect(listener.local.formatted == "*:22")
        #expect(listener.kind == .listening)
        #expect(listener.isExposed)
    }

    @Test func readsAddressesStatesAndFamilies() {
        let unbound = read.rows[1].connection
        #expect(unbound.family == .ipv6)
        #expect(unbound.local.address == "::")
        #expect(unbound.local.port == nil)
        #expect(unbound.kind == .udpBound)

        #expect(read.rows[2].connection.local.address == "fe80::1%en0")
        #expect(read.rows[2].connection.local.port == 5353)
        #expect(read.rows[2].connection.tcpState == nil)

        let outgoing = read.rows[3].connection
        #expect(outgoing.remote?.formatted == "17.253.1.2:443")
        #expect(outgoing.kind == .established)
        #expect(outgoing.scope == .internet)

        #expect(read.rows[4].connection.tcpState == .synReceived)
        #expect(read.rows[5].connection.local.scope == .loopback)
        #expect(!read.rows[5].connection.isExposed)
    }

    @Test func countsAsThePageDoes() {
        let summary = ConnectionSummary(read.rows.map(\.connection))
        #expect(summary.processesWithSockets == 4)
        #expect(summary.listeningPorts == 4)
        #expect(summary.exposedPorts == 2)
        #expect(summary.exposedOnAllInterfaces == 1)
        #expect(summary.openConnections == 2)
    }

    @Test func leavesOutWhatItCannotRead() {
        #expect(PrivilegedSocketRead.endpoint("garbage", family: .ipv4) == nil)
        #expect(PrivilegedSocketRead.endpoint("[::1]631", family: .ipv6) == nil)
        #expect(PrivilegedSocketRead.endpoint("host:abc", family: .ipv4) == nil)
        #expect(PrivilegedSocketRead.endpoint(":80", family: .ipv4) == nil)
        #expect(PrivilegedSocketRead(lsofFields: "f3\ntIPv4\nPTCP\nn*:80\n", readAt: .now).rows.isEmpty)
        // Windows-style endings, should AppleScript keep any returns.
        #expect(PrivilegedSocketRead(lsofFields: "p7\r\ncx\r\nLroot\r\nf3\r\ntIPv4\r\nPUDP\r\nn*:53\r\n", readAt: .now).rows.count == 1)
    }

    @Test func outcomesFromOsascript() {
        guard case let .read(read) = PrivilegedSocketReader.outcome(status: 0, output: Self.fields, readAt: .now) else {
            Issue.record("A finished read should be read")
            return
        }
        #expect(read.rows.count == 7)
        guard case .cancelled = PrivilegedSocketReader.outcome(
            status: 1, output: "0:149: execution error: User canceled. (-128)\n", readAt: .now) else {
            Issue.record("A cancelled prompt should be cancelled")
            return
        }
        guard case let .failed(message) = PrivilegedSocketReader.outcome(
            status: 1, output: "0:149: execution error: lsof: no permission (1)\n", readAt: .now) else {
            Issue.record("Other errors should fail")
            return
        }
        #expect(message == "lsof: no permission")
    }

    @Test func thePromptIsQuotedForAppleScript() {
        let script = PrivilegedSocketReader.script(prompt: #"Read "every" socket\"#)
        #expect(script == #"do shell script "/usr/sbin/lsof -w -n -P +c 0 -i -F pcuLftPnT" with prompt "Read \"every\" socket\\" "#
            + "with administrator privileges without altering line endings")
    }
}
