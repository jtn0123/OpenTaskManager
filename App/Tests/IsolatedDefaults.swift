import Foundation
import Testing

/// Each test owns a suite, removed on exit, so parallel tests and the user's
/// saved settings stay out of each other's way. Launch arguments are passed
/// as dictionaries: the argument domain belongs to the whole test process.
@MainActor
func withIsolatedDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
    let name = "OpenTaskManagerLogicTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults, name)
}
