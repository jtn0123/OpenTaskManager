import Darwin
import Foundation
@testable import OTMKit
import Testing

struct AddressScopeTests {
    @Test(arguments: ["127.0.0.1", "127.8.9.10", "::1", "::ffff:127.0.0.1"])
    func loopback(address: String) {
        #expect(AddressScope(address: address) == .loopback)
    }

    @Test(arguments: [
        "10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.20", // RFC 1918
        "169.254.10.1", "fe80::1", "fe80::1c2b:3aff:fe4d:5e6f%en0", // link-local
        "fd12:3456:789a::1", "fc00::1", // unique local
        "224.0.0.251", "239.255.255.250", "ff02::fb", "255.255.255.255", // multicast and broadcast
        "::ffff:192.168.1.5",
    ])
    func localNetwork(address: String) {
        #expect(AddressScope(address: address) == .localNetwork)
    }

    @Test(arguments: [
        "8.8.8.8", "17.57.146.20", "172.15.0.1", "172.32.0.1", "192.169.0.1", "11.0.0.1",
        "2606:4700:4700::1111", "fe00::1", "::ffff:8.8.8.8", "not an address", "",
    ])
    func internet(address: String) {
        #expect(AddressScope(address: address) == .internet)
    }

    @Test(arguments: ["0.0.0.0", "::"])
    func wildcard(address: String) {
        #expect(AddressScope(address: address) == .allInterfaces)
        #expect(Endpoint(address: address, port: 80).isWildcard)
    }
}

struct EndpointFormatTests {
    @Test(arguments: [
        ("127.0.0.1", 3000, "127.0.0.1:3000"),
        ("::1", 443, "[::1]:443"),
        ("2606:4700:4700::1111", 853, "[2606:4700:4700::1111]:853"),
        ("fe80::1%en0", 5353, "[fe80::1%en0]:5353"),
        ("0.0.0.0", 22, "*:22"),
        ("::", 5353, "*:5353"),
        ("10.0.0.1", 0, "10.0.0.1"),
    ])
    func formats(address: String, port: Int, expected: String) {
        #expect(Endpoint(address: address, port: port).formatted == expected)
    }

    @Test func missingPartsBecomeWildcards() {
        #expect(Endpoint.format(address: nil, port: nil) == "*")
        #expect(Endpoint.format(address: nil, port: 8080) == "*:8080")
        #expect(Endpoint.format(address: "", port: 53) == "*:53")
        #expect(Endpoint(address: "192.168.1.2", port: 0).port == nil)
    }

    @Test func describesInspectorSockets() {
        let wildcard = SocketInfo(proto: .tcp, localAddress: "0.0.0.0", localPort: 8080,
                                  remoteAddress: nil, remotePort: nil, state: "LISTEN")
        #expect(ProcessInspector.describe(wildcard) == "TCP *:8080 (LISTEN)")
        let unix = SocketInfo(proto: .unix, localAddress: "/var/run/x.sock", localPort: nil,
                              remoteAddress: nil, remotePort: nil, state: nil)
        #expect(ProcessInspector.describe(unix) == "UNIX /var/run/x.sock")
    }
}

struct TCPStateTests {
    @Test func followsKernelNumbering() {
        let expected: [(Int32, TCPState)] = [
            (TSI_S_CLOSED, .closed), (TSI_S_LISTEN, .listen), (TSI_S_SYN_SENT, .synSent),
            (TSI_S_SYN_RECEIVED, .synReceived), (TSI_S_ESTABLISHED, .established), (TSI_S__CLOSE_WAIT, .closeWait),
            (TSI_S_FIN_WAIT_1, .finWait1), (TSI_S_CLOSING, .closing), (TSI_S_LAST_ACK, .lastAck),
            (TSI_S_FIN_WAIT_2, .finWait2), (TSI_S_TIME_WAIT, .timeWait),
        ]
        for (value, state) in expected {
            #expect(TCPState(kernelValue: value) == state)
        }
        #expect(TCPState(kernelValue: TSI_S_RESERVED) == nil)
        #expect(TCPState(kernelValue: -1) == nil)
        #expect(TCPState.listen.rawValue == "LISTEN")
        #expect(TCPState.timeWait.label == "Time wait")
    }

    @Test(arguments: [
        (TCPState.listen, ConnectionKind.listening),
        (.established, .established),
        (.synSent, .connecting),
        (.synReceived, .connecting),
        (.closeWait, .closing),
        (.finWait1, .closing),
        (.finWait2, .closing),
        (.lastAck, .closing),
        (.timeWait, .closing),
        (.closed, .closed),
    ])
    func classifiesTCP(state: TCPState, kind: ConnectionKind) {
        #expect(ConnectionKind(transport: .tcp, state: state, hasRemote: state != .listen) == kind)
    }

