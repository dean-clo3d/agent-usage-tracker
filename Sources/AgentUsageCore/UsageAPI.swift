import Foundation

public enum UsageAPIError: Error {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case network(String)
    case decoding
}

public struct UsageAPI: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    public init(session: URLSession = UsageAPI.makeSession()) {
        self.session = session
    }

    /// A session that leaves nothing on disk and never stores or sends cookies.
    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config)
    }

    public func fetch(accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentUsage/\(AppInfo.version) (macOS menu bar)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            // Redirects are refused: URLSession would otherwise replay our headers,
            // including the bearer token, to whatever host the redirect names.
            (data, response) = try await session.data(for: request, delegate: RedirectBlocker.shared)
        } catch let error as URLError {
            // Only the error code — never the URL/userInfo, which tie back to the request.
            throw UsageAPIError.network(Self.describe(error.code))
        } catch {
            throw UsageAPIError.network("요청 실패")
        }

        // The token must only ever have gone to the pinned endpoint.
        guard response.url?.host == Self.endpoint.host, response.url?.scheme == "https" else {
            throw UsageAPIError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            do {
                return try UsageResponse.decode(data)
            } catch {
                throw UsageAPIError.decoding
            }
        case 401, 403:
            throw UsageAPIError.unauthorized
        case 429:
            let retryAfter = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw UsageAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageAPIError.http(status: status)
        }
    }

    static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: return "인터넷에 연결되어 있지 않아요."
        case .timedOut: return "응답 시간이 초과됐어요."
        case .cannotFindHost, .dnsLookupFailed: return "서버를 찾을 수 없어요."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "안전한 연결을 만들지 못했어요."
        default: return "연결 오류 (\(code.rawValue))"
        }
    }
}

/// Cancels every HTTP redirect so request headers are never re-sent elsewhere.
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectBlocker()

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

public enum AppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
