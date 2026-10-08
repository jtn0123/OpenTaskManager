import Foundation

/// A volume in an APFS container, from `diskutil apfs list -plist`.
public struct APFSVolume: Sendable, Codable, Equatable, Identifiable {
    public var id: String { device }
    /// "disk3s5".
    public let device: String
    public let name: String
    /// "System", "Data", "Preboot", "Recovery", "VM", "Update"…; none for
    /// an ordinary volume.
    public let roles: [String]
    /// The space it holds in the container, its snapshots' included.
    public let used: UInt64

    public init(device: String, name: String, roles: [String] = [], used: UInt64) {
        self.device = device
        self.name = name
        self.roles = roles
        self.used = used
    }

    /// Whether the device a volume is mounted from is this volume or a
    /// snapshot of it: the startup disk's system volume runs from
    /// "disk3s1s1", a snapshot of "disk3s1".
    public func holds(device mounted: String) -> Bool {
        if mounted == device { return true }
        let prefix = device + "s"
        guard mounted.hasPrefix(prefix) else { return false }
        let rest = mounted.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Its name, with its role when that says more: "Preboot", "VM",
    /// "Macintosh HD (System)".
    public var title: String {
        let shown = roles.filter { $0 != name }
        return shown.isEmpty ? name : "\(name) (\(shown.joined(separator: ", ")))"
    }
}

/// An APFS container: the space its volumes share.
public struct APFSContainer: Sendable, Codable, Equatable {
    /// "disk3".
    public let reference: String
    public let capacity: UInt64
    public let free: UInt64
    public let volumes: [APFSVolume]

    public init(reference: String, capacity: UInt64, free: UInt64, volumes: [APFSVolume]) {
        self.reference = reference
        self.capacity = capacity
        self.free = free
        self.volumes = volumes
    }

    public var used: UInt64 { capacity > free ? capacity - free : 0 }

    /// The volume mounted from `device`, if it's in this container.
    public func volume(mountedFrom device: String) -> APFSVolume? {
        volumes.first { $0.holds(device: device) }
    }

    /// `diskutil apfs list -plist`'s containers, from what it printed (a
    /// stray line before the plist is ignored); nil if it isn't that list.
    public static func parseList(_ output: String) -> [APFSContainer]? {
        guard let root = PlistOutput.dictionary(in: output), let containers = root["Containers"] as? [[String: Any]] else { return nil }
        return containers.compactMap { container in
            guard let reference = container["ContainerReference"] as? String else { return nil }
            let volumes = (container["Volumes"] as? [[String: Any]] ?? []).compactMap { volume -> APFSVolume? in
                guard let device = volume["DeviceIdentifier"] as? String else { return nil }
                return APFSVolume(device: device, name: volume["Name"] as? String ?? device, roles: volume["Roles"] as? [String] ?? [],
                                  used: PlistOutput.bytes(volume["CapacityInUse"]))
            }
            return APFSContainer(reference: reference, capacity: PlistOutput.bytes(container["CapacityCeiling"]),
                                 free: PlistOutput.bytes(container["CapacityFree"]), volumes: volumes)
        }
    }

    /// The container holding the volume mounted from `device`.
    public static func holding(device: String, in containers: [APFSContainer]) -> APFSContainer? {
        containers.first { $0.volume(mountedFrom: device) != nil }
    }
}

/// An APFS snapshot of a volume, from `diskutil apfs listSnapshots -plist`.
public struct APFSSnapshot: Sendable, Codable, Equatable {
    public let name: String
    /// Whether macOS may remove it when space runs short (Time Machine's
    /// local snapshots are); nil when the list doesn't say.
    public let isPurgeable: Bool?
    /// The mount point of the volume it's a snapshot of.
    public let volume: String

    public init(name: String, isPurgeable: Bool? = nil, volume: String) {
        self.name = name
        self.isPurgeable = isPurgeable
        self.volume = volume
    }

    /// The snapshots in what `diskutil apfs listSnapshots -plist` printed;
    /// nil if it isn't that list.
    public static func parseList(_ output: String, volume: String) -> [APFSSnapshot]? {
        guard let root = PlistOutput.dictionary(in: output), let snapshots = root["Snapshots"] as? [[String: Any]] else { return nil }
        return snapshots.compactMap { snapshot in
            guard let name = snapshot["SnapshotName"] as? String else { return nil }
            return APFSSnapshot(name: name, isPurgeable: snapshot["Purgeable"] as? Bool, volume: volume)
        }
    }
}

/// What could be learned about the snapshots of the volumes a scan covered.
public enum SnapshotListing: Sendable, Equatable {
    /// Read: these (perhaps none).
    case listed([APFSSnapshot])
    /// The list is refused without administrator rights.
    case needsAdmin
    /// The list couldn't be read (the tool failed or took too long).
    case unreadable
    /// The volumes aren't APFS, which keeps snapshots.
    case notAPFS
    /// Only read-only volumes were scanned, such as the startup disk's
    /// sealed system volume, which runs from a snapshot of itself.
    case readOnly

    /// What one run of `diskutil apfs listSnapshots -plist` said: nil
    /// status for a tool that didn't run to the end.
    public static func reading(status: Int32?, output: String, volume: String) -> SnapshotListing {
        if status == 0, let snapshots = APFSSnapshot.parseList(output, volume: volume) { return .listed(snapshots) }
        let text = output.lowercased()
        let refusals = ["must be run as root", "permission denied", "not permitted", "requires root", "privilege", "administrator"]
        return refusals.contains { text.contains($0) } ? .needsAdmin : .unreadable
    }

    /// Several volumes' lists as one: complete only when every one was read.
    public static func combining(_ readings: [SnapshotListing]) -> SnapshotListing {
        if readings.contains(.needsAdmin) { return .needsAdmin }
        if readings.contains(.unreadable) { return .unreadable }
        let lists = readings.compactMap { reading -> [APFSSnapshot]? in
            if case let .listed(snapshots) = reading { return snapshots }
            return nil
        }
        return lists.isEmpty ? .readOnly : .listed(lists.flatMap { $0 })
    }

    /// The snapshots read, or nil when they couldn't be.
    public var snapshots: [APFSSnapshot]? {
        if case let .listed(snapshots) = self { return snapshots }
        return nil
    }

    /// A word for JSON.
    public var state: String {
        switch self {
        case .listed: "listed"
        case .needsAdmin: "needsAdmin"
        case .unreadable: "unreadable"
        case .notAPFS: "notAPFS"
        case .readOnly: "readOnly"
        }
    }
}

/// A plist printed by a tool, perhaps after a stray line or two.
enum PlistOutput {
    static func dictionary(in output: String) -> [String: Any]? {
        guard let start = output.range(of: "<?xml") ?? output.range(of: "<plist") else { return nil }
        let end = output.range(of: "</plist>", options: .backwards).map(\.upperBound) ?? output.endIndex
        guard start.lowerBound < end else { return nil }
        let data = Data(output[start.lowerBound..<end].utf8)
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func bytes(_ value: Any?) -> UInt64 {
        switch value {
        case let number as NSNumber: number.int64Value > 0 ? UInt64(number.int64Value) : 0
        case let text as String: UInt64(text) ?? 0
        default: 0
        }
    }
}
