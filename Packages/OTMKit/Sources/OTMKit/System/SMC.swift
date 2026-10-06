import Foundation
import IOKit

/// A four-character SMC code such as the key "PSTR" or the type "flt ",
/// packed big-endian into a `UInt32` the way the SMC expects it.
struct SMCCode: Hashable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Takes the first four ASCII bytes, padding short codes with spaces ("ui8" becomes "ui8 ").
    init(_ text: String) {
        let bytes = Array(text.utf8.prefix(4)) + [UInt8](repeating: 0x20, count: max(0, 4 - text.utf8.count))
        rawValue = bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: rawValue >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The 80-byte parameter block the AppleSMC user client exchanges through
/// `IOConnectCallStructMethod`. It is kept as raw bytes at fixed offsets
/// (the C layout of the classic `SMCKeyData` struct, including its padding)
/// instead of a Swift struct, whose layout the compiler is free to change.
struct SMCParamBlock: Equatable {
    static let size = 80
    /// `kSMCHandleYPCEvent`, the user client's only struct method.
    static let selector: UInt32 = 2

    /// 4: version (6 bytes), 12: power-limit data (16 bytes), 36: attributes,
    /// 41: status, 44: a 32-bit argument. None of those are needed here.
    enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let payload = 48
    }

    enum Command: UInt8 {
        case readKey = 5
        case keyInfo = 9
    }

    static let maxPayload = 32

    var bytes: [UInt8]

    init(bytes: [UInt8] = [UInt8](repeating: 0, count: SMCParamBlock.size)) {
        self.bytes = bytes.count == Self.size ? bytes : [UInt8](repeating: 0, count: Self.size)
    }

    static func keyInfoRequest(for key: SMCCode) -> SMCParamBlock {
        var block = SMCParamBlock()
        block.setUInt32(key.rawValue, at: Offset.key)
        block.bytes[Offset.command] = Command.keyInfo.rawValue
        return block
    }

    static func readRequest(for key: SMCCode, size: Int) -> SMCParamBlock {
        var block = SMCParamBlock()
        block.setUInt32(key.rawValue, at: Offset.key)
        block.setUInt32(UInt32(min(max(size, 0), maxPayload)), at: Offset.dataSize)
        block.bytes[Offset.command] = Command.readKey.rawValue
        return block
    }

    /// Non-zero when the SMC rejected the request (for example, an unknown key).
    var result: UInt8 { bytes[Offset.result] }
    var dataSize: Int { Int(uint32(at: Offset.dataSize)) }
    var dataType: SMCCode { SMCCode(rawValue: uint32(at: Offset.dataType)) }

    func payload(count: Int) -> [UInt8] {
        let count = min(max(count, 0), Self.maxPayload)
        return Array(bytes[Offset.payload..<Offset.payload + count])
    }

    // The struct's integer fields are in host byte order (little-endian on every supported Mac).
    private mutating func setUInt32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    private func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}

/// Turns raw SMC payloads into numbers.
enum SMCValueDecoder {
    /// Decodes the numeric SMC types this app reads. `flt ` is an IEEE float
    /// stored little-endian. `fpXY`/`spXY` are big-endian unsigned/signed
    /// fixed point with Y (hex) fraction bits, the classic Intel formats.
    /// Plain integers are little-endian on Apple silicon and big-endian on
    /// Intel Macs, so the caller says which.
    static func decode(type: SMCCode, bytes: [UInt8], integersLittleEndian: Bool) -> Double? {
        let name = type.description
        switch name {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let value = Double(Float(bitPattern: unsigned(bytes, littleEndian: true)))
            return value.isFinite ? value : nil
        case "flag":
            return bytes.count == 1 ? Double(bytes[0] != 0 ? 1 : 0) : nil
        case "ui8 ", "ui16", "ui32", "ui64":
            guard [1, 2, 4, 8].contains(bytes.count) else { return nil }
            return Double(unsigned64(bytes, littleEndian: integersLittleEndian))
        case "si8 ", "si16", "si32", "si64":
            guard [1, 2, 4, 8].contains(bytes.count) else { return nil }
            return Double(signed64(bytes, littleEndian: integersLittleEndian))
        default:
            return fixedPoint(name, bytes)
        }
    }

    private static func fixedPoint(_ name: String, _ bytes: [UInt8]) -> Double? {
        let characters = Array(name)
        guard bytes.count == 2, characters.count == 4, name.hasPrefix("fp") || name.hasPrefix("sp"),
              let fractionBits = Int(String(characters[3]), radix: 16) else { return nil }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let value = name.hasPrefix("sp") ? Double(Int16(bitPattern: raw)) : Double(raw)
        return value / Double(1 << fractionBits)
    }

    private static func unsigned(_ bytes: [UInt8], littleEndian: Bool) -> UInt32 {
        UInt32(truncatingIfNeeded: unsigned64(bytes, littleEndian: littleEndian))
    }

    private static func unsigned64(_ bytes: [UInt8], littleEndian: Bool) -> UInt64 {
        let ordered = littleEndian ? bytes.reversed() : bytes
        return ordered.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private static func signed64(_ bytes: [UInt8], littleEndian: Bool) -> Int64 {
        let raw = unsigned64(bytes, littleEndian: littleEndian)
        let shift = UInt64(64 - 8 * bytes.count)
        // Sign-extend from the value's own width.
        return Int64(bitPattern: raw << shift) >> shift
    }
}

/// A connection to the AppleSMC user client, opened once and closed on
/// deinit. Reading needs no special privileges. Key metadata is cached, so
/// each read after the first is a single kernel call.
final class SMCConnection {
    private struct KeyInfo {
        let size: Int
        let type: SMCCode
    }

    private var connection: io_connect_t = 0
    /// nil values remember keys this SMC doesn't have, so they aren't retried every tick.
    private var keyInfo: [SMCCode: KeyInfo?] = [:]
    private let integersLittleEndian: Bool

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess, connection != 0 else { return nil }
        integersLittleEndian = Sysctl.int("hw.optional.arm64") == 1
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Reads a numeric key, or nil when the key is missing, unreadable or not a number.
    func double(_ key: String) -> Double? {
        let code = SMCCode(key)
        guard let info = info(for: code),
              let reply = call(.readRequest(for: code, size: info.size)), reply.result == 0 else { return nil }
        return SMCValueDecoder.decode(type: info.type, bytes: reply.payload(count: info.size),
                                      integersLittleEndian: integersLittleEndian)
    }

    private func info(for key: SMCCode) -> KeyInfo? {
        if let cached = keyInfo[key] { return cached }
        var info: KeyInfo?
        if let reply = call(.keyInfoRequest(for: key)), reply.result == 0,
           reply.dataSize > 0, reply.dataSize <= SMCParamBlock.maxPayload {
            info = KeyInfo(size: reply.dataSize, type: reply.dataType)
        }
        keyInfo[key] = .some(info)
        return info
    }

    private func call(_ request: SMCParamBlock) -> SMCParamBlock? {
        var output = [UInt8](repeating: 0, count: SMCParamBlock.size)
        var outputSize = SMCParamBlock.size
        let status = request.bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                IOConnectCallStructMethod(connection, SMCParamBlock.selector, input.baseAddress, SMCParamBlock.size,
                                          buffer.baseAddress, &outputSize)
            }
        }
        guard status == kIOReturnSuccess, outputSize == SMCParamBlock.size else { return nil }
        return SMCParamBlock(bytes: output)
    }
}
