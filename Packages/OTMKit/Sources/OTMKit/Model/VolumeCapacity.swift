/// A volume's capacity in three parts that add up to it, for the Storage
/// page's capacity bars: what's in use, what macOS clears by itself when
/// space runs short (purgeable), and what's free now. Purgeable space counts
/// as available, as Finder counts it.
public struct VolumeCapacity: Sendable, Equatable {
    public let capacity: UInt64
    public let used: UInt64
    /// Nil where the free space wasn't read apart from the purgeable.
    public let purgeable: UInt64?
    public let free: UInt64

    public init(_ volume: VolumeInfo) {
        capacity = volume.totalBytes
        free = min(volume.freeBytes ?? volume.availableBytes, capacity)
        // Never less than what's free: a volume can keep part of its free
        // space back from important use.
        let available = min(max(volume.availableBytes, free), capacity)
        purgeable = volume.freeBytes == nil ? nil : available - free
        used = capacity - available
    }

    /// Free and purgeable together.
    public var available: UInt64 {
        free + (purgeable ?? 0)
    }

    /// A part's share of the capacity; 0 for a volume that reports none.
    public func share(of part: UInt64) -> Double {
        capacity > 0 ? Double(part) / Double(capacity) : 0
    }

    /// "28.8 GB used, 1.2 GB purgeable and 11.1 GB free, of 41.1 GB".
    public var summary: String {
        var parts = ["\(Format.bytes(used)) used"]
        if let purgeable, purgeable > 0 { parts.append("\(Format.bytes(purgeable)) purgeable") }
        parts.append("\(Format.bytes(free)) free")
        let listed = parts.count == 3 ? "\(parts[0]), \(parts[1]) and \(parts[2])" : "\(parts[0]) and \(parts[1])"
        return "\(listed), of \(Format.bytes(capacity))"
    }
}