    @Test func classifiesUDP() {
        #expect(ConnectionKind(transport: .udp, state: nil, hasRemote: false) == .udpBound)
        #expect(ConnectionKind(transport: .udp, state: nil, hasRemote: true) == .udpConnected)
        #expect(ConnectionKind(transport: .tcp, state: nil, hasRemote: false) == .closed)
        #expect(ConnectionKind.listening.acceptsInbound)
        #expect(ConnectionKind.udpBound.acceptsInbound)
        #expect(!ConnectionKind.established.acceptsInbound)
        #expect(!ConnectionKind.udpConnected.acceptsInbound)
    }
}

struct ConnectionTests {
    /// A fixture connection; the local port doubles as its descriptor.
    static func make(_ transport: Connection.Transport = .tcp, pid: Int32 = 100, local: (String, Int),
                     remote: (String, Int)? = nil, state: TCPState? = nil, name: String = "test") -> Connection {
        Connection(
            id: Connection.SocketID(pid: pid, fd: Int32(local.1), socket: UInt64(local.1)),
            processName: name, transport: transport, family: local.0.contains(":") ? .ipv6 : .ipv4,
            local: Endpoint(address: local.0, port: local.1),
            remote: remote.map { Endpoint(address: $0.0, port: $0.1) },
            tcpState: transport == .tcp ? state : nil
        )
    }

    @Test func wildcardListenersAreExposed() {
        let any4 = Self.make(local: ("0.0.0.0", 8080), state: .listen)
        let any6 = Self.make(local: ("::", 8080), state: .listen)
        let lan = Self.make(local: ("192.168.1.10", 8080), state: .listen)
        let loopback = Self.make(local: ("127.0.0.1", 8080), state: .listen)
        let loopback6 = Self.make(local: ("::1", 8080), state: .listen)
        #expect(any4.isExposed && any6.isExposed && lan.isExposed)
        #expect(!loopback.isExposed && !loopback6.isExposed)
        #expect(any4.scope == .allInterfaces)
        #expect(lan.scope == .localNetwork)
        #expect(loopback.scope == .loopback)
    }

    @Test func boundUDPIsExposedUnlessLoopback() {
        #expect(Self.make(.udp, local: ("0.0.0.0", 5353)).isExposed)
        #expect(!Self.make(.udp, local: ("127.0.0.1", 5353)).isExposed)
        let connected = Self.make(.udp, local: ("0.0.0.0", 60000), remote: ("8.8.8.8", 53))
        #expect(connected.kind == .udpConnected)
        #expect(!connected.isExposed)
        #expect(connected.stateLabel == "Connected")
        #expect(Self.make(.udp, local: ("0.0.0.0", 5353)).stateLabel == "Bound")
    }

    @Test func connectionScopeFollowsTheRemoteEnd() {
        let web = Self.make(local: ("192.168.1.10", 52100), remote: ("17.57.146.20", 443), state: .established)
        #expect(web.scope == .internet)
        #expect(!web.isExposed)
        #expect(web.stateLabel == "Established")
        let nas = Self.make(local: ("192.168.1.10", 52101), remote: ("192.168.1.196", 445), state: .established)
        #expect(nas.scope == .localNetwork)
        let local = Self.make(local: ("127.0.0.1", 52102), remote: ("127.0.0.1", 3000), state: .established)
        #expect(local.scope == .loopback)
    }

    @Test func namesWellKnownServices() {
        #expect(WellKnownPorts.name(for: 443, transport: .tcp) == "HTTPS")
        #expect(WellKnownPorts.name(for: 443, transport: .udp) == "QUIC (HTTPS)")
        #expect(WellKnownPorts.name(for: 22, transport: .tcp) == "SSH")
        #expect(WellKnownPorts.name(for: 5353, transport: .udp) == "Bonjour (mDNS)")
        #expect(WellKnownPorts.name(for: 54321, transport: .tcp) == nil)

        let outgoing = Self.make(local: ("192.168.1.10", 22), remote: ("17.57.146.20", 443), state: .established)
        #expect(outgoing.service?.name == "HTTPS", "the remote port names an outgoing connection's service")
        let inbound = Self.make(local: ("192.168.1.10", 22), remote: ("192.168.1.30", 61000), state: .established)
        #expect(inbound.service?.name == "SSH")
        #expect(inbound.service?.port == 22)
        #expect(Self.make(local: ("127.0.0.1", 49999), state: .listen).service == nil)
    }

