import Foundation
import Testing

/// Each test owns a suite, including its argument domain. Removing it on
/// exit keeps parallel tests and the user's saved settings out of each other's way.
@MainActor
func withIsolatedDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
    let name = "OpenTaskManagerLogicTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    defer {
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.removePersistentDomain(forName: name)
    }
    try body(defaults, name)
}
