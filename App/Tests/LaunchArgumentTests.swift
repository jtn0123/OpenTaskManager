import Foundation
import Testing

@MainActor
struct LaunchArgumentTests {
    @Test func savedAndRegisteredValuesAreNotLaunchRequests() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("start", forKey: "openSpeedTest")
            defaults.set("gpu", forKey: "openResource")
            defaults.register(defaults: ["openPage": "Storage"])
            #expect(LaunchArgument.string("openResource", defaults: defaults) == nil)
            #expect(LaunchArgument.string("openPage", defaults: defaults) == nil)
            #expect(!LaunchArgument.startsTest(on: "gpu", defaults: defaults))
        }
    }

    @Test func argumentDomainWinsAndDoesNotPersist() throws {
        try withIsolatedDefaults { defaults, suite in
            defaults.set("disk", forKey: "openResource")
            defaults.setVolatileDomain(["openSpeedTest": "start", "openResource": "network"], forName: UserDefaults.argumentDomain)
            #expect(LaunchArgument.string("openResource", defaults: defaults) == "network")
            #expect(LaunchArgument.startsTest(on: "network", defaults: defaults))
            #expect(!LaunchArgument.startsTest(on: "cpu", defaults: defaults))
            #expect(defaults.persistentDomain(forName: suite)?["openResource"] as? String == "disk")
            #expect(defaults.persistentDomain(forName: suite)?["openSpeedTest"] == nil)
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            #expect(!LaunchArgument.startsTest(on: "network", defaults: defaults))
        }
    }

    @Test func missingResourceUsesCPUAndNonStringFlagsAreIgnored() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.setVolatileDomain(["openSpeedTest": "start", "openResource": true], forName: UserDefaults.argumentDomain)
            #expect(LaunchArgument.string("openResource", defaults: defaults) == nil)
            #expect(LaunchArgument.startsTest(on: "cpu", defaults: defaults))
            defaults.setVolatileDomain(["openSpeedTest": true], forName: UserDefaults.argumentDomain)
            #expect(!LaunchArgument.startsTest(on: "cpu", defaults: defaults))
        }
    }
}