    @Test func filters() {
        let listener = Self.make(local: ("127.0.0.1", 3000), state: .listen)
        let exposed = Self.make(local: ("::", 22), state: .listen)
        let established = Self.make(local: ("10.0.0.2", 50000), remote: ("1.1.1.1", 443), state: .established)
        let udp = Self.make(.udp, local: ("0.0.0.0", 5353))
        let all = [listener, exposed, established, udp]
        func matching(_ filter: ConnectionFilter) -> [Connection] { all.filter(filter.matches) }
        #expect(matching(.all) == all)
        #expect(matching(.established) == [established])
        #expect(matching(.listening) == [listener, exposed])
        #expect(matching(.exposed) == [exposed, udp])
        #expect(matching(.udp) == [udp])
    }

    @Test func summarisesDistinctPortsHostsAndProcesses() {
        let connections = [
            Self.make(pid: 1, local: ("0.0.0.0", 5000), state: .listen),
            Self.make(pid: 1, local: ("::", 5000), state: .listen), // same port over IPv6
            Self.make(pid: 2, local: ("127.0.0.1", 3000), state: .listen),
            Self.make(.udp, pid: 3, local: ("0.0.0.0", 5353)),
            Self.make(.udp, pid: 3, local: ("::", 5353)),
            Self.make(pid: 4, local: ("10.0.0.2", 50000), remote: ("17.57.146.20", 443), state: .established),
            Self.make(pid: 4, local: ("10.0.0.2", 50001), remote: ("17.57.146.20", 443), state: .established),
            Self.make(pid: 4, local: ("10.0.0.2", 50002), remote: ("10.0.0.9", 445), state: .closeWait),
            Self.make(pid: 2, local: ("127.0.0.1", 50003), remote: ("127.0.0.1", 3000), state: .established),
        ]
        let summary = ConnectionSummary(connections)
        #expect(summary.openConnections == 4)
        #expect(summary.listeningPorts == 3, "TCP 5000, TCP 3000 and UDP 5353")
        #expect(summary.exposedPorts == 2, "TCP 5000 and UDP 5353; 3000 is loopback only")
        #expect(summary.exposedOnAllInterfaces == 2)
        #expect(summary.remoteHosts == 2, "loopback peers don't count")
        #expect(summary.processesWithSockets == 4)
        #expect(ConnectionSummary([]) == ConnectionSummary())
    }

    @Test func separatesAllInterfaceBindsFromOneAddress() {
        let summary = ConnectionSummary([
            Self.make(local: ("0.0.0.0", 22), state: .listen),
            Self.make(local: ("10.0.0.2", 8080), state: .listen), // one network address
            Self.make(local: ("10.0.0.2", 22), state: .listen), // 22 again: still on every interface
            Self.make(.udp, local: ("::", 5353)),
        ])
        #expect(summary.exposedPorts == 3)
        #expect(summary.exposedOnAllInterfaces == 2, "TCP 22 and UDP 5353; 8080 is on one address")
    }
}

/// Decoding the kernel's socket records, from hand-built fixtures.
struct SocketDecodeTests {
    private func ipv4(_ text: String) -> in_addr {
        var address = in_addr()
        inet_pton(AF_INET, text, &address)
        return address
    }

    private func ipv6(_ text: String) -> in6_addr {
        var address = in6_addr()
        inet_pton(AF_INET6, text, &address)
        return address
    }

    private func port(_ value: UInt16) -> Int32 {
        Int32(value.bigEndian)
    }

    private func tcp(state: Int32, configure: (inout in_sockinfo) -> Void) -> socket_info {
        var info = socket_info()
        info.soi_kind = Int32(SOCKINFO_TCP)
        info.soi_so = 0xABCD
        info.soi_proto.pri_tcp.tcpsi_state = state
        configure(&info.soi_proto.pri_tcp.tcpsi_ini)
        return info
    }

    @Test func decodesDualStackListener() throws {
        let info = tcp(state: TSI_S_LISTEN) { inet in
            inet.insi_vflag = UInt8(INI_IPV4 | INI_IPV6)
            inet.insi_laddr.ina_6 = ipv6("::")
            inet.insi_lport = port(8080)
        }
        let connection = try #require(ConnectionSampler.decode(info, pid: 42, fd: 7, processName: "server"))
        #expect(connection.id == Connection.SocketID(pid: 42, fd: 7, socket: 0xABCD))
        #expect(connection.transport == .tcp)
        #expect(connection.family == .dual)
        #expect(connection.local.formatted == "*:8080")
        #expect(connection.remote == nil)
        #expect(connection.tcpState == .listen)
        #expect(connection.kind == .listening)
        #expect(connection.isExposed)
    }

