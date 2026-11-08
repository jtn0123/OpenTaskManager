@testable import OTMKit
import Testing

struct ConnectionHistoryLabelsTests {
    private func connection(fd: Int32, family: Connection.Family = .ipv4) -> Connection {
        Connection(id: .init(pid: 62194, fd: fd, socket: 42), processName: "sshd-session", transport: .tcp, family: family,
                   local: Endpoint(address: "127.0.0.1", port: 22), remote: Endpoint(address: "127.0.0.1", port: 60000),
                   tcpState: .established)
    }

    @Test func identicalEndpointsKeepDescriptorsVisibleAndDistinct() {
        let first = connection(fd: 4)
        let second = connection(fd: 5)
        #expect(first.local == second.local)
        #expect(first.remote == second.remote)
        #expect(first.id != second.id)
        #expect(first.historyIdentity == "PID 62194 · fd 4 · IPv4")
        #expect(second.historyIdentity == "PID 62194 · fd 5 · IPv4")
    }

    @Test func wildcardFamiliesRemainVisibleInAShortLine() {
        #expect(connection(fd: 4, family: .ipv6).historyIdentity == "PID 62194 · fd 4 · IPv6")
        #expect(connection(fd: 4, family: .dual).historyIdentity == "PID 62194 · fd 4 · IPv4/6")
    }
}
