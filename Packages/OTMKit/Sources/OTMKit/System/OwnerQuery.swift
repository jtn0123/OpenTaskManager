import Foundation

/// A path or a local port. Resolving a path's inode is separate from parsing,
/// so spelling and matching rules can be checked without reading this Mac.
public enum OwnerQuery: Sendable, Equatable {
    case path(String)
    case port(Int, SocketInfo.TransportProtocol?)

    public static func parse(_ text: String) throws -> OwnerQuery {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw OwnerLookupError.invalidQuery }
        let lower = input.lowercased()
        let proto: SocketInfo.TransportProtocol?
        let number: String
        if lower.hasPrefix("tcp:") {
            proto = .tcp
            number = String(input.dropFirst(4))
        } else if lower.hasPrefix("udp:") {
            proto = .udp
            number = String(input.dropFirst(4))
        } else if input.hasPrefix(":") {
            proto = nil
            number = String(input.dropFirst())
        } else if input.allSatisfy({ $0.isASCII && $0.isNumber }) {
            proto = nil
            number = input
        } else {
            if let url = URL(string: text), url.isFileURL { return .path(url.path) }
            // Finder paths can contain leading or trailing spaces. Only the
            // port syntax ignores surrounding whitespace.
            return .path(text)
        }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(number), (1...65535).contains(port) else { throw OwnerLookupError.invalidPort }
        return .port(port, proto)
    }
}

public enum OwnerLookupError: Error, LocalizedError, Sendable {
    case invalidQuery, invalidPort, unreadablePath(String), processListUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidQuery: "Enter a file, folder or local port."
        case .invalidPort: "Use a local port from 1 to 65535, optionally prefixed with tcp: or udp:."
        case let .unreadablePath(path): "Could not read \(path). Check that it exists and you can access it."
        case .processListUnavailable: "macOS did not return the process list. Try searching again."
        }
    }
}

public struct OwnerFileIdentity: Sendable, Hashable, Codable {
    public let device: Int64
    public let inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// A resolved query. Folder paths are canonical and comparisons respect path
/// components, so /Work doesn't include /Workshop. Volumes also match by device.
public enum OwnerTarget: Sendable, Equatable, Codable {
    case file(path: String, identity: OwnerFileIdentity)
    case folder(path: String, volumeDevice: Int64?)
    case port(Int, SocketInfo.TransportProtocol?)

    public var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    public var volumeNote: String? {
        if case .folder(_, .some) = self {
            return "macOS may also prevent ejecting for reasons this lookup can't see, such as Spotlight indexing or the kernel."
        }
        return nil
    }

    public var checkedDescription: String {
        switch self {
        case let .file(path, _): "open file descriptors for \(path) (by device and inode)"
        case let .folder(path, _): "open file descriptors and current directories in \(path)"
        case let .port(port, proto): "\(proto?.rawValue ?? "TCP and UDP") sockets on local port \(port)"
        }
    }

    public func matches(_ descriptor: OwnerDescriptor) -> Bool {
        switch self {
        case let .file(_, identity):
            return descriptor.kind == .file && descriptor.fileIdentity == identity
        case let .folder(path, volumeDevice):
            guard descriptor.kind != .socket else { return false }
            if let volumeDevice, descriptor.fileIdentity?.device == volumeDevice { return true }
            guard let candidate = descriptor.path, !candidate.isEmpty else { return false }
            return candidate == path || candidate.hasPrefix(path == "/" ? "/" : path + "/")
        case let .port(port, proto):
            guard let socket = descriptor.socket, socket.proto == .tcp || socket.proto == .udp else { return false }
            return socket.localPort == port && (proto == nil || socket.proto == proto)
        }
    }

    public func matches(in descriptors: [OwnerDescriptor]) -> [OwnerDescriptor] {
        descriptors.filter(matches)
    }
}

/// What held the match: a descriptor, or a process's working directory.
public struct OwnerDescriptor: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case file, currentDirectory, socket }

    public let kind: Kind
    public let descriptor: Int32?
    public let path: String?
    public let fileIdentity: OwnerFileIdentity?
    public let socket: SocketInfo?

    public init(kind: Kind, descriptor: Int32? = nil, path: String? = nil,
                fileIdentity: OwnerFileIdentity? = nil, socket: SocketInfo? = nil) {
        self.kind = kind
        self.descriptor = descriptor
        self.path = path
        self.fileIdentity = fileIdentity
        self.socket = socket
    }

    public var label: String {
        if kind == .currentDirectory { return "Current directory · \(path ?? "Path unavailable")" }
        let prefix = descriptor.map { "FD \($0) · " } ?? ""
        if let socket { return prefix + ProcessInspector.describe(socket) }
        return prefix + (path.flatMap { $0.isEmpty ? nil : $0 } ?? "Path unavailable")
    }
}