    @Test func decodesEstablishedIPv4() throws {
        let info = tcp(state: TSI_S_ESTABLISHED) { inet in
            inet.insi_vflag = UInt8(INI_IPV4)
            inet.insi_laddr.ina_46.i46a_addr4 = ipv4("192.168.1.10")
            inet.insi_lport = port(52100)
            inet.insi_faddr.ina_46.i46a_addr4 = ipv4("17.57.146.20")
            inet.insi_fport = port(5223)
        }
        let connection = try #require(ConnectionSampler.decode(info, pid: 42, fd: 8, processName: "apsd"))
        #expect(connection.family == .ipv4)
        #expect(connection.local.formatted == "192.168.1.10:52100")
        #expect(connection.remote?.formatted == "17.57.146.20:5223")
        #expect(connection.kind == .established)
        #expect(connection.scope == .internet)
        #expect(connection.service?.name == "Apple Push")
    }

    @Test func movesTheLinkLocalZoneOutOfTheAddress() throws {
        // The kernel embeds the interface index (1, lo0) in bytes 2 and 3.
        let info = tcp(state: TSI_S_ESTABLISHED) { inet in
            inet.insi_vflag = UInt8(INI_IPV6)
            inet.insi_laddr.ina_6 = ipv6("fe80:1::1")
            inet.insi_lport = port(50000)
            inet.insi_faddr.ina_6 = ipv6("fe80:1::2")
            inet.insi_fport = port(22)
        }
        let connection = try #require(ConnectionSampler.decode(info, pid: 1, fd: 3, processName: "ssh"))
        #expect(connection.local.address == "fe80::1%lo0")
        #expect(connection.remote?.formatted == "[fe80::2%lo0]:22")
        #expect(connection.scope == .localNetwork)
    }

    @Test func decodesBoundUDP() throws {
        var info = socket_info()
        info.soi_kind = Int32(SOCKINFO_IN)
        info.soi_protocol = IPPROTO_UDP
        info.soi_proto.pri_in.insi_vflag = UInt8(INI_IPV4)
        info.soi_proto.pri_in.insi_laddr.ina_46.i46a_addr4 = ipv4("0.0.0.0")
        info.soi_proto.pri_in.insi_lport = port(5353)
        let connection = try #require(ConnectionSampler.decode(info, pid: 1, fd: 3, processName: "mdns"))
        #expect(connection.transport == .udp)
        #expect(connection.tcpState == nil)
        #expect(connection.kind == .udpBound)
        #expect(connection.isExposed)
        #expect(connection.service?.name == "Bonjour (mDNS)")
    }

    @Test func skipsUnboundAndNonInternetSockets() {
        let fresh = tcp(state: TSI_S_CLOSED) { $0.insi_vflag = UInt8(INI_IPV4) }
        #expect(ConnectionSampler.decode(fresh, pid: 1, fd: 3, processName: "x") == nil)

        var unix = socket_info()
        unix.soi_kind = Int32(SOCKINFO_UN)
        #expect(ConnectionSampler.decode(unix, pid: 1, fd: 3, processName: "x") == nil)

        var raw = socket_info()
        raw.soi_kind = Int32(SOCKINFO_IN)
        raw.soi_protocol = IPPROTO_ICMP
        raw.soi_proto.pri_in.insi_lport = port(1)
        #expect(ConnectionSampler.decode(raw, pid: 1, fd: 3, processName: "x") == nil)
    }
}

/// Opens a real listener and finds it in a system-wide walk.
struct ConnectionSamplerLiveTests {
    @Test func findsOwnLoopbackListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let snapshot = ConnectionSampler.sample()
        let mine = try #require(snapshot.connections.first { $0.pid == getpid() && $0.id.fd == fd })
        #expect(mine.transport == .tcp)
        #expect(mine.kind == .listening)
        #expect(mine.local.formatted == "127.0.0.1:\(port)")
        #expect(mine.scope == .loopback)
        #expect(!mine.isExposed)
        #expect(snapshot.scannedProcesses > 0)
        #expect(snapshot.hiddenProcesses >= 0)
        #expect(snapshot.duration >= 0)
    }
}
