import Foundation

/// Talks to the local Go daemon over loopback HTTP, per API_CONTRACT.md. The Swift app never
/// touches Keychain, provider APIs, or any local cache file directly - the daemon owns all of
/// that, and this is the only network client the app has.
enum DaemonError: Error, Equatable {
    case unreachable
    case badResponse(Int)
    case decodeFailed
}

final class DaemonClient {
    static let baseURL = URL(string: "http://127.0.0.1:47831")!

    private let session: URLSession
    private var cachedToken: String?
    private let tokenLock = NSLock()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    private func getAuthToken(forceReload: Bool = false) -> String? {
        tokenLock.lock()
        defer { tokenLock.unlock() }

        if !forceReload, let token = cachedToken, !token.isEmpty {
            return token
        }

        let tokenURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaPeek/auth-token")
        if let token = try? String(contentsOf: tokenURL, encoding: .utf8) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            cachedToken = trimmed
            return trimmed
        }
        cachedToken = nil
        return nil
    }

    private func invalidateToken() {
        tokenLock.lock()
        cachedToken = nil
        tokenLock.unlock()
    }

    func status() async -> Result<StatusResponse, DaemonError> {
        await request(path: "/status", method: "GET")
    }

    /// Triggers an immediate live re-fetch for all accounts or a single account if `accountId` is specified.
    func refresh(accountId: String? = nil) async -> Result<StatusResponse, DaemonError> {
        var body: Data?
        if let accountId {
            body = try? JSONSerialization.data(withJSONObject: ["accountId": accountId])
        }
        return await request(path: "/refresh", method: "POST", body: body)
    }

    // MARK: - Account Management (P5)

    func accounts() async -> Result<AccountsResponse, DaemonError> {
        await request(path: "/accounts", method: "GET")
    }

    func createAccount(_ accountRequest: CreateAccountRequest) async -> Result<Account, DaemonError> {
        guard let body = try? JSONEncoder().encode(accountRequest) else { return .failure(.decodeFailed) }
        return await request(path: "/accounts", method: "POST", body: body)
    }

    func updateAccount(id: String, label: String) async -> Result<Account, DaemonError> {
        let payload = UpdateAccountRequest(label: label)
        guard let body = try? JSONEncoder().encode(payload) else { return .failure(.decodeFailed) }
        return await request(url: accountURL(id: id), method: "PATCH", body: body)
    }

    func deleteAccount(id: String) async -> Result<SimpleSuccessResponse, DaemonError> {
        await request(url: accountURL(id: id), method: "DELETE")
    }

    /// Tests exactly the requested route for an account, per P5 contract.
    func testRoute(accountId: String, provider: Provider, route: Route) async -> Result<TestRouteResponse, DaemonError> {
        let requestBody = TestRouteRequest(accountId: accountId, provider: provider, route: route)
        guard let body = try? JSONEncoder().encode(requestBody) else { return .failure(.decodeFailed) }
        return await request(path: "/test-route", method: "POST", body: body)
    }

    /// Clears daemon credential/discovery cache for a specific account.
    func resetCredentials(accountId: String) async -> Result<ResetCredentialsResponse, DaemonError> {
        await request(url: accountURL(id: accountId, trailingPathComponent: "reset-credentials"), method: "POST")
    }

    /// Fetches usage history points for a given account and route, per P5 contract.
    func history(accountId: String, route: Route? = nil) async -> Result<HistoryResponse, DaemonError> {
        var queryItems = [URLQueryItem(name: "accountId", value: accountId)]
        if let route, route != .none {
            queryItems.append(URLQueryItem(name: "route", value: route.rawValue))
        }
        let url = Self.makeURL(path: "/history", queryItems: queryItems)
        return await request(url: url, method: "GET")
    }

    // MARK: - Config & Diagnostics

    func config() async -> Result<DaemonConfig, DaemonError> {
        await request(path: "/config", method: "GET")
    }

    func updateConfig(_ config: DaemonConfig) async -> Result<DaemonConfig, DaemonError> {
        guard let body = try? JSONEncoder().encode(config) else { return .failure(.decodeFailed) }
        return await request(path: "/config", method: "PUT", body: body)
    }

    func updateConfigFields(_ fields: [String: Any]) async -> Result<DaemonConfig, DaemonError> {
        guard let body = try? JSONSerialization.data(withJSONObject: fields) else {
            return .failure(.decodeFailed)
        }
        return await request(path: "/config", method: "PUT", body: body)
    }

    func errors(limit: Int = 50) async -> Result<ErrorsResponse, DaemonError> {
        let url = Self.makeURL(path: "/errors", queryItems: [URLQueryItem(name: "limit", value: String(limit))])
        return await request(url: url, method: "GET")
    }

    /// Pauses background data collection on the daemon.
    func pauseCollection() async -> Result<DaemonConfig, DaemonError> {
        await updateConfigFields(["collectionPaused": true])
    }

    /// Resumes background data collection on the daemon.
    func resumeCollection() async -> Result<DaemonConfig, DaemonError> {
        await updateConfigFields(["collectionPaused": false])
    }

    // MARK: - URL Construction

    /// Characters safe to leave unescaped within a single opaque path segment
    /// (an account id, say). Deliberately narrower than `.urlPathAllowed` -
    /// that set still permits "/", which would let a value containing a slash
    /// smuggle in an extra path segment. Everything outside RFC 3986's
    /// "unreserved" set (including "#", "?", "=", "+", space, "/") gets
    /// percent-encoded.
    private static let pathSegmentAllowedCharacters: CharacterSet = {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    }()

    private static func encodedPathSegment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowedCharacters) ?? raw
    }

    /// Builds a URL under `baseURL` from literal path segments (assumed to
    /// already be URL-safe, e.g. `"/accounts"`) plus optional query items.
    /// Uses `URLComponents` throughout instead of `URL(string:)` string
    /// concatenation or `appendingPathComponent`, so values containing `#`,
    /// `?`, `=`, `+`, or spaces are always correctly percent-encoded rather
    /// than truncating the URL or corrupting the query string.
    private static func makeURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url ?? baseURL
    }

    /// Builds `/accounts/<id>` (optionally with a trailing literal path
    /// component, e.g. `"reset-credentials"`), percent-encoding `id` as a
    /// single opaque path segment so ids containing `#`, `?`, `=`, or spaces
    /// can't break the URL or get misinterpreted.
    private func accountURL(id: String, trailingPathComponent: String? = nil) -> URL {
        var path = "/accounts/" + Self.encodedPathSegment(id)
        if let trailingPathComponent {
            path += "/" + trailingPathComponent
        }
        return Self.makeURL(path: path)
    }

    // MARK: - Internal HTTP Request

    private func request<T: Decodable>(path: String, method: String, body: Data? = nil, isRetryAfterAuthRefresh: Bool = false) async -> Result<T, DaemonError> {
        await request(url: Self.makeURL(path: path), method: method, body: body, isRetryAfterAuthRefresh: isRetryAfterAuthRefresh)
    }

    private func request<T: Decodable>(url: URL, method: String, body: Data? = nil, isRetryAfterAuthRefresh: Bool = false) async -> Result<T, DaemonError> {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = getAuthToken(forceReload: isRetryAfterAuthRefresh) {
            request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            if http.statusCode == 401 && !isRetryAfterAuthRefresh {
                invalidateToken()
                return await self.request(url: url, method: method, body: body, isRetryAfterAuthRefresh: true)
            }
            guard (200...299).contains(http.statusCode) else { return .failure(.badResponse(http.statusCode)) }

            // A genuinely empty body (typically paired with 204 No Content) means
            // success with no payload - if `T` can represent that directly, return
            // it without forcing the empty body through JSON decoding of a shape
            // that may not tolerate an empty object (e.g. `SimpleSuccessResponse.ok`
            // is a non-optional `Bool`, so decoding "{}" into it always fails).
            // A non-empty but malformed body still correctly fails decode below.
            if data.isEmpty || http.statusCode == 204 {
                if let emptyType = T.self as? DaemonEmptySuccessRepresentable.Type {
                    return .success(emptyType.emptySuccess as! T)
                }
            }

            let responseData = data.isEmpty ? "{}".data(using: .utf8)! : data
            guard let decoded = try? JSONDecoder().decode(T.self, from: responseData) else { return .failure(.decodeFailed) }
            return .success(decoded)
        } catch {
            return .failure(.unreachable)
        }
    }
}

/// Conformed to by response types that have a well-defined "successful, empty
/// body" value, so `DaemonClient`'s request layer can short-circuit an empty
/// or 204 response straight to success instead of trying to JSON-decode it.
protocol DaemonEmptySuccessRepresentable {
    static var emptySuccess: Self { get }
}

extension SimpleSuccessResponse: DaemonEmptySuccessRepresentable {
    static var emptySuccess: SimpleSuccessResponse { SimpleSuccessResponse(ok: true, message: nil) }
}
