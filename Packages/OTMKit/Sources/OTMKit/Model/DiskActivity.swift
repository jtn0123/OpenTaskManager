import Foundation

/// A compact selection of the current physical disk names (disk0, disk2,
/// etc.). All follows devices appearing and disappearing; disk images never
/// become hardware activity lights.
public struct DiskLightSelection: RawRepresentable, Sendable, Equatable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let all = Self(rawValue: "all")
    public var isAll: Bool { rawValue == "all" }
    public var names: Set<String> { Set(rawValue.split(separator: ",").map(String.init)) }
    public func contains(_ name: String) -> Bool { isAll || names.contains(name) }

    public mutating func toggle(_ name: String) {
        var picked = isAll ? Set<String>() : names
        if !picked.insert(name).inserted { picked.remove(name) }
        rawValue = picked.sorted().joined(separator: ",")
    }
}

public struct DiskActivityLight: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let reading: Bool
    public let writing: Bool

    public static func readings(_ disks: [DiskSample], selection: DiskLightSelection, paused: Bool) -> [Self] {
        disks.filter { !$0.isDiskImage && selection.contains($0.bsdName) }.map { disk in
            Self(id: disk.bsdName, name: disk.name ?? disk.model ?? disk.bsdName,
                 reading: !paused && disk.readBytesPerSecond.isFinite && disk.readBytesPerSecond > 0,
                 writing: !paused && disk.writeBytesPerSecond.isFinite && disk.writeBytesPerSecond > 0)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
