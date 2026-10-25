import Foundation

/// One bounded, unauthenticated metadata request. No cookies, cached
/// credentials, telemetry, background session or application download.
public enum ReleaseClient {
    public static func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/jtn0123/OpenTaskManager/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OpenTaskManager", forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func fetchLatest() async throws -> ReleaseHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: ReleaseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request())
        guard let response = response as? HTTPURLResponse else { throw ReleaseCheckError.invalidResponse }
        if response.statusCode != 200 { return ReleaseHTTPResponse(status: response.statusCode, data: Data()) }
        guard response.expectedContentLength <= ReleaseCheck.maximumBytes else { throw ReleaseCheckError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < ReleaseCheck.maximumBytes else { throw ReleaseCheckError.tooLarge }
            data.append(byte)
        }
        return ReleaseHTTPResponse(status: response.statusCode, data: data)
    }
}

private final class ReleaseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && request.url?.host == "api.github.com"
        completionHandler(allowed ? request : nil)
    }
}
