import Darwin
import Foundation

/// One TCP or UDP socket held open by a process.
public struct Connection: Sendable, Hashable, Codable, Identifiable {
    /// Stable across refreshes: the same socket keeps the same descriptor and
    /// kernel handle for as long as the process holds it.
    public struct SocketID: Sendable, Hashable, Codable {
        public let pid: Int32
        public let fd: Int32
        /// The kernel's opaque handle for the socket (`soi_so`).
        public let socket: UInt64

        public init(pid: Int32, fd: Int32, socket: UInt64) {
            self.pid = pid
            self.fd = fd
            self.socket = socket
        }
    }

    public enum Transport: String, Sendable, Codable, CaseIterable {
        case tcp = "TCP", udp = "UDP"
    }

    public enum Family: String, Sendable, Codable {
        case ipv4 = "IPv4", ipv6 = "IPv6"
        /// An IPv6 socket that also accepts IPv4, such as a listener on `::`.
        case dual = "IPv4 and IPv6"
    }

    public let id: SocketID
    public let processName: String
    public let transport: Transport
    public let family: Family
    public let local: Endpoint
    /// The other end, for connected sockets.
    public let remote: Endpoint?
    /// TCP only.
    public let tcpState: TCPState?
    public let kind: ConnectionKind

    public init(id: SocketID, processName: String, transport: Transport, family: Family,
                local: Endpoint, remote: Endpoint?, tcpState: TCPState?) {
        self.id = id
        self.processName = processName
        self.transport = transport
        self.family = family
        self.local = local
        self.remote = remote
        self.tcpState = tcpState
        kind = ConnectionKind(transport: transport, state: tcpState, hasRemote: remote != nil)
    }

    public var pid: Int32 { id.pid }

    /// Where traffic on this socket can come from or go to: the remote end's
    /// scope when connected, otherwise the address it's bound to.
    public var scope: AddressScope { remote?.scope ?? local.scope }

    /// Accepts traffic from other machines: a listener or bound UDP socket on
    /// any address but loopback. Wildcard binds (`0.0.0.0`, `::`) are the
    /// usual case; they're reachable on every interface unless a firewall says no.
    public var isExposed: Bool { kind.acceptsInbound && local.scope != .loopback }

    /// "Established", "Listening", "Time wait"; UDP has no state machine, so
    /// it reads "Bound" or "Connected".
    public var stateLabel: String { tcpState?.label ?? kind.label }

    /// The well-known service on either end, preferring the remote port, since
    /// for an outgoing connection that's the service being used.
    public var service: (name: String, port: Int)? {
        for port in [remote?.port, local.port].compactMap({ $0 }) {
            if let name = WellKnownPorts.name(for: port, transport: transport) { return (name, port) }
        }
        return nil
    }
}

/// An address and port as the kernel reports them.
public struct Endpoint: Sendable, Hashable, Codable {
    /// Numeric form: `127.0.0.1`, `::1`, `fe80::1%en0`, or the wildcard `0.0.0.0` / `::`.
    public let address: String
    /// Nil when unbound (port 0).
    public let port: Int?
    public let scope: AddressScope

    public init(address: String, port: Int?) {
        self.address = address
        self.port = port == 0 ? nil : port
        scope = AddressScope(address: address)
    }

    /// Bound to every interface rather than one address.
    public var isWildcard: Bool { scope == .allInterfaces }

    /// `127.0.0.1:3000`, `[::1]:443`, `*:22`.
    public var formatted: String { Self.format(address: address, port: port) }

    /// Wildcards print as `*`, and IPv6 addresses go in brackets so the port
    /// can't be mistaken for part of the address.
    public static func format(address: String?, port: Int?) -> String {
        let host: String
        if let address, !address.isEmpty, AddressScope(address: address) != .allInterfaces {
            host = address.contains(":") ? "[\(address)]" : address
        } else {
            host = "*"
        }
        guard let port, port != 0 else { return host }
        return "\(host):\(port)"
    }
}

/// How far away an address is.
public enum AddressScope: String, Sendable, Codable, CaseIterable {
    /// 127.0.0.0/8 or ::1: only this Mac.
    case loopback
    /// Private (RFC 1918), link-local, unique-local (fc00::/7) and multicast.
    case localNetwork
    /// Anything else.
    case internet
    /// The wildcard `0.0.0.0` or `::`: bound to every interface.
    case allInterfaces

