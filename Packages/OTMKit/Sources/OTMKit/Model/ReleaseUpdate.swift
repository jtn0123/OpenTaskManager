import Foundation

/// Stable release tags use vMAJOR.MINOR.PATCH; numeric comparison avoids
/// treating 0.10.0 as older than 0.9.0. Prereleases never enter this channel.
public struct ReleaseVersion: Sendable, Equatable, Comparable {
    public let components: [Int]

    public init?(_ string: String) {
        let value = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            components.append(number)
        }
        self.components = components
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

public struct ReleaseUpdate: Sendable, Equatable {
    public let version: String
    public let page: URL
}

public enum ReleaseCheckResult: Sendable, Equatable {
    case noPublicRelease
    case upToDate
    case available(ReleaseUpdate)
}

public enum ReleaseCheckError: Error, Sendable, Equatable {
    case invalidCurrentVersion, invalidResponse, tooLarge, rateLimited, http(Int)

    public var message: String {
        switch self {
        case .invalidCurrentVersion: "This build has no recognized version to compare."
        case .invalidResponse: "GitHub returned release information this app could not read."
        case .tooLarge: "GitHub’s release response was too large."
        case .rateLimited: "GitHub is limiting requests. Try again later."
        case .http(let status): "GitHub could not provide a release (HTTP \(status))."
        }
    }
}

public struct ReleaseHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public enum ReleaseCheck {
    public static let releasesPage = URL(string: "https://github.com/jtn0123/OpenTaskManager/releases")!
    public static let interval: TimeInterval = 24 * 60 * 60
    public static let maximumBytes = 1_048_576

    public static func isDue(enabled: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastAttempt else { return true }
        return now < lastAttempt || now.timeIntervalSince(lastAttempt) >= interval
    }

    private struct Payload: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease }
        let draft: Bool
        let prerelease: Bool
    }

    public static func result(_ response: ReleaseHTTPResponse, current: String) throws(ReleaseCheckError) -> ReleaseCheckResult {
        guard let current = ReleaseVersion(current) else { throw .invalidCurrentVersion }
        if response.status == 404 { return .noPublicRelease }
        if response.status == 403 || response.status == 429 { throw .rateLimited }
        guard response.status == 200 else { throw .http(response.status) }
        guard response.data.count <= maximumBytes else { throw .tooLarge }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.data),
              !payload.draft, !payload.prerelease, let version = ReleaseVersion(payload.tagName) else { throw .invalidResponse }
        guard version > current else { return .upToDate }
        // The numeric tag is validated above; never open a server-supplied URL.
        let page = releasesPage.appendingPathComponent("tag").appendingPathComponent(payload.tagName)
        return .available(ReleaseUpdate(version: payload.tagName, page: page))
    }
}
