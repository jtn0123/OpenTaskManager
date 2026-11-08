import Foundation

/// The stored form of a setting's default, for checking the registry without erasing its value's type.
public enum SettingDefault: Sendable, Equatable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case date(Date)
    case strings([String: String])
    case stringLists([String: [String]])
    case absent
}

public struct SettingDescriptor: Sendable, Equatable {
    public let key: String
    public let valueType: String
    public let storedType: String
    public let defaultValue: SettingDefault
    public let meaning: String
}

/// A property-list value, read and written with the same encoding as the original defaults callers.
public protocol SettingStorage: Sendable {
    static func readSetting(from defaults: UserDefaults, key: String) -> Self?
    func writeSetting(to defaults: UserDefaults, key: String)
    var settingDefault: SettingDefault { get }
}

extension Bool: SettingStorage {
    public static func readSetting(from defaults: UserDefaults, key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }
    public func writeSetting(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
    public var settingDefault: SettingDefault { .bool(self) }
}

extension Int: SettingStorage {
    public static func readSetting(from defaults: UserDefaults, key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }
    public func writeSetting(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
    public var settingDefault: SettingDefault { .integer(self) }
}

extension Double: SettingStorage {
    public static func readSetting(from defaults: UserDefaults, key: String) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }
    public func writeSetting(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
    public var settingDefault: SettingDefault { .double(self) }
}

extension String: SettingStorage {
    public static func readSetting(from defaults: UserDefaults, key: String) -> String? { defaults.string(forKey: key) }
    public func writeSetting(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
    public var settingDefault: SettingDefault { .string(self) }
}

extension Date: SettingStorage {
    public static func readSetting(from defaults: UserDefaults, key: String) -> Date? { defaults.object(forKey: key) as? Date }
    public func writeSetting(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
    public var settingDefault: SettingDefault { .date(self) }
}

extension Optional: SettingStorage where Wrapped: SettingStorage {
    public static func readSetting(from defaults: UserDefaults, key: String) -> Self? {
        // Optional capability flags used an object cast, so absence stays unknown rather than false.
        .some(defaults.object(forKey: key) as? Wrapped)
    }
    public func writeSetting(to defaults: UserDefaults, key: String) {
        if let value = self { value.writeSetting(to: defaults, key: key) } else { defaults.removeObject(forKey: key) }
    }
    public var settingDefault: SettingDefault { self?.settingDefault ?? .absent }
}

/// The two benchmark dictionaries are property lists, never JSON blobs.
public protocol SettingDictionaryValue: Sendable {
    static func describeSettingDictionary(_ dictionary: [String: Self]) -> SettingDefault
}

extension String: SettingDictionaryValue {
    public static func describeSettingDictionary(_ dictionary: [String: String]) -> SettingDefault { .strings(dictionary) }
}

extension Array: SettingDictionaryValue where Element == String {
    public static func describeSettingDictionary(_ dictionary: [String: [String]]) -> SettingDefault { .stringLists(dictionary) }
}

extension Dictionary: SettingStorage where Key == String, Value: SettingDictionaryValue {
    public static func readSetting(from defaults: UserDefaults, key: String) -> Self? { defaults.dictionary(forKey: key) as? Self }
    public func writeSetting(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
    public var settingDefault: SettingDefault { Value.describeSettingDictionary(self) }
}

/// A setting's value and its existing stored form. Only OTMKit can declare keys; callers use the registry.
public struct SettingKey<Value: Sendable, Stored: SettingStorage>: Sendable {
    public let key: String
    public let defaultValue: Value
    public let meaning: String
    private let encode: @Sendable (Value) -> Stored
    private let decode: @Sendable (Stored) -> Value?

    init(_ key: String, default defaultValue: Value, meaning: String) where Value == Stored {
        self.key = key
        self.defaultValue = defaultValue
        self.meaning = meaning
        encode = { $0 }
        decode = { $0 }
    }

    init(_ key: String, default defaultValue: Value, meaning: String) where Value: RawRepresentable, Stored == Value.RawValue {
        self.key = key
        self.defaultValue = defaultValue
        self.meaning = meaning
        encode = { $0.rawValue }
        decode = { Value(rawValue: $0) }
    }

    public var storedDefault: Stored { encode(defaultValue) }
    public func value(from stored: Stored) -> Value { decode(stored) ?? defaultValue }
    public func storedValue(_ value: Value) -> Stored { encode(value) }

    public func get(in defaults: UserDefaults = .standard) -> Value {
        Stored.readSetting(from: defaults, key: key).flatMap(decode) ?? defaultValue
    }

    public func set(_ value: Value, in defaults: UserDefaults = .standard) {
        encode(value).writeSetting(to: defaults, key: key)
    }

    public func remove(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    public var descriptor: SettingDescriptor {
        SettingDescriptor(key: key, valueType: String(describing: Value.self), storedType: String(describing: Stored.self),
                          defaultValue: storedDefault.settingDefault, meaning: meaning)
    }
}
