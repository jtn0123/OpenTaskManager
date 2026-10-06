import Darwin
import Foundation

public struct ProcessArguments: Sendable, Codable, Hashable {
    public let executable: String
    public let arguments: [String]
    /// Environment entries in launch order, as `KEY=value` pairs split once.
    public let environment: [EnvironmentVariable]

    public var commandLine: String {
        arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

public struct EnvironmentVariable: Sendable, Codable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let value: String
}

public struct OpenFile: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case file, directory, socket, pipe, other
    }

    public var id: Int32 { descriptor }
    public let descriptor: Int32
    public let kind: Kind
    /// File path, or a socket description such as `TCP 127.0.0.1:3000 → 10.0.0.2:52100`.
    public let detail: String
    public let socket: SocketInfo?
}

public struct SocketInfo: Sendable, Codable, Hashable {
    public enum TransportProtocol: String, Sendable, Codable {
        case tcp = "TCP", udp = "UDP", unix = "UNIX", other = "Other"
    }

    public let proto: TransportProtocol
    public let localAddress: String?
    public let localPort: Int?
    public let remoteAddress: String?
    public let remotePort: Int?
    /// TCP state such as LISTEN or ESTABLISHED.
    public let state: String?

    public var isListening: Bool { state == "LISTEN" || (proto == .udp && remotePort == nil) }
}

/// On-demand, per-process details too expensive to gather every tick.
public enum ProcessInspector {
    /// Arguments and environment from KERN_PROCARGS2. macOS only returns these
    /// for processes owned by the caller.
    public static func arguments(of pid: Int32) -> ProcessArguments? {
        guard let bytes = Sysctl.bytes([CTL_KERN, KERN_PROCARGS2, pid]) else { return nil }
        return parseProcArgs(bytes)
    }

    /// Layout: argc (Int32), executable path, NUL padding, argc argument
    /// strings, then environment strings until an empty string.
    static func parseProcArgs(_ bytes: [UInt8]) -> ProcessArguments? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }

        guard let executable = nextString() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        for _ in 0..<max(argc, 0) {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }

        var environment: [EnvironmentVariable] = []
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment.append(EnvironmentVariable(
                name: String(entry[..<equals]),
                value: String(entry[entry.index(after: equals)...])
            ))
        }
        return ProcessArguments(executable: executable, arguments: arguments, environment: environment)
    }

    public static func currentDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let path = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return path.isEmpty ? nil : path
        }
    }

    /// Open file descriptors with paths and socket endpoints. Returns nil when
    /// macOS denies access (another user's process).
    public static func openFiles(of pid: Int32) -> [OpenFile]? {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let capacity = Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return nil }
        let count = Int(written) / MemoryLayout<proc_fdinfo>.stride

        return descriptors.prefix(count).compactMap { descriptor in
            switch Int32(descriptor.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                return vnode(pid: pid, fd: descriptor.proc_fd)
            case PROX_FDTYPE_SOCKET:
                return socket(pid: pid, fd: descriptor.proc_fd)
            case PROX_FDTYPE_PIPE:
                return OpenFile(descriptor: descriptor.proc_fd, kind: .pipe, detail: "pipe", socket: nil)
            default:
                return nil
            }
        }
    }

    private static func vnode(pid: Int32, fd: Int32) -> OpenFile? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let mode = info.pvip.vip_vi.vi_stat.vst_mode
        let kind: OpenFile.Kind = (mode & S_IFMT) == S_IFDIR ? .directory : .file
        return OpenFile(descriptor: fd, kind: kind, detail: path, socket: nil)
    }

    private static func socket(pid: Int32, fd: Int32) -> OpenFile? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        let psi = info.psi

        let socketInfo: SocketInfo
        switch Int32(psi.soi_kind) {
        case Int32(SOCKINFO_TCP):
            let tcp = psi.soi_proto.pri_tcp
            let endpoints = inetEndpoints(tcp.tcpsi_ini)
            socketInfo = SocketInfo(
                proto: .tcp,
                localAddress: endpoints.local, localPort: endpoints.localPort,
                remoteAddress: endpoints.remote, remotePort: endpoints.remotePort,
                state: tcpState(tcp.tcpsi_state)
            )
        case Int32(SOCKINFO_IN):
            let endpoints = inetEndpoints(psi.soi_proto.pri_in)
            socketInfo = SocketInfo(
                proto: psi.soi_protocol == IPPROTO_UDP ? .udp : .other,
                localAddress: endpoints.local, localPort: endpoints.localPort,
                remoteAddress: endpoints.remote, remotePort: endpoints.remotePort,
                state: nil
            )
        case Int32(SOCKINFO_UN):
            let path = withUnsafeBytes(of: psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            socketInfo = SocketInfo(proto: .unix, localAddress: path.isEmpty ? nil : path, localPort: nil,
                                    remoteAddress: nil, remotePort: nil, state: nil)
        default:
            socketInfo = SocketInfo(proto: .other, localAddress: nil, localPort: nil, remoteAddress: nil, remotePort: nil, state: nil)
        }
        return OpenFile(descriptor: fd, kind: .socket, detail: describe(socketInfo), socket: socketInfo)
    }

    private struct Endpoints {
        let local: String?
        let localPort: Int?
        let remote: String?
        let remotePort: Int?
    }

    private static func inetEndpoints(_ info: in_sockinfo) -> Endpoints {
        let isIPv6 = info.insi_vflag & UInt8(INI_IPV6) != 0
        let local = isIPv6 ? format(info.insi_laddr.ina_6) : format(info.insi_laddr.ina_46.i46a_addr4)
        let remote = isIPv6 ? format(info.insi_faddr.ina_6) : format(info.insi_faddr.ina_46.i46a_addr4)
        let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.insi_lport)))
        let remotePort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.insi_fport)))
        return Endpoints(
            local: local, localPort: localPort == 0 ? nil : localPort,
            remote: remotePort == 0 ? nil : remote, remotePort: remotePort == 0 ? nil : remotePort
        )
    }

    private static func format(_ address: in_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func format(_ address: in6_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func tcpState(_ state: Int32) -> String {
        let names = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT",
                     "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]
        return names.indices.contains(Int(state)) ? names[Int(state)] : "UNKNOWN"
    }

    static func describe(_ socket: SocketInfo) -> String {
        func endpoint(_ address: String?, _ port: Int?) -> String {
            let host = address.map { $0.contains(":") ? "[\($0)]" : $0 } ?? "*"
            return port.map { "\(host):\($0)" } ?? host
        }
        var text = "\(socket.proto.rawValue) \(endpoint(socket.localAddress, socket.localPort))"
        if socket.remoteAddress != nil || socket.remotePort != nil {
            text += " → \(endpoint(socket.remoteAddress, socket.remotePort))"
        }
        if let state = socket.state { text += " (\(state))" }
        return text
    }
}
