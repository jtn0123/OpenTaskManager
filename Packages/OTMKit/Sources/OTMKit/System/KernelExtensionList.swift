import Foundation
import IOKit
import IOKit.kext

/// Lists the kexts loaded in the kernel.
enum KernelExtensionList {
    /// Only what the page shows. Asking for everything adds each kext's C++
    /// classes and takes ten times as long.
    static let infoKeys = [
        "CFBundleIdentifier", "CFBundleVersion", "OSBundlePath", "OSBundleLoadTag", "OSBundleRetainCount",
        "OSBundleLoadAddress", "OSBundleLoadSize", "OSBundleWiredSize", "OSBundleUUID", "OSBundleDependencies",
        "OSBundleStarted", "OSBundleIsInterface", "OSKernelResource",
    ]

    /// Asks the kernel through IOKit's `KextManagerCopyLoadedKextInfo`, which
    /// takes about 20 ms and also gives each kext's path. If that call ever
    /// fails, `kmutil showloaded` has the rest. Nil when neither works.
    static func read() -> [KernelExtension]? {
        if let info = KextManagerCopyLoadedKextInfo(nil, infoKeys as CFArray)?.takeRetainedValue() as? [String: Any],
           !info.isEmpty {
            return parse(loadedInfo: info)
        }
        return CommandRunner.run("/usr/bin/kmutil", ["showloaded", "--list-only"], timeout: 10).map(parse(kmutil:))
    }

    /// Reads `KextManagerCopyLoadedKextInfo`'s dictionary, keyed by bundle ID.
    /// The kernel itself and the monitors beside it (sptm, txm) are kernel
    /// resources without being interfaces; kmutil leaves them out, and so does this.
    static func parse(loadedInfo: [String: Any]) -> [KernelExtension] {
        loadedInfo.compactMap { key, value -> KernelExtension? in
            guard let info = value as? [String: Any], let tag = number(info["OSBundleLoadTag"]) else { return nil }
            let isInterface = info["OSBundleIsInterface"] as? Bool ?? false
            if key == "__kernel__" || (info["OSKernelResource"] as? Bool == true && !isInterface) { return nil }
            let address = number(info["OSBundleLoadAddress"]).map { UInt64(bitPattern: $0) } ?? 0
            return KernelExtension(
                loadTag: Int(tag),
                bundleID: info["CFBundleIdentifier"] as? String ?? key,
                version: info["CFBundleVersion"] as? String,
                references: number(info["OSBundleRetainCount"]).map(Int.init) ?? 0,
                loadAddress: address == 0 ? nil : address,
                size: number(info["OSBundleLoadSize"]).map { UInt64(bitPattern: $0) } ?? 0,
                wiredSize: number(info["OSBundleWiredSize"]).map { UInt64(bitPattern: $0) } ?? 0,
                uuid: (info["OSBundleUUID"] as? Data).flatMap(uuidString),
                linkedAgainst: (info["OSBundleDependencies"] as? [Any] ?? []).compactMap { number($0).map(Int.init) },
                path: (info["OSBundlePath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isInterface: isInterface,
                isStarted: info["OSBundleStarted"] as? Bool ?? true
            )
        }
        .sorted { $0.loadTag < $1.loadTag }
    }

    /// Reads `kmutil showloaded --list-only`. Each row is the index, refs,
    /// address, size and wired size, then `bundleID (version) UUID <linked tags>`.
    /// The header, kmutil's "No variant specified" note and anything else
    /// that doesn't start with two numbers is skipped.
    static func parse(kmutil output: String) -> [KernelExtension] {
        output.split(separator: "\n").compactMap { line -> KernelExtension? in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let tag = Int(fields[0]), let references = Int(fields[1]),
                  let address = hex(fields[2]), let size = hex(fields[3]), let wired = hex(fields[4]) else { return nil }
            var rest = Substring(fields[5])
            var linked: [Int] = []
            if let open = rest.lastIndex(of: "<"), let close = rest.lastIndex(of: ">"), open < close {
                linked = rest[rest.index(after: open) ..< close].split(separator: " ").compactMap { Int($0) }
                rest = rest[..<open]
            }
            let words = rest.split(separator: " ")
            guard let bundleID = words.first else { return nil }
            var version: String?
            var uuid: String?
            if let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
                version = String(rest[rest.index(after: open) ..< close])
                uuid = rest[rest.index(after: close)...].split(separator: " ").first.map(String.init)
            }
            return KernelExtension(loadTag: tag, bundleID: String(bundleID), version: version, references: references,
                                   loadAddress: address == 0 ? nil : address, size: size, wiredSize: wired,
                                   uuid: uuid, linkedAgainst: linked, path: nil,
                                   isInterface: address == 0 && size == 0, isStarted: true)
        }
    }

    private static func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    /// "0xfffffe0007144000" or "0".
    private static func hex<S: StringProtocol>(_ text: S) -> UInt64? {
        text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }

    private static func uuidString(_ data: Data) -> String? {
        guard data.count == 16 else { return nil }
        let bytes = Array(data)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}
