@testable import OTMKit
import Testing

struct LaunchOptionsTests {
    @Test func readsOnlyStringsWithoutCoercingFlagsOrNumbers() {
        let domain: [String: Any] = ["openPage": "History", "flag": true, "count": 2, "empty": ""]
        #expect(LaunchOptions.string("openPage", in: domain) == "History")
        #expect(LaunchOptions.string("empty", in: domain) == "")
        #expect(LaunchOptions.string("flag", in: domain) == nil)
        #expect(LaunchOptions.string("count", in: domain) == nil)
        #expect(LaunchOptions.string("absent", in: domain) == nil)
    }

    @Test func withoutAResourceOnlyTheCPUStarts() {
        let domain: [String: Any] = ["openSpeedTest": "start"]
        #expect(LaunchOptions.startsTest(on: "cpu", in: domain))
        #expect(!LaunchOptions.startsTest(on: "gpu", in: domain))
        #expect(!LaunchOptions.startsTest(on: "benchmarks", in: domain))
    }

    @Test(arguments: ["cpu", "gpu", "disk", "network", "benchmarks"])
    func onlyTheRequestedResourceStarts(resource: String) {
        let domain: [String: Any] = ["openSpeedTest": "start", "openResource": resource]
        #expect(LaunchOptions.startsTest(on: resource, in: domain))
        for other in ["cpu", "gpu", "disk", "network", "benchmarks"] where other != resource {
            #expect(!LaunchOptions.startsTest(on: other, in: domain))
        }
    }

    @Test(arguments: ["", "Start", "sustained", "stop"])
    func otherTestRequestsDoNotStartTheOrdinaryTest(request: String) {
        let domain: [String: Any] = ["openSpeedTest": request, "openResource": "cpu"]
        #expect(!LaunchOptions.startsTest(on: "cpu", in: domain))
    }

    @Test func missingRequestAndExplicitEmptyResourceDoNotStartTheCPU() {
        #expect(!LaunchOptions.startsTest(on: "cpu", in: [:]))
        #expect(!LaunchOptions.startsTest(on: "cpu", in: ["openSpeedTest": "start", "openResource": ""]))
    }
}