    public var label: String {
        switch self {
        case .loopback: "Loopback"
        case .localNetwork: "Local network"
        case .internet: "Internet"
        case .allInterfaces: "All interfaces"
        }
    }

    /// Classifies a numeric IPv4 or IPv6 address. A zone suffix (`%en0`) is
    /// ignored, and text that isn't an address counts as the internet.
    public init(address: String) {
        let host = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            self = Self.classify(ipv4: UInt32(bigEndian: v4.s_addr))
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            self = Self.classify(ipv6: withUnsafeBytes(of: v6) { Array($0) })
            return
        }
        self = .internet
    }

    /// `address` in host byte order.
    static func classify(ipv4 address: UInt32) -> AddressScope {
        let octets = (address >> 24, (address >> 16) & 0xFF)
        switch octets {
        case (0, _) where address == 0: return .allInterfaces
        case (127, _): return .loopback
        case (10, _), (192, 168), (169, 254): return .localNetwork
        case (172, 16...31): return .localNetwork
        case (224...239, _): return .localNetwork // multicast
        default: return address == 0xFFFF_FFFF ? .localNetwork : .internet
        }
    }

    static func classify(ipv6 bytes: [UInt8]) -> AddressScope {
        guard bytes.count == 16 else { return .internet }
        if bytes.allSatisfy({ $0 == 0 }) { return .allInterfaces }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .loopback }
        // IPv4-mapped (::ffff:a.b.c.d): judge the IPv4 address inside.
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let v4 = bytes[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return classify(ipv4: v4)
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .localNetwork } // fe80::/10 link-local
        if bytes[0] & 0xFE == 0xFC { return .localNetwork } // fc00::/7 unique local
        if bytes[0] == 0xFF { return .localNetwork } // multicast
        return .internet
    }
}

/// TCP states, in the kernel's numbering (`TSI_S_*`).
public enum TCPState: String, Sendable, Codable, CaseIterable {
    case closed = "CLOSED"
    case listen = "LISTEN"
    case synSent = "SYN_SENT"
    case synReceived = "SYN_RECEIVED"
    case established = "ESTABLISHED"
    case closeWait = "CLOSE_WAIT"
    case finWait1 = "FIN_WAIT_1"
    case closing = "CLOSING"
    case lastAck = "LAST_ACK"
    case finWait2 = "FIN_WAIT_2"
    case timeWait = "TIME_WAIT"

    public init?(kernelValue: Int32) {
        guard Self.allCases.indices.contains(Int(kernelValue)) else { return nil }
        self = Self.allCases[Int(kernelValue)]
    }

    public var label: String {
        switch self {
        case .closed: "Closed"
        case .listen: "Listening"
        case .synSent: "SYN sent"
        case .synReceived: "SYN received"
        case .established: "Established"
        case .closeWait: "Close wait"
        case .finWait1: "FIN wait 1"
        case .closing: "Closing"
        case .lastAck: "Last ACK"
        case .finWait2: "FIN wait 2"
        case .timeWait: "Time wait"
        }
    }
}

/// What a socket is doing, in coarser terms than the TCP state machine.
public enum ConnectionKind: String, Sendable, Codable, CaseIterable {
    /// TCP, waiting for connections.
    case listening
    case established
    /// TCP handshake in progress.
    case connecting
    /// TCP shutting down (close wait, FIN wait, last ACK, time wait).
    case closing
    /// TCP socket bound but neither listening nor connected.
    case closed
    /// UDP socket bound to a port and receiving from anyone.
    case udpBound
    /// UDP socket connected to one peer.
    case udpConnected

    public init(transport: Connection.Transport, state: TCPState?, hasRemote: Bool) {
        switch transport {
        case .udp:
            self = hasRemote ? .udpConnected : .udpBound
        case .tcp:
            switch state {
            case .listen: self = .listening
            case .established: self = .established
            case .synSent, .synReceived: self = .connecting
            case .closeWait, .finWait1, .closing, .lastAck, .finWait2, .timeWait: self = .closing
            case .closed, nil: self = .closed
            }
        }
    }

    /// Takes traffic from any peer rather than one.
    public var acceptsInbound: Bool { self == .listening || self == .udpBound }

    public var label: String {
        switch self {
        case .listening: "Listening"
        case .established: "Established"
        case .connecting: "Connecting"
        case .closing: "Closing"
        case .closed: "Closed"
        case .udpBound: "Bound"
        case .udpConnected: "Connected"
        }
    }

