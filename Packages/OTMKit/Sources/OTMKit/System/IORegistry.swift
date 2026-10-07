import Foundation
import IOKit

/// Helpers for walking the IORegistry. All returned dictionaries are plain
/// Foundation values so callers never touch retained CF objects directly.
enum IORegistry {
    /// Calls `body` with each service matching `className`. The service object
    /// is released after `body` returns.
    static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) {
        forEachService(matchingDictionary: IOServiceMatching(className), body)
    }

    /// Like `forEachService(matching:)`, but matches the entry's name
    /// (device-tree nodes such as "pmgr") instead of its class.
    static func forEachService(named name: String, _ body: (io_registry_entry_t) -> Void) {
        forEachService(matchingDictionary: IOServiceNameMatching(name), body)
    }

    private static func forEachService(matchingDictionary: CFMutableDictionary?, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator) == KERN_SUCCESS else {
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

    /// The whole physical disk that `bsdName` lives on, following APFS
    /// volumes, containers and partitions down to the media an
    /// `IOBlockStorageDriver` publishes: "disk3s1s1" becomes "disk0". Nil for
    /// disk images and anything else without a block storage driver below it.
    static func physicalDisk(forBSDName bsdName: String) -> String? {
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        // Registry chains are about a dozen deep; the bound guards against a loop.
        for _ in 0..<32 {
            guard let parent = parent(of: entry) else { return nil }
            if IOObjectConformsTo(entry, "IOMedia") != 0, IOObjectConformsTo(parent, "IOBlockStorageDriver") != 0 {
                IOObjectRelease(parent)
                return property("BSD Name", of: entry) as? String
            }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
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
