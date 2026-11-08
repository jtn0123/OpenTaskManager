import Foundation

extension Connection {
    /// Kept beside the name even when optional columns give way. Separate
    /// descriptors stay separate rows, and wildcard endpoints can hide a family.
    public var historyIdentity: String { "PID \(pid) · fd \(id.fd) · \(shortFamily)" }

    public var shortFamily: String {
        switch family {
        case .ipv4: "IPv4"
        case .ipv6: "IPv6"
        case .dual: "IPv4/6"
        }
    }
}

public enum ConnectionHistoryColumn: String, CaseIterable, Sendable {
    case process, endpoints, transport, seen, ended
}
