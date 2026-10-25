import Foundation
@testable import OTMKit
import Testing

struct ReleaseUpdateTests {
    private func response(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> ReleaseHTTPResponse {
        ReleaseHTTPResponse(status: 200, data: Data("{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(prerelease)}".utf8))
    }

    @Test func comparesNumericStableVersions() throws {
        let nine = try #require(ReleaseVersion("0.9.0"))
        let ten = try #require(ReleaseVersion("v0.10.0"))
        #expect(ten > nine)
        #expect(ReleaseVersion("v1.0.0") == ReleaseVersion("1.0.0"))
        for invalid in ["", "1", "1.2", "1.2.3.4", "1.2.3-beta", "1.2.3+dev", "01.2.3", "1.-2.3", "1.2.x", " 1.2.3", "1.2/3"] {
            #expect(ReleaseVersion(invalid) == nil)
        }
    }

    @Test func offersOnlyNewerFullReleasesOnTheCanonicalPage() throws {
        let result = try ReleaseCheck.result(response("v0.10.0"), current: "0.9.0")
        guard case .available(let update) = result else { Issue.record("Newer release missing"); return }
        #expect(update.version == "v0.10.0")
        #expect(update.page.absoluteString == "https://github.com/jtn0123/OpenTaskManager/releases/tag/v0.10.0")
        #expect(try ReleaseCheck.result(response("v0.9.0"), current: "0.9.0") == .upToDate)
        #expect(try ReleaseCheck.result(response("v0.8.0"), current: "0.9.0") == .upToDate)
        #expect(throws: ReleaseCheckError.invalidResponse) { try ReleaseCheck.result(response("v0.10.0", prerelease: true), current: "0.9.0") }
        #expect(throws: ReleaseCheckError.invalidResponse) { try ReleaseCheck.result(response("v0.10.0", draft: true), current: "0.9.0") }
    }

    @Test func handlesNoPublicReleaseErrorsAndMalformedData() throws {
        #expect(try ReleaseCheck.result(.init(status: 404, data: Data()), current: "0.1.0") == .noPublicRelease)
        #expect(throws: ReleaseCheckError.rateLimited) { try ReleaseCheck.result(.init(status: 429, data: Data()), current: "0.1.0") }
        #expect(throws: ReleaseCheckError.http(503)) { try ReleaseCheck.result(.init(status: 503, data: Data()), current: "0.1.0") }
        #expect(throws: ReleaseCheckError.invalidCurrentVersion) { try ReleaseCheck.result(response("v1.0.0"), current: "Unknown") }
        #expect(throws: ReleaseCheckError.invalidResponse) {
            try ReleaseCheck.result(.init(status: 200, data: Data("<html>".utf8)), current: "0.1.0")
        }
        #expect(throws: ReleaseCheckError.tooLarge) {
            try ReleaseCheck.result(.init(status: 200, data: Data(repeating: 0, count: ReleaseCheck.maximumBytes + 1)), current: "0.1.0")
        }
    }

    @Test func automaticChecksAreOptInAndAtMostDailyIncludingClockChanges() {
        let date = Date(timeIntervalSince1970: 100_000)
        #expect(!ReleaseCheck.isDue(enabled: false, lastAttempt: nil, now: date))
        #expect(ReleaseCheck.isDue(enabled: true, lastAttempt: nil, now: date))
        #expect(!ReleaseCheck.isDue(enabled: true, lastAttempt: date, now: date.addingTimeInterval(86_399)))
        #expect(ReleaseCheck.isDue(enabled: true, lastAttempt: date, now: date.addingTimeInterval(86_400)))
        #expect(ReleaseCheck.isDue(enabled: true, lastAttempt: date.addingTimeInterval(100), now: date))
    }

    @Test func requestHasOnlyPublicMetadataHeaders() {
        let request = ReleaseClient.request()
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "api.github.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 15)
    }
}
