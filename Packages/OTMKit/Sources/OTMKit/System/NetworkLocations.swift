import Darwin
import Foundation
import SystemConfiguration

/// A location in System Settings' Network pane ("Automatic", "Office"): a
/// set of services with settings of their own, one set in use at a time.
/// Read-only from SystemConfiguration's preferences, which any user can read;
/// switching locations is left to System Settings.
public struct NetworkLocation: Sendable, Hashable, Identifiable {
    public struct Service: Sendable, Hashable {
        /// "Wi-Fi", "USB 10/100/1000 LAN".
        public let name: String
        /// BSD name of its interface; nil for a service without one.
        public let interface: String?
        /// Turned off with "Make Service Inactive".
        public let isEnabled: Bool

        public init(name: String, interface: String?, isEnabled: Bool) {
            self.name = name
            self.interface = interface
            self.isEnabled = isEnabled
        }
    }

    public let id: String
    public let name: String
    /// The location System Settings has chosen now.
    public let isCurrent: Bool
    /// Its services in its order, without the hidden ones macOS keeps for itself.
    public let services: [Service]

    public init(id: String, name: String, isCurrent: Bool, services: [Service]) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
        self.services = services
    }

    /// Builds the locations from the preferences' `CurrentSet` ("/Sets/<id>"),
    /// `Sets` and `NetworkServices` values, as `SCPreferencesGetValue` returns
    /// them (and `preferences.plist` keeps them): the one in use first, then
    /// the rest by name. A set lists its services as links into
    /// `NetworkServices` ("/NetworkServices/<id>") and orders them in its
    /// `Network/Global/IPv4/ServiceOrder`; services it doesn't order follow by ID.
    public static func parse(currentSet: String?, sets: [String: Any], services: [String: Any]) -> [NetworkLocation] {
        let current = currentSet.flatMap { $0.split(separator: "/").last.map(String.init) }
        let locations = sets.compactMap { id, value -> NetworkLocation? in
            guard let set = value as? [String: Any] else { return nil }
            let network = set["Network"] as? [String: Any] ?? [:]
            let linked = network["Service"] as? [String: Any] ?? [:]
            let global = (network["Global"] as? [String: Any])?["IPv4"] as? [String: Any]
            let order = (global?["ServiceOrder"] as? [String] ?? []).filter { linked[$0] != nil }
            let ids = order + linked.keys.filter { !order.contains($0) }.sorted()
            let members = ids.compactMap { serviceID -> Service? in
                let link = (linked[serviceID] as? [String: Any])?["__LINK__"] as? String
                let target = link?.split(separator: "/").last.map(String.init) ?? serviceID
                guard let service = services[target] as? [String: Any] else { return nil }
                let interface = service["Interface"] as? [String: Any] ?? [:]
                if (interface["HiddenConfiguration"] as? NSNumber)?.boolValue == true { return nil }
                let device = interface["DeviceName"] as? String
                let name = text(service["UserDefinedName"]) ?? text(interface["UserDefinedName"]) ?? device ?? target
                return Service(name: name, interface: device, isEnabled: service["__INACTIVE__"] == nil)
            }
            return NetworkLocation(id: id, name: text(set["UserDefinedName"]) ?? "Untitled", isCurrent: id == current, services: members)
        }
        return locations.sorted { first, second in
            if first.isCurrent != second.isCurrent { return first.isCurrent }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    private static func text(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The locations on this Mac, or none when the preferences can't be
    /// opened. Opening them takes no lock and changes nothing.
    public static func read() -> [NetworkLocation] {
        guard let preferences = SCPreferencesCreate(nil, "OpenTaskManager" as CFString, nil) else { return [] }
        return parse(
            currentSet: SCPreferencesGetValue(preferences, kSCPrefCurrentSet) as? String,
            sets: SCPreferencesGetValue(preferences, kSCPrefSets) as? [String: Any] ?? [:],
            services: SCPreferencesGetValue(preferences, kSCPrefNetworkServices) as? [String: Any] ?? [:]
        )
    }
}

/// A file share mounted from a server: SMB, NFS, AFP, WebDAV or FTP. Read
/// from the kernel's mount table only, so listing one never sends anything
/// to its server or looks inside it.
public struct NetworkVolume: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case smb, nfs, afp, webdav, ftp

        public var title: String {
            switch self {
            case .smb: "SMB"
            case .nfs: "NFS"
            case .afp: "AFP"
            case .webdav: "WebDAV"
            case .ftp: "FTP"
            }
        }

        /// From `statfs`'s `f_fstypename`; nil for a local or virtual file system.
        public init?(fileSystemType: String) {
            switch fileSystemType {
            case "smbfs", "cifs": self = .smb
            case "nfs": self = .nfs
            case "afpfs": self = .afp
            case "webdav": self = .webdav
            case "ftp": self = .ftp
            default: return nil
            }
        }
    }

    public var id: String { mountPoint }
    public let kind: Kind
    /// The host name or address, without the account or a port.
    public let server: String?
    /// The share, export or path on the server: "Media", "/export/home".
    public let share: String?
    /// The account it was mounted with (never a password). Identifies the user.
    public let account: String?
    public let mountPoint: String
    /// The kernel's figures from the server's last answer (read with
    /// `MNT_NOWAIT`, so they may be minutes old); nil when it has none.
    public let totalBytes: UInt64?
    public let availableBytes: UInt64?
    public let isReadOnly: Bool
    /// Mounted on demand by the automounter.
    public let isAutomounted: Bool
    /// Kept out of Finder's sidebar and desktop (`MNT_DONTBROWSE`).
    public let isHidden: Bool

    public init(kind: Kind, server: String?, share: String?, account: String?, mountPoint: String, totalBytes: UInt64?,
                availableBytes: UInt64?, isReadOnly: Bool = false, isAutomounted: Bool = false, isHidden: Bool = false) {
        self.kind = kind
        self.server = server
        self.share = share
        self.account = account
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isReadOnly = isReadOnly
        self.isAutomounted = isAutomounted
        self.isHidden = isHidden
    }

    /// What Finder calls it: the mount point's last path component, else the share's.
    public var name: String {
        for candidate in [mountPoint, share].compactMap({ $0 }) {
            if let last = candidate.split(separator: "/").last { return String(last) }
        }
        return mountPoint
    }

    /// One `statfs` record from the mount table, as plain values.
    struct MountRecord {
        /// `f_fstypename`: "smbfs", "nfs", "apfs".
        var fileSystemType: String
        /// `f_mntfromname`: where it was mounted from.
        var source: String
        var mountPoint: String
        /// `f_flags`.
        var flags: UInt32 = 0
        /// Sizes in blocks of `blockSize` bytes; zero blocks means the server hasn't said.
        var blocks: UInt64 = 0
        var availableBlocks: UInt64 = 0
        var blockSize: UInt64 = 0
    }

    /// Where a share was mounted from; each part nil when the source doesn't say.
    struct Origin: Equatable {
        var server: String?
        var share: String?
        var account: String?
    }

    /// A share from its mount-table record; nil for anything that isn't
    /// mounted from a server.
    static func parse(_ record: MountRecord) -> NetworkVolume? {
        guard let kind = Kind(fileSystemType: record.fileSystemType) else { return nil }
        let origin = parseSource(record.source)
        func bytes(_ blocks: UInt64) -> UInt64? {
            guard record.blocks > 0, record.blockSize > 0 else { return nil }
            let product = blocks.multipliedReportingOverflow(by: record.blockSize)
            return product.overflow ? nil : product.partialValue
        }
        return NetworkVolume(
            kind: kind, server: origin.server, share: origin.share, account: origin.account, mountPoint: record.mountPoint,
            totalBytes: bytes(record.blocks), availableBytes: bytes(record.availableBlocks),
            isReadOnly: record.flags & UInt32(MNT_RDONLY) != 0,
            isAutomounted: record.flags & UInt32(MNT_AUTOMOUNTED) != 0,
            isHidden: record.flags & UInt32(MNT_DONTBROWSE) != 0
        )
    }

    /// Splits where a share was mounted from: "//user@server/share" (SMB,
    /// AFP), "server:/export" or "[fd00::1]:/export" (NFS), or a URL
    /// ("https://server/dav", "nfs://server/export"). A password in it is
    /// dropped; percent escapes are decoded.
    static func parseSource(_ source: String) -> Origin {
        func decoded(_ text: Substring) -> String? {
            let plain = String(text).removingPercentEncoding ?? String(text)
            return plain.isEmpty ? nil : plain
        }
        if source.contains("://"), let url = URL(string: source) {
            let path = url.path.isEmpty || url.path == "/" ? nil : url.path
            return Origin(server: url.host, share: path, account: url.user.flatMap { decoded(Substring($0)) })
        }
        if source.hasPrefix("//") {
            let rest = source.dropFirst(2)
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = rest[..<slash]
            let share = slash < rest.endIndex ? decoded(rest[rest.index(after: slash)...]) : nil
            guard let at = authority.lastIndex(of: "@") else { return Origin(server: decoded(authority), share: share) }
            // "DOMAIN;user:password": keep the account, never the password.
            let account = authority[..<at].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return Origin(server: decoded(authority[authority.index(after: at)...]), share: share, account: decoded(account))
        }
        if source.hasPrefix("["), let close = source.firstIndex(of: "]") {
            let rest = source[source.index(after: close)...]
            let path = rest.hasPrefix(":") ? decoded(rest.dropFirst()) : nil
            return Origin(server: decoded(source[source.index(after: source.startIndex)..<close]), share: path)
        }
        if let colon = source.firstIndex(of: ":") {
            return Origin(server: decoded(source[..<colon]), share: decoded(source[source.index(after: colon)...]))
        }
        return Origin()
    }
}

