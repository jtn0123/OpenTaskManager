import Foundation
import IOKit

/// Helpers for walking the IORegistry. All returned dictionaries are plain
/// Foundation values so callers never touch retained CF objects directly.
enum IORegistry {
    /// Calls `body` with each service matching `className`. The service object
    /// is released after `body` returns.
    static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        forEach(iterator, body)
    }

    static func forEachChild(of entry: io_registry_entry_t, plane: String = kIOServicePlane, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        forEach(iterator, body)
    }

    static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func parent(of entry: io_registry_entry_t, plane: String = kIOServicePlane) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, plane, &parent) == KERN_SUCCESS else { return nil }
        return parent
    }

    static func entry(path: String) -> io_registry_entry_t? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        return entry == 0 ? nil : entry
    }

    private static func forEach(_ iterator: io_iterator_t, _ body: (io_registry_entry_t) -> Void) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func uint64(_ key: String) -> UInt64? {
        (self[key] as? NSNumber)?.uint64Value
    }

    func int(_ key: String) -> Int? {
        (self[key] as? NSNumber)?.intValue
    }

    func double(_ key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        (self[key] as? NSNumber)?.boolValue
    }

    func string(_ key: String) -> String? {
        if let string = self[key] as? String { return string }
        // Device-tree strings arrive as NUL-terminated Data.
        if let data = self[key] as? Data {
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        return nil
    }

    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }
}
