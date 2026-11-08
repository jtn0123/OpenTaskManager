import Foundation
import OTMKit
import Testing

private actor ReleaseFetchCounter {
    var count = 0
    func response(failing: Bool = false) throws -> ReleaseHTTPResponse {
        count += 1
        if failing { throw URLError(.notConnectedToInternet) }
        return ReleaseHTTPResponse(status: 404, data: Data())
    }
}

@MainActor
struct UpdateCheckStoreTests {
    @Test func automaticChecksDefaultOffAndManualChecksStillWork() async throws {
        let name = "OTM-UpdateTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let counter = ReleaseFetchCounter()
        let store = UpdateCheckStore(defaults: defaults, currentVersion: "0.1.0", fetch: { try await counter.response() })
        await store.check(automatic: true)
        #expect(await counter.count == 0)
        await store.check()
        #expect(await counter.count == 1)
        #expect(store.state == .checked(.noPublicRelease))
        #expect(store.lastChecked != nil)
    }

    @Test func failedAutomaticAttemptIsThrottledAcrossStoreInstances() async throws {
        let name = "OTM-UpdateTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        Settings.automaticUpdateChecks.set(true, in: defaults)
        let date = Date(timeIntervalSince1970: 100_000)
        let counter = ReleaseFetchCounter()
        let store = UpdateCheckStore(defaults: defaults, currentVersion: "0.1.0", now: { date },
                                     fetch: { try await counter.response(failing: true) })
        await store.check(automatic: true)
        #expect(await counter.count == 1)
        #expect(store.lastChecked == nil)
        let reopened = UpdateCheckStore(defaults: defaults, currentVersion: "0.1.0", now: { date.addingTimeInterval(10) },
                                        fetch: { try await counter.response() })
        await reopened.check(automatic: true)
        #expect(await counter.count == 1)
        await reopened.check()
        #expect(await counter.count == 2)
        let tomorrow = UpdateCheckStore(defaults: defaults, currentVersion: "0.1.0", now: { date.addingTimeInterval(86_410) },
                                        fetch: { try await counter.response() })
        await tomorrow.check(automatic: true)
        #expect(await counter.count == 3)
    }

    @Test func invalidBuildAndPreviewDoNotPersistOrAutomaticallyFetch() async throws {
        let name = "OTM-UpdateTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let counter = ReleaseFetchCounter()
        let invalid = UpdateCheckStore(defaults: defaults, currentVersion: "Unknown", fetch: { try await counter.response() })
        await invalid.check()
        #expect(await counter.count == 0)
        Settings.automaticUpdateChecks.set(true, in: defaults)
        let preview = UpdateCheckStore(defaults: defaults, currentVersion: "0.1.0", preview: true, fetch: { try await counter.response() })
        await preview.check(automatic: true)
        #expect(await counter.count == 0)
        await preview.check()
        #expect(await counter.count == 1)
        #expect(defaults.object(forKey: "releaseCheckLastAttempt") == nil)
    }
}
