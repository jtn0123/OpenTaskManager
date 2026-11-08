import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("otm: \(message)\n".utf8))
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { fail("could not encode JSON") }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
    let fill = String(repeating: " ", count: max(width - clipped.count, 0))
    return right ? fill + clipped : clipped + fill
}
