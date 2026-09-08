import Foundation

/// Talks to the local Go daemon over loopback HTTP, per API_CONTRACT.md. The Swift app never
/// touches Keychain, provider APIs, or any local cache file directly - the daemon owns all of
/// that, and this is the only network client the app has.
enum DaemonError: Error {
    case unreachable
    case badResponse(Int)
    case decodeFailed
}

final class DaemonClient {
    static let baseURL = URL(string: "http://127.0.0.1:47831")!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
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
        return await request(path: "/accounts/\(id)", method: "PATCH", body: body)
    }

    func deleteAccount(id: String) async -> Result<SimpleSuccessResponse, DaemonError> {
        await request(path: "/accounts/\(id)", method: "DELETE")
    }

    /// Tests exactly the requested route for an account, per P5 contract.
    func testRoute(accountId: String, provider: Provider, route: Route) async -> Result<TestRouteResponse, DaemonError> {
        let requestBody = TestRouteRequest(accountId: accountId, provider: provider, route: route)
        guard let body = try? JSONEncoder().encode(requestBody) else { return .failure(.decodeFailed) }
        return await request(path: "/test-route", method: "POST", body: body)
    }

    /// Clears daemon credential/discovery cache for a specific account.
    func resetCredentials(accountId: String) async -> Result<ResetCredentialsResponse, DaemonError> {
        await request(path: "/accounts/\(accountId)/reset-credentials", method: "POST")
    }

    /// Fetches usage history points for a given account and route, per P5 contract.
    func history(accountId: String, route: Route? = nil) async -> Result<HistoryResponse, DaemonError> {
        var path = "/history?accountId=\(accountId)"
        if let route, route != .none {
            path += "&route=\(route.rawValue)"
        }
        return await request(path: path, method: "GET")
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
        await request(path: "/errors?limit=\(limit)", method: "GET")
    }

    /// Pauses background data collection on the daemon.
    func pauseCollection() async -> Result<DaemonConfig, DaemonError> {
        await updateConfigFields(["collectionPaused": true])
    }

    /// Resumes background data collection on the daemon.
    func resumeCollection() async -> Result<DaemonConfig, DaemonError> {
        await updateConfigFields(["collectionPaused": false])
    }

    // MARK: - Internal HTTP Request

    private func request<T: Decodable>(path: String, method: String, body: Data? = nil) async -> Result<T, DaemonError> {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path))
        // appendingPathComponent escapes "?" - rebuild with URLComponents when there's a query string.
        if path.contains("?"), let url = URL(string: Self.baseURL.absoluteString + path) {
            request = URLRequest(url: url)
        }
        request.httpMethod = method
        let tokenURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsageWidget/auth-token")
        if let token = try? String(contentsOf: tokenURL, encoding: .utf8) {
            request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Auth-Token")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            guard (200...299).contains(http.statusCode) else { return .failure(.badResponse(http.statusCode)) }
            let responseData = data.isEmpty ? "{}".data(using: .utf8)! : data
            guard let decoded = try? JSONDecoder().decode(T.self, from: responseData) else { return .failure(.decodeFailed) }
            return .success(decoded)
        } catch {
            return .failure(.unreachable)
        }
    }
}
