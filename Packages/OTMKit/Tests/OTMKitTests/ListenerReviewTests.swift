import Foundation
import Testing
@testable import OTMKit

struct ListenerReviewTests {
    private let time = Date(timeIntervalSince1970: 1_000)

    private func listener(path: String = "/usr/local/bin/server", port: Int = 8_080, address: String = "127.0.0.1",
                          transport: Connection.Transport = .tcp, pid: Int32 = 7, team: String? = "TEAM",
                          signingID: String? = "example.server") -> ListenerObservation {
        let connection = Connection(id: .init(pid: pid, fd: pid, socket: UInt64(pid)), processName: "server",
                                    transport: transport, family: address.contains(":") ? .ipv6 : .ipv4,
                                    local: Endpoint(address: address, port: port), remote: nil,
                                    tcpState: transport == .tcp ? .listen : nil, processStart: Date(timeIntervalSince1970: Double(pid)))
        let executable = ListenerExecutable(path: path, teamIdentifier: team, signingIdentifier: signingID)
        let identity = ListenerIdentity(executable: executable, transport: transport, port: port, scope: ListenerBindScope(connection.local))
        return ListenerObservation(identity: identity, connection: connection)
    }

    @Test func identitySurvivesRestartsAndGroupsLoopbackAndWildcardFamilies() throws {
        let original = listener()
        #expect(original.identity == listener(address: "::1", pid: 100).identity)
        #expect(listener(address: "0.0.0.0").identity == listener(address: "::").identity)
        #expect(original.identity != listener(transport: .udp).identity)
        #expect(original.identity != listener(port: 8_081).identity)
        #expect(original.identity != listener(path: "/another/server").identity)
        #expect(original.identity != listener(team: "OTHER").identity)
        #expect(original.identity != listener(signingID: "another.identifier").identity)
        #expect(listener(address: "192.0.2.1").identity != listener(address: "192.0.2.2").identity)
        #expect(listener(address: "fe80::1%en0").identity != listener(address: "fe80::1%en1").identity)
        let encoded = try JSONEncoder().encode(original.identity)
        #expect(try JSONDecoder().decode(ListenerIdentity.self, from: encoded) == original.identity)
    }

