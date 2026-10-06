@testable import OTMKit
import Testing

struct SMCTests {
    @Test func packsFourCharacterCodes() {
        #expect(SMCCode("PSTR").rawValue == 0x5053_5452)
        #expect(SMCCode("PSTR").description == "PSTR")
        #expect(SMCCode("ui8").description == "ui8 ")
        #expect(SMCCode("flt ") == SMCCode(rawValue: 0x666C_7420))
    }

    @Test func buildsRequestsAtTheClassicOffsets() {
        let info = SMCParamBlock.keyInfoRequest(for: SMCCode("PSTR"))
        #expect(info.bytes.count == 80)
        // The key is a host-order (little-endian) UInt32 at offset 0; the command byte is at 42.
        #expect(Array(info.bytes[0..<4]) == [0x52, 0x54, 0x53, 0x50])
        #expect(info.bytes[42] == 9)

        let read = SMCParamBlock.readRequest(for: SMCCode("PDTR"), size: 4)
        #expect(read.bytes[42] == 5)
        #expect(Array(read.bytes[28..<32]) == [4, 0, 0, 0])
        #expect(SMCParamBlock.readRequest(for: SMCCode("PDTR"), size: 99).dataSize == 32)
    }

    @Test func parsesReplies() {
        // A key-info reply for PSTR: 4 bytes of type "flt ".
        var bytes = [UInt8](repeating: 0, count: 80)
        bytes[28] = 4
        bytes[32...35] = [0x20, 0x74, 0x6C, 0x66]
        bytes[48...51] = [0xEE, 0x59, 0x95, 0x42]
        let reply = SMCParamBlock(bytes: bytes)
        #expect(reply.result == 0)
        #expect(reply.dataSize == 4)
        #expect(reply.dataType == SMCCode("flt "))
        #expect(reply.payload(count: 4) == [0xEE, 0x59, 0x95, 0x42])
        // A wrongly sized buffer becomes an empty block instead of crashing.
        #expect(SMCParamBlock(bytes: [1, 2, 3]).bytes == [UInt8](repeating: 0, count: 80))
    }

    @Test func decodesFloats() throws {
        // PSTR read on an M5 Pro: ee599542 is 74.675644 W.
        let watts = try #require(SMCValueDecoder.decode(type: SMCCode("flt "), bytes: [0xEE, 0x59, 0x95, 0x42], integersLittleEndian: true))
        #expect(abs(watts - 74.675644) < 0.0001)
        #expect(SMCValueDecoder.decode(type: SMCCode("flt "), bytes: [0, 0, 0xC0, 0x7F], integersLittleEndian: true) == nil, "NaN")
        #expect(SMCValueDecoder.decode(type: SMCCode("flt "), bytes: [0, 0], integersLittleEndian: true) == nil)
    }

    @Test func decodesFixedPoint() {
        // sp78: signed, 8 fraction bits. 0x1D80 is 29.5 °C; 0xFF00 is -1.
        #expect(SMCValueDecoder.decode(type: SMCCode("sp78"), bytes: [0x1D, 0x80], integersLittleEndian: true) == 29.5)
        #expect(SMCValueDecoder.decode(type: SMCCode("sp78"), bytes: [0xFF, 0x00], integersLittleEndian: true) == -1)
        // fpe2: unsigned, 2 fraction bits. 0x1F40 is 2000 rpm.
        #expect(SMCValueDecoder.decode(type: SMCCode("fpe2"), bytes: [0x1F, 0x40], integersLittleEndian: false) == 2000)
        // sp96: signed, 6 fraction bits.
        #expect(SMCValueDecoder.decode(type: SMCCode("sp96"), bytes: [0x01, 0x40], integersLittleEndian: false) == 5)
        #expect(SMCValueDecoder.decode(type: SMCCode("fpe2"), bytes: [0x1F], integersLittleEndian: false) == nil)
        #expect(SMCValueDecoder.decode(type: SMCCode("hex_"), bytes: [0x1F, 0x40], integersLittleEndian: false) == nil)
    }

    @Test func decodesIntegersInEitherByteOrder() {
        // B0AV (battery millivolts) on Apple silicon is little-endian: 3d30 is 12349.
        #expect(SMCValueDecoder.decode(type: SMCCode("ui16"), bytes: [0x3D, 0x30], integersLittleEndian: true) == 12349)
        #expect(SMCValueDecoder.decode(type: SMCCode("ui16"), bytes: [0x30, 0x3D], integersLittleEndian: false) == 12349)
        #expect(SMCValueDecoder.decode(type: SMCCode("ui8"), bytes: [0xFF], integersLittleEndian: true) == 255)
        #expect(SMCValueDecoder.decode(type: SMCCode("si8"), bytes: [0xFF], integersLittleEndian: true) == -1)
        #expect(SMCValueDecoder.decode(type: SMCCode("si16"), bytes: [0x18, 0xFC], integersLittleEndian: true) == -1000)
        #expect(SMCValueDecoder.decode(type: SMCCode("si32"), bytes: [0xFF, 0xFF, 0xFC, 0x18], integersLittleEndian: false) == -1000)
        #expect(SMCValueDecoder.decode(type: SMCCode("ui32"), bytes: [0x00, 0x00, 0x0E, 0x2C], integersLittleEndian: false) == 3628)
        #expect(SMCValueDecoder.decode(type: SMCCode("ui32"), bytes: [1, 2, 3], integersLittleEndian: true) == nil)
        #expect(SMCValueDecoder.decode(type: SMCCode("flag"), bytes: [1], integersLittleEndian: true) == 1)
    }
}
