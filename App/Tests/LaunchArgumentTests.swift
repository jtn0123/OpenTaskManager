import Foundation
import Testing

@MainActor
struct LaunchArgumentTests {
    @Test func savedValuesAreNotLaunchRequests() throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("start", forKey: "openSpeedTest")
            defaults.set("gpu", forKey: "openResource")
            defaults.register(defaults: ["openPage": "Storage"])
            #expect(LaunchArgument.string("openResource", in: [:]) == nil)
            #expect(LaunchArgument.string("openPage", in: [:]) == nil)
            #expect(!LaunchArgument.startsTest(on: "gpu", in: [:]))
            // The run's own domain holds only its command line, which names none of these.
            #expect(LaunchArgument.domain["openResource"] == nil)
            #expect(LaunchArgument.domain["openSpeedTest"] == nil)
        }
    }

    @Test func argumentsNameTheDetailWhoseTestStarts() {
        let arguments: [String: Any] = ["openSpeedTest": "start", "openResource": "network"]
        #expect(LaunchArgument.string("openResource", in: arguments) == "network")
        #expect(LaunchArgument.startsTest(on: "network", in: arguments))
        #expect(!LaunchArgument.startsTest(on: "cpu", in: arguments))
        #expect(!LaunchArgument.startsTest(on: "network", in: [:]))
    }

    @Test func missingResourceUsesCPUAndNonStringFlagsAreIgnored() {
        let noResource: [String: Any] = ["openSpeedTest": "start", "openResource": true]
        #expect(LaunchArgument.string("openResource", in: noResource) == nil)
        #expect(LaunchArgument.startsTest(on: "cpu", in: noResource))
        #expect(!LaunchArgument.startsTest(on: "cpu", in: ["openSpeedTest": true]))
    }
}