/// Lists mounted network shares from the kernel's mount table.
public enum NetworkVolumeReader {
    /// `getfsstat` with `MNT_NOWAIT` returns what the kernel already holds
    /// for each mount, so a share whose server has gone quiet can't hang the
    /// read, and no request reaches any server. Capacities are the server's
    /// last answer.
    public static func read() -> [NetworkVolume] {
        let count = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard count > 0 else { return [] }
        // Room for a mount or two arriving between the calls.
        var mounts = Array(repeating: statfs(), count: count + 4)
        let stride = MemoryLayout.stride(ofValue: mounts[0])
        let filled = mounts.withUnsafeMutableBufferPointer { buffer in
            Int(getfsstat(buffer.baseAddress, Int32(buffer.count * stride), MNT_NOWAIT))
        }
        return mounts.prefix(max(filled, 0)).compactMap { mount in
            func text<T>(_ field: T) -> String {
                withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            return NetworkVolume.parse(NetworkVolume.MountRecord(
                fileSystemType: text(mount.f_fstypename), source: text(mount.f_mntfromname), mountPoint: text(mount.f_mntonname),
                flags: mount.f_flags, blocks: mount.f_blocks, availableBlocks: mount.f_bavail, blockSize: UInt64(mount.f_bsize)
            ))
        }
        .sorted { $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending }
    }
}