    @Test func systemAssignedPortsShareOneIdentityPerExecutableAndNeverNameAPreviousHolder() {
        let first = listener(port: 52_344)
        #expect(first.identity.port == nil)
        #expect(first.identity == listener(port: 61_002, pid: 100).identity)
        #expect(listener(port: 49_151).identity.port == 49_151)
        #expect(first.identity != listener(port: 52_344, address: "0.0.0.0").identity)
        #expect(first.identity.portLabel(seen: 52_344) == "system-assigned port (52344 when seen)")
        #expect(listener().identity.portLabel(seen: 8_080) == "port 8080")
        let baseline: Set = [first.identity]
        #expect(ListenerChangeRules.changes([listener(port: 50_000)], baseline: baseline, at: time).isEmpty)
        let other = ListenerChangeRules.changes([listener(path: "/other/server", port: 50_000)], baseline: baseline, at: time)
        #expect(other.first?.reasons == [.newExecutable])
        #expect(other.first?.previousHolders == [])
        #expect(ListenerChangeRules.changes([listener(port: 50_000, address: "0.0.0.0")], baseline: baseline, at: time)
            .first?.reasons == [.scopeWidened])
    }

    @Test func connectedSocketsAreNotListeners() {
        let connection = Connection(id: .init(pid: 7, fd: 3, socket: 9), processName: "client", transport: .tcp, family: .ipv4,
                                    local: Endpoint(address: "127.0.0.1", port: 50_000),
                                    remote: Endpoint(address: "192.0.2.1", port: 443), tcpState: .established)
        #expect(ListenerIdentity(connection: connection, executable: .init(path: "/client")) == nil)
        #expect(ListenerIdentity(connection: listener(transport: .udp).connection, executable: .init(path: "/server")) != nil)
    }

    @Test func newExecutableNewPortAndProtocolHaveSeparateRules() {
        let baseline: Set = [listener().identity]
        let newExecutable = listener(path: "/new/server", port: 9_000)
        let newPort = listener(port: 9_001)
        let newProtocol = listener(transport: .udp)
        let changes = ListenerChangeRules.changes([newExecutable, newPort, newProtocol, newPort], baseline: baseline, at: time)
        #expect(changes.count == 3)
        #expect(changes[0].reasons == [.newExecutable])
        #expect(changes[1].reasons == [.newPort])
        #expect(changes[2].reasons == [.newPort])
        #expect(ListenerChangeRules.changes([listener(pid: 100)], baseline: baseline, at: time).isEmpty)
    }

    @Test func wideningRequiresPreviouslyLoopbackOnlyOnThatProtocolAndPort() {
        let local = listener()
        let widened = listener(address: "0.0.0.0")
        #expect(ListenerChangeRules.changes([widened], baseline: [local.identity], at: time).first?.reasons == [.scopeWidened])
        #expect(ListenerChange.Reason.scopeWidened.label == "Now listening on all interfaces")
        let specific = listener(address: "192.0.2.1")
        #expect(ListenerChangeRules.changes([widened], baseline: [local.identity, specific.identity], at: time)
            .first?.reasons == [.bindChanged])
        #expect(ListenerChangeRules.changes([specific], baseline: [local.identity], at: time).first?.reasons == [.bindChanged])
        #expect(ListenerChangeRules.changes([listener(port: 9_000, address: "::")], baseline: [local.identity], at: time)
            .first?.reasons == [.newPort])
    }

    @Test func portTakenOverNamesItsPreviousExecutableAndKeepsProtocolsSeparate() {
        let baseline = listener()
        let replacement = listener(path: "/new/server")
        let change = ListenerChangeRules.changes([replacement], baseline: [baseline.identity], at: time).first
        #expect(change?.reasons == [.newExecutable, .portOwnerChanged])
        #expect(change?.previousHolders == [baseline.identity.executable.path])
        #expect(ListenerChangeRules.changes([listener(path: "/new/server", transport: .udp)],
                                          baseline: [baseline.identity], at: time).first?.reasons == [.newExecutable])
    }

    @Test func twoConsecutiveWalksDebounceEvenAcrossProcessRestartsButNotGaps() {
        var debounce = ListenerDebounce()
        let first = listener()
        #expect(debounce.observe([first], at: time, maximumSpacing: 7).isEmpty)
        #expect(debounce.observe([listener(pid: 100)], at: time.addingTimeInterval(3), maximumSpacing: 7).count == 1)
        #expect(debounce.observe([], at: time.addingTimeInterval(6), maximumSpacing: 7).isEmpty)
        #expect(debounce.observe([first], at: time.addingTimeInterval(9), maximumSpacing: 7).isEmpty)
        #expect(debounce.observe([first], at: time.addingTimeInterval(60), maximumSpacing: 7).isEmpty)
        #expect(debounce.observe([first], at: time.addingTimeInterval(120), maximumSpacing: 121).count == 1)
        debounce.stop()
        #expect(debounce.observe([first], at: time.addingTimeInterval(123), maximumSpacing: 7).isEmpty)
        #expect(debounce.observe([first], at: time, maximumSpacing: 7).isEmpty)
    }

    @Test func initialBaselineDoesNotRaiseChangesAndAcceptanceKeepsAbsentReviewedListeners() {
        let original = listener()
        let newPort = listener(port: 9_000)
        var review = ListenerReview(baseline: ListenerBaseline(listeners: [original.identity], at: time))
        review.record([original], at: time.addingTimeInterval(3))
        #expect(review.changes.isEmpty)
        review.record([newPort], at: time.addingTimeInterval(6))
        let pending = review.changes
        review.record([newPort], at: time.addingTimeInterval(9))
        review.record([], at: time.addingTimeInterval(12))
        #expect(review.changes == pending)
        review.accept([newPort.identity], at: time.addingTimeInterval(15))
        #expect(review.baseline.listeners == [original.identity, newPort.identity])
        #expect(review.baseline.setAt == time)
        #expect(review.baseline.reviewedAt == time.addingTimeInterval(15))
        #expect(review.changes.isEmpty)
        review.record([newPort], at: time.addingTimeInterval(18))
        #expect(review.changes.isEmpty)
    }

    @Test func reviewWordsDistinguishTheInitialBaselineAndAcceptedReview() {
        var review = ListenerReview(baseline: ListenerBaseline(listeners: [listener().identity], at: time))
        #expect(ListenerReviewWords.baseline(review).hasPrefix("Baseline set at "))
        let added = listener(port: 9_000)
        review.record([added], at: time.addingTimeInterval(3))
        review.accept([added.identity], at: time.addingTimeInterval(6))
        #expect(ListenerReviewWords.baseline(review).hasPrefix("Baseline reviewed at "))
        #expect(ListenerReviewWords.baseline(review).hasSuffix("with 2 listeners"))
        #expect(ListenerReviewWords.baseline(nil) == "Baseline has not been set yet.")
        #expect(ListenerReviewWords.changeCount(1) == "1 listener change")
        #expect(ListenerReviewWords.changeCount(3) == "3 listener changes")
    }

    @Test func unreadableProcessesAndMissingPathsAreCountedWithoutInventingIdentities() {
        var reader = ListenerIdentityReader()
        let connection = listener().connection
        let snapshot = ConnectionSnapshot(connections: [connection], hiddenProcesses: 1, scannedProcesses: 2, duration: 0,
                                          unreadablePIDs: [8, 9])
        let reading = reader.read(snapshot)
        #expect(reading.listeners.isEmpty)
        #expect(reading.unreadableProcesses == 3)
        var debounce = ListenerDebounce()
        _ = debounce.observe([listener()], at: time, maximumSpacing: 7)
        _ = debounce.observe(reading.listeners, at: time.addingTimeInterval(3), maximumSpacing: 7)
        #expect(debounce.observe([listener()], at: time.addingTimeInterval(6), maximumSpacing: 7).isEmpty)
    }
}
