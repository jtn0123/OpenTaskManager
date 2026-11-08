import Foundation

/// Every process's TCP and UDP sockets, read once with an administrator's
/// password (`PrivilegedSocketReader`), for the processes the Connections
/// page can't read: root's and other accounts'. A snapshot: nothing
/// refreshes it, and nothing keeps running as root.
public struct PrivilegedSocketRead: Sendable {
    public struct Row: Sendable, Identifiable, Hashable {
        public let connection: Connection
        /// The account the process runs as, as lsof names it.
        public let user: String

        public var id: Connection.SocketID { connection.id }
    }

    public let rows: [Row]
    public let readAt: Date

    public init(rows: [Row], readAt: Date) {
        self.rows = rows
        self.readAt = readAt
    }

    /// The rows of processes running as anyone but `user`, the ones the page leaves out.
    public func rows(notRunningAs user: String) -> [Row] {
        rows.filter { $0.user != user }
    }

    /// Reads lsof's field output (`-F pcuLftPnT`): a `p` line starts each
    /// process, with its command (`c`) and login (`L`, or `u`, the UID,
    /// without one), and an `f` line each socket, with its family (`t`),
    /// protocol (`P`), addresses (`n`, "local->remote") and TCP state
    /// (`TST=`). Other protocols and lines it can't read are left out.
    public init(lsofFields text: String, readAt: Date) {
        var rows: [Row] = []
        var process: ProcessFields?
        var socket = SocketFields()

        func finishSocket() {
            if let process, let connection = socket.connection(pid: process.pid, command: process.command) {
                rows.append(Row(connection: connection, user: process.user))
            }
            socket = SocketFields()
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                finishSocket()
                process = Int32(value).map { ProcessFields(pid: $0) }
            case "c": process?.command = String(value)
            case "L": process?.user = String(value)
            // lsof prints the UID first; a login name replaces it.
            case "u": process?.user = String(value)
            case "f":
                finishSocket()
                socket.fd = Int32(value)
            case "t": socket.family = value == "IPv6" ? .ipv6 : value == "IPv4" ? .ipv4 : nil
            case "P": socket.transport = Connection.Transport(rawValue: String(value))
            case "n": socket.name = value
            case "T":
                if value.hasPrefix("ST=") { socket.state = Self.state(value.dropFirst(3)) }
            default: break
            }
        }
        finishSocket()
        self.init(rows: rows, readAt: readAt)
    }

    /// A `p` line's process, until the next one starts.
    private struct ProcessFields {
        let pid: Int32
        var command = ""
        var user = ""
    }

    /// One `f` line's fields, until the next socket or process starts.
    private struct SocketFields {
        var fd: Int32?
        var family: Connection.Family?
        var transport: Connection.Transport?
        var name: Substring?
        var state: TCPState?

        func connection(pid: Int32, command: String) -> Connection? {
            guard let fd, let family, let transport, let name else { return nil }
            let ends = name.split(separator: "->", maxSplits: 1, omittingEmptySubsequences: false)
            guard let local = PrivilegedSocketRead.endpoint(ends[0], family: family) else { return nil }
            let remote = ends.count > 1 ? PrivilegedSocketRead.endpoint(ends[1], family: family) : nil
            return Connection(id: .init(pid: pid, fd: fd, socket: 0), processName: command, transport: transport, family: family,
                              local: local, remote: remote, tcpState: transport == .tcp ? state : nil)
        }
    }

    /// lsof's state names are the kernel's, but for "SYN_RCVD".
    static func state(_ name: Substring) -> TCPState? {
        name == "SYN_RCVD" ? .synReceived : TCPState(rawValue: String(name))
    }

    /// "10.0.0.2:5000", "[fe80::1%en0]:123", "*:22" (any address), "*:*" (no port yet).
    static func endpoint(_ text: Substring, family: Connection.Family) -> Endpoint? {
        let host: Substring
        let port: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]"), text[close...].dropFirst().first == ":" else { return nil }
            host = text[text.index(after: text.startIndex)..<close]
            port = text[close...].dropFirst(2)
        } else {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            host = text[..<colon]
            port = text[text.index(after: colon)...]
        }
        guard !host.isEmpty, port == "*" || Int(port) != nil else { return nil }
        let address = host == "*" ? (family == .ipv4 ? "0.0.0.0" : "::") : String(host)
        return Endpoint(address: address, port: Int(port))
    }
}
