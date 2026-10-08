import Darwin
import Foundation

/// Every TCP and UDP socket the caller is allowed to see, by process.
public struct ConnectionSnapshot: Sendable {
    public let connections: [Connection]
    /// Processes macOS wouldn't list sockets for (root's and other users').
    /// Their sockets are missing from `connections`.
    public let hiddenProcesses: Int
    /// Processes whose descriptors were read.
    public let scannedProcesses: Int
    /// How long the walk took.
    public let duration: TimeInterval
    public let cpuDuration: TimeInterval
    public let unreadablePIDs: Set<Int32>
    public let processes: [ProcessIdentity: ConnectionProcess]
    /// When the walk began.
    public let time: Date

    public init(connections: [Connection], hiddenProcesses: Int, scannedProcesses: Int, duration: TimeInterval,
                time: Date = Date(), cpuDuration: TimeInterval = 0, unreadablePIDs: Set<Int32> = [],
                processes: [ProcessIdentity: ConnectionProcess] = [:]) {
        self.connections = connections
        self.hiddenProcesses = hiddenProcesses
        self.scannedProcesses = scannedProcesses
        self.duration = duration
        self.time = time
        self.cpuDuration = cpuDuration
        self.unreadablePIDs = unreadablePIDs
        self.processes = processes
    }
}

/// Walks every process's descriptor table for internet sockets.
///
/// This is a few thousand system calls, so it's meant for an occasional
/// refresh (the Connections page every few seconds), not the main sampler's tick.
public enum ConnectionSampler {
    public static func sample() -> ConnectionSnapshot {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        let time = Date()
        let started = DispatchTime.now()
        let cpuStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        var connections: [Connection] = []
        var hidden = 0
        var unreadable = Set<Int32>()
        var scanned = 0
        var metadata: [ProcessIdentity: ConnectionProcess] = [:]
        var users: [UInt32: String] = [:]

        // PID 0 is the kernel, which has no descriptor table to read.
        for pid in allPIDs() where pid > 0 {
            errno = 0
            guard let count = listDescriptors(of: pid, into: &descriptors) else {
                unreadable.insert(pid)
                if errno == EPERM || errno == EACCES { hidden += 1 }
                continue
            }
            scanned += 1
            var process: Description?
            for descriptor in descriptors.prefix(count) where Int32(descriptor.proc_fdtype) == PROX_FDTYPE_SOCKET {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                errno = 0
                guard unsafe proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else {
                    if unreadable.insert(pid).inserted, errno == EPERM || errno == EACCES { hidden += 1 }
                    continue
                }
                let described = process ?? describe(pid)
                process = described
                if let connection = decode(info.psi, pid: pid, fd: descriptor.proc_fd, processName: described.name,
                                           processStart: described.start) {
                    connections.append(connection)
                    if metadata[connection.process] == nil {
                        let user = described.uid.map { uid in
                            let name = users[uid] ?? UserAccounts.account(uid: uid)?.name ?? String(uid)
                            users[uid] = name
                            return name
                        } ?? "Not recorded"
                        metadata[connection.process] = ConnectionProcess(name: described.name, path: described.path, user: user)
                    }
                }
            }
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        return ConnectionSnapshot(connections: connections, hiddenProcesses: hidden, scannedProcesses: scanned,
                                  duration: elapsed, time: time,
                                  cpuDuration: Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStarted) / 1_000_000_000,
                                  unreadablePIDs: unreadable, processes: metadata)
    }

    /// A TCP or UDP socket as a connection. Sockets that are neither bound
    /// to a port nor connected (just created) aren't worth a row, so they're nil.
    static func decode(_ info: socket_info, pid: Int32, fd: Int32, processName: String,
                       processStart: Date? = nil) -> Connection? {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        let transport: Connection.Transport
        let inet: in_sockinfo
        var state: TCPState?
        switch Int32(info.soi_kind) {
        case Int32(SOCKINFO_TCP):
            transport = .tcp
            inet = unsafe info.soi_proto.pri_tcp.tcpsi_ini
            state = unsafe TCPState(kernelValue: info.soi_proto.pri_tcp.tcpsi_state)
        case Int32(SOCKINFO_IN) where info.soi_protocol == IPPROTO_UDP:
            transport = .udp
            inet = unsafe info.soi_proto.pri_in
        default:
            return nil
        }
        let endpoints = SocketDecoder.endpoints(inet)
        guard endpoints.local.port != nil || endpoints.remote != nil else { return nil }
        return Connection(
            id: Connection.SocketID(pid: pid, fd: fd, socket: info.soi_so),
            processName: processName, transport: transport, family: endpoints.family,
            local: endpoints.local, remote: endpoints.remote, tcpState: state, processStart: processStart
        )
    }