    /// Sort order for a State column: servers first, then live traffic, then the rest.
    public var rank: Int {
        switch self {
        case .listening: 0
        case .udpBound: 1
        case .established: 2
        case .udpConnected: 3
        case .connecting: 4
        case .closing: 5
        case .closed: 6
        }
    }
}

/// The segmented filter on the Connections page.
public enum ConnectionFilter: String, Sendable, CaseIterable, Identifiable {
    case all = "All"
    case established = "Established"
    case listening = "Listening"
    case exposed = "Exposed"
    case udp = "UDP"

    public var id: String { rawValue }

    public func matches(_ connection: Connection) -> Bool {
        switch self {
        case .all: true
        case .established: connection.kind == .established
        case .listening: connection.kind == .listening
        case .exposed: connection.isExposed
        case .udp: connection.transport == .udp
        }
    }
}

/// Headline counts for a set of sockets.
public struct ConnectionSummary: Sendable, Equatable {
    /// Sockets with a peer: TCP past the handshake or closing, and connected UDP.
    public var openConnections = 0
    /// Distinct ports taking new traffic: TCP listeners and bound UDP.
    public var listeningPorts = 0
    /// Distinct ports reachable from other machines.
    public var exposedPorts = 0
    /// Those of `exposedPorts` bound to every interface (`0.0.0.0` or `::`),
    /// rather than to one network address.
    public var exposedOnAllInterfaces = 0
    /// Distinct peers other than this Mac.
    public var remoteHosts = 0
    public var processesWithSockets = 0

    public init() {}

    public init(_ connections: [Connection]) {
        struct Port: Hashable {
            let transport: Connection.Transport
            let port: Int
        }
        var listening = Set<Port>()
        var exposed = Set<Port>()
        var everywhere = Set<Port>()
        var hosts = Set<String>()
        var processes = Set<Int32>()
        for connection in connections {
            processes.insert(connection.pid)
            if let remote = connection.remote {
                openConnections += 1
                if remote.scope != .loopback { hosts.insert(remote.address) }
            }
            if connection.kind.acceptsInbound, let port = connection.local.port {
                listening.insert(Port(transport: connection.transport, port: port))
                if connection.isExposed {
                    exposed.insert(Port(transport: connection.transport, port: port))
                    if connection.local.isWildcard { everywhere.insert(Port(transport: connection.transport, port: port)) }
                }
            }
        }
        listeningPorts = listening.count
        exposedPorts = exposed.count
        exposedOnAllInterfaces = everywhere.count
        remoteHosts = hosts.count
        processesWithSockets = processes.count
    }
}

/// Names for the ports people are most likely to see. A short built-in list
/// rather than `getservbyport`, which isn't thread-safe and names hundreds of
/// obscure services that collide with ephemeral client ports.
public enum WellKnownPorts {
    private static let names: [Int: String] = [
        20: "FTP data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP",
        80: "HTTP", 88: "Kerberos", 110: "POP3", 123: "NTP", 137: "NetBIOS", 138: "NetBIOS", 139: "SMB over NetBIOS",
        143: "IMAP", 161: "SNMP", 389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTP over TLS", 500: "IKE (VPN)",
        548: "AFP file sharing", 587: "SMTP submission", 631: "IPP printing", 853: "DNS over TLS", 993: "IMAP over TLS",
        995: "POP3 over TLS", 1194: "OpenVPN", 1883: "MQTT", 1900: "SSDP (UPnP)", 3283: "Apple Remote Desktop",
        3306: "MySQL", 3389: "Remote Desktop", 3478: "STUN", 4500: "IPsec NAT traversal", 5000: "AirPlay",
        5223: "Apple Push", 5353: "Bonjour (mDNS)", 5432: "PostgreSQL", 5900: "Screen Sharing (VNC)", 6379: "Redis",
        7000: "AirPlay", 8080: "HTTP (alternate)", 8443: "HTTPS (alternate)", 27017: "MongoDB", 51820: "WireGuard",
    ]

    public static func name(for port: Int, transport: Connection.Transport) -> String? {
        // HTTP/3 runs over UDP on the HTTPS port.
        if port == 443, transport == .udp { return "QUIC (HTTPS)" }
        return names[port]
    }
}
