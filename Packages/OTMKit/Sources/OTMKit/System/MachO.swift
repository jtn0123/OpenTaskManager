import Foundation

/// One architecture in a Mach-O executable, from its header.
public struct MachOSlice: Sendable, Codable, Hashable {
    public let cpuType: Int32
    public let cpuSubtype: Int32

    public init(cpuType: Int32, cpuSubtype: Int32) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
    }

    /// The name `lipo` uses: "arm64", "arm64e", "x86_64".
    public var name: String {
        // The top byte of the subtype holds capability bits, not the subtype.
        let subtype = cpuSubtype & 0x00FF_FFFF
        switch cpuType {
        case MachO.cpuTypeARM64:
            switch subtype {
            case 0: return "arm64"
            case 1: return "arm64v8"
            case 2: return "arm64e"
            case 12: return "arm64e.x1"
            default: return "arm64 (subtype \(subtype))"
            }
        case MachO.cpuTypeIntel64: return subtype == 8 ? "x86_64h" : "x86_64"
        case MachO.cpuTypeIntel: return "i386"
        case MachO.cpuTypeARM64ILP32: return "arm64_32"
        case MachO.cpuTypeARM: return "arm"
        case MachO.cpuTypePowerPC: return "ppc"
        case MachO.cpuTypePowerPC64: return "ppc64"
        default: return "cpu \(cpuType)"
        }
    }

    public var isARM64: Bool { cpuType == MachO.cpuTypeARM64 }
    public var isIntel64: Bool { cpuType == MachO.cpuTypeIntel64 }

    private enum CodingKeys: String, CodingKey { case cpuType, cpuSubtype, name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cpuType: try container.decode(Int32.self, forKey: .cpuType),
                  cpuSubtype: try container.decode(Int32.self, forKey: .cpuSubtype))
    }

    /// Writes the name beside the numbers, for anyone reading the JSON.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpuType, forKey: .cpuType)
        try container.encode(cpuSubtype, forKey: .cpuSubtype)
        try container.encode(name, forKey: .name)
    }
}

/// Reads which architectures a Mach-O file holds, thin or fat, from its
/// first few kilobytes. Nothing is loaded or executed.
public enum MachO {
    static let abi64: Int32 = 0x0100_0000
    public static let cpuTypeIntel: Int32 = 7
    public static let cpuTypeIntel64: Int32 = cpuTypeIntel | abi64
    public static let cpuTypeARM: Int32 = 12
    public static let cpuTypeARM64: Int32 = cpuTypeARM | abi64
    public static let cpuTypeARM64ILP32: Int32 = cpuTypeARM | 0x0200_0000
    public static let cpuTypePowerPC: Int32 = 18
    public static let cpuTypePowerPC64: Int32 = cpuTypePowerPC | abi64

    /// The first word of each kind of file, read big-endian.
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF
    static let thinMagic: UInt32 = 0xFEED_FACE
    static let thinMagic64: UInt32 = 0xFEED_FACF

    /// Enough bytes for a fat header listing far more slices than any real file.
    public static let headerLength = 4096

    /// Java class files also start with 0xCAFEBABE, followed by their version
    /// (45 or more) where a fat file has its slice count. Real fat files hold
    /// a handful of slices, so a count this high means it isn't one.
    static let maximumSlices = 32

    /// The architectures in a Mach-O header, or nil when the bytes aren't
    /// Mach-O at all (a shell script, a Java class) or stop short.
    public static func slices(in data: Data) -> [MachOSlice]? {
        let bytes = [UInt8](data.prefix(headerLength))
        guard bytes.count >= 8 else { return nil }
        let magic = word(bytes, at: 0, bigEndian: true)
        switch magic {
        case fatMagic, fatMagic64:
            let count = Int(word(bytes, at: 4, bigEndian: true))
            // fat_arch is 20 bytes; fat_arch_64 has 64-bit offset and size and a reserved word.
            let stride = magic == fatMagic64 ? 32 : 20
            guard (1...maximumSlices).contains(count), 8 + count * stride <= bytes.count else { return nil }
            return (0..<count).map { index in
                let entry = 8 + index * stride
                return MachOSlice(cpuType: Int32(bitPattern: word(bytes, at: entry, bigEndian: true)),
                                  cpuSubtype: Int32(bitPattern: word(bytes, at: entry + 4, bigEndian: true)))
            }
        case thinMagic, thinMagic64:
            // Stored big-endian: PowerPC.
            return thin(bytes, bigEndian: true, is64Bit: magic == thinMagic64)
        default:
            let little = word(bytes, at: 0, bigEndian: false)
            guard little == thinMagic || little == thinMagic64 else { return nil }
            return thin(bytes, bigEndian: false, is64Bit: little == thinMagic64)
        }
    }

    /// Reads the header of the file at `path`; nil when it can't be read or isn't Mach-O.
    public static func slices(atPath path: String) -> [MachOSlice]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLength) else { return nil }
        return slices(in: data)
    }

    /// A single-architecture header: mach_header is 28 bytes, mach_header_64 is 32.
    private static func thin(_ bytes: [UInt8], bigEndian: Bool, is64Bit: Bool) -> [MachOSlice]? {
        guard bytes.count >= (is64Bit ? 32 : 28) else { return nil }
        return [MachOSlice(cpuType: Int32(bitPattern: word(bytes, at: 4, bigEndian: bigEndian)),
                           cpuSubtype: Int32(bitPattern: word(bytes, at: 8, bigEndian: bigEndian)))]
    }

    private static func word(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> UInt32 {
        let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return bigEndian ? value : value.byteSwapped
    }
}