    // MARK: - Kernel reads

    private static func allPIDs() -> [Int32] {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Processes can start between the two calls; leave headroom.
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let written = pids.withUnsafeMutableBytes { unsafe proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written)))
    }

    /// Fills `buffer` with the process's descriptors and returns how many
    /// there are, growing the buffer when it's too small. Nil with `errno`
    /// set when the process can't be read.
    private static func listDescriptors(of pid: Int32, into buffer: inout [proc_fdinfo]) -> Int? {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        let stride = MemoryLayout<proc_fdinfo>.stride
        for _ in 0..<3 {
            let written = buffer.withUnsafeMutableBytes {
                unsafe proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if written == 0, errno == 0 { return 0 }
            guard written > 0 else { return nil }
            // A full buffer may have cut the list short; ask for the real size.
            guard Int(written) >= buffer.count * stride else { return Int(written) / stride }
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return nil }
            buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: max(Int(needed) / stride + 32, buffer.count * 2))
        }
        return buffer.count
    }

    /// The process's name and when it started, from the one record
    /// `proc_name` reads the name from, so the start time takes no extra call.
    private struct Description {
        let name: String
        let start: Date?
        let path: String?
        let uid: UInt32?
    }

    private static func describe(_ pid: Int32) -> Description {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return Description(name: "PID \(pid)", start: nil, path: nil, uid: nil)
        }
        let name = text(info.pbi_name)
        let shown = name.isEmpty ? text(info.pbi_comm) : name
        let start = ProcessIdentity.startTime(microseconds: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec))
        var path = [CChar](repeating: 0, count: 4096)
        let length = path.withUnsafeMutableBytes { unsafe proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let executable = length > 0 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return Description(name: shown.isEmpty ? "PID \(pid)" : shown, start: start, path: executable, uid: info.pbi_uid)
    }

    /// A kernel record's fixed-size C string, up to its first NUL.
    private static func text<Characters>(_ characters: Characters) -> String {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        withUnsafeBytes(of: characters) { unsafe String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Turns the kernel's socket records into addresses and ports. Shared by the
/// connection walk and the per-process inspector.
enum SocketDecoder {
    struct Endpoints {
        let family: Connection.Family
        let local: Endpoint
        /// Nil until the socket is connected (no foreign port).
        let remote: Endpoint?
    }

    static func endpoints(_ info: in_sockinfo) -> Endpoints {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        let hasIPv4 = info.insi_vflag & UInt8(INI_IPV4) != 0
        let isIPv6 = info.insi_vflag & UInt8(INI_IPV6) != 0
        let family: Connection.Family = isIPv6 ? (hasIPv4 ? .dual : .ipv6) : .ipv4
        let local = unsafe isIPv6 ? address(info.insi_laddr.ina_6) : address(info.insi_laddr.ina_46.i46a_addr4)
        let remote = unsafe isIPv6 ? address(info.insi_faddr.ina_6) : address(info.insi_faddr.ina_46.i46a_addr4)
        let localPort = port(info.insi_lport)
        let remotePort = port(info.insi_fport)
        return Endpoints(
            family: family,
            local: Endpoint(address: local, port: localPort),
            remote: remotePort == 0 ? nil : Endpoint(address: remote, port: remotePort)
        )
    }

    /// Ports are stored in network byte order in the low 16 bits.
    static func port(_ raw: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
    }

    static func address(_ address: in_addr) -> String {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard unsafe inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The kernel keeps a link-local address's interface index inside the
    /// address (bytes 2 and 3). It's moved out into a `%en0` zone, the way
    /// `netstat` prints it, so the address itself reads normally.
    static func address(_ address: in6_addr) -> String {
        // Kernel calls receive the allocated byte capacity; kind and family select the union layouts, and text
        // reads stay within their buffers.
        var bytes = withUnsafeBytes(of: address) { unsafe Array($0) }
        var zone = ""
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            let index = UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            if index != 0 {
                bytes[2] = 0
                bytes[3] = 0
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                zone = unsafe if_indextoname(index, &name) != nil
                    ? "%" + String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    : "%\(index)"
            }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let text = bytes.withUnsafeBytes { raw in
            unsafe inet_ntop(AF_INET6, raw.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard unsafe text != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + zone
    }
}
