import Foundation
import Observation
import OTMKit

@Observable
@MainActor
final class UpdateCheckStore {
    static let shared: UpdateCheckStore = {
        #if DEBUG
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let fixture = arguments["updateCheckFixture"] as? String {
            return UpdateCheckStore(preview: true, fetch: {
                if fixture == "error" { throw URLError(.notConnectedToInternet) }
                let tag = fixture == "current" ? "v0.1.0" : "v99.0.0"
                return ReleaseHTTPResponse(status: fixture == "none" ? 404 : 200,
                                           data: Data("{\"tag_name\":\"\(tag)\",\"draft\":false,\"prerelease\":false}".utf8))
            })
        }
        #endif
        return UpdateCheckStore()
    }()

    enum State: Equatable {
        case idle, checking
        case checked(ReleaseCheckResult)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var lastChecked: Date?
    let currentVersion: String
    let preview: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable () async throws -> ReleaseHTTPResponse
    @ObservationIgnored private let now: @Sendable () -> Date
    private static let attemptKey = "releaseCheckLastAttempt"

    init(defaults: UserDefaults = .standard, currentVersion: String? = nil, preview: Bool = false,
         now: @escaping @Sendable () -> Date = Date.init,
         fetch: @escaping @Sendable () async throws -> ReleaseHTTPResponse = ReleaseClient.fetchLatest) {
        self.defaults = defaults
        self.currentVersion = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        self.preview = preview
        self.now = now
        self.fetch = fetch
    }

    func check(automatic: Bool = false) async {
        guard state != .checking else { return }
        let date = now()
        if automatic {
            guard !preview, ReleaseCheck.isDue(enabled: Settings.automaticUpdateChecks.get(in: defaults),
                                               lastAttempt: defaults.object(forKey: Self.attemptKey) as? Date, now: date) else { return }
        }
        guard ReleaseVersion(currentVersion) != nil else { state = .failed(ReleaseCheckError.invalidCurrentVersion.message); return }
        if !preview { defaults.set(date, forKey: Self.attemptKey) }
        state = .checking
        do {
            let response = try await fetch()
            let result = try ReleaseCheck.result(response, current: currentVersion)
            state = .checked(result)
            lastChecked = now()
        } catch let error as ReleaseCheckError {
            state = .failed(error.message)
        } catch {
            state = .failed("Could not reach GitHub. Check your connection and try again.")
        }
    }

    var message: String {
        switch state {
        case .idle: "Check for a newer public release on GitHub."
        case .checking: "Checking GitHub…"
        case .checked(.noPublicRelease): "No public release is available yet."
        case .checked(.upToDate): "You’re up to date."
        case .checked(.available(let update)): "\(update.version) is available."
        case .failed(let message): message
        }
    }
}
