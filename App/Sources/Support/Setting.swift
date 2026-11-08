import OTMKit
import SwiftUI

/// A registered setting, observed by SwiftUI through AppStorage. Defaults and raw encodings come from its key.
@propertyWrapper
struct Setting<Value: Sendable, Stored: SettingStorage>: DynamicProperty {
    @AppStorage private var storage: Stored
    private let key: SettingKey<Value, Stored>

    init(_ key: SettingKey<Value, Stored>) where Stored == Bool {
        self.key = key
        _storage = AppStorage(wrappedValue: key.storedDefault, key.key)
    }

    init(_ key: SettingKey<Value, Stored>) where Stored == Int {
        self.key = key
        _storage = AppStorage(wrappedValue: key.storedDefault, key.key)
    }

    init(_ key: SettingKey<Value, Stored>) where Stored == Double {
        self.key = key
        _storage = AppStorage(wrappedValue: key.storedDefault, key.key)
    }

    init(_ key: SettingKey<Value, Stored>) where Stored == String {
        self.key = key
        _storage = AppStorage(wrappedValue: key.storedDefault, key.key)
    }

    var wrappedValue: Value {
        get { key.value(from: storage) }
        nonmutating set { storage = key.storedValue(newValue) }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
