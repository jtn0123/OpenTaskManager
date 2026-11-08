import Foundation

/// Selects complete top-level values without decoding unrelated threads or images.
/// An incomplete tail is left out, so the reader can keep a fixed byte budget.
enum DiagnosticJSONFields {
    static func read(_ data: Data, keeping keys: Set<String>, processPID: Int32? = nil) -> Data {
        let bytes = Array(data)
        var index = 0
        var selected: [Data] = []
        skipSpace(bytes, at: &index)
        guard index < bytes.count, bytes[index] == 123 else { return Data("{}".utf8) }
        index += 1
        while index < bytes.count {
            skipSpace(bytes, at: &index)
            if index < bytes.count, bytes[index] == 44 { index += 1; skipSpace(bytes, at: &index) }
            let start = index
            guard index < bytes.count, bytes[index] == 34, let keyEnd = valueEnd(bytes, from: index) else { break }
            let key = try? JSONDecoder().decode(String.self, from: Data(bytes[index..<keyEnd]))
            index = keyEnd
            skipSpace(bytes, at: &index)
            guard index < bytes.count, bytes[index] == 58 else { break }
            index += 1
            skipSpace(bytes, at: &index)
            if key == "processes", let processPID,
               let entry = matchingProcess(bytes, from: index, pid: processPID) {
                var field = Data("\"jetsamProcess\":".utf8)
                field.append(entry)
                selected.append(field)
            }
            guard let end = valueEnd(bytes, from: index) else { break }
            if let key, keys.contains(key) { selected.append(Data(bytes[start..<end])) }
            index = end
        }
        var result = Data("{".utf8)
        for (index, field) in selected.enumerated() {
            if index > 0 { result.append(44) }
            result.append(field)
        }
        result.append(125)
        return result
    }

    private static func matchingProcess(_ bytes: [UInt8], from start: Int, pid: Int32) -> Data? {
        guard start < bytes.count, bytes[start] == 91 else { return nil }
        var index = start + 1
        while index < bytes.count {
            skipSpace(bytes, at: &index)
            if index < bytes.count, bytes[index] == 44 { index += 1; skipSpace(bytes, at: &index) }
            guard let end = valueEnd(bytes, from: index), end > index else { break }
            let fields = read(Data(bytes[index..<end]), keeping: ["pid", "name", "procName", "procPath", "reason"])
            if let entry = try? JSONDecoder().decode(JetsamIdentity.self, from: fields), entry.pid == pid,
               let reason = entry.reason, !reason.isEmpty { return fields }
            index = end
        }
        return nil
    }

    private struct JetsamIdentity: Decodable {
        let pid: Int32
        let reason: String?
    }

    private static func skipSpace(_ bytes: [UInt8], at index: inout Int) {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private static func valueEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        var index = start
        var depth = 0
        var quoted = false
        var escaped = false
        let complex = [123, 91, 34].contains(bytes[start])
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 {
                    quoted = false
                    if depth == 0 { return index + 1 }
                }
            } else {
                if byte == 34 { quoted = true }
                if byte == 123 || byte == 91 { depth += 1 }
                if byte == 125 || byte == 93 {
                    if depth == 0 { return index }
                    depth -= 1
                    if depth == 0 { return index + 1 }
                }
                if !complex, depth == 0, byte == 44 || [9, 10, 13, 32].contains(byte) { return index }
            }
            index += 1
        }
        return nil
    }
}
