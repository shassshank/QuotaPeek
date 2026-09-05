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

    func refresh() async -> Result<StatusResponse, DaemonError> {
        await request(path: "/refresh", method: "POST")
    }

    func config() async -> Result<DaemonConfig, DaemonError> {
        await request(path: "/config", method: "GET")
    }

    func updateConfig(_ config: DaemonConfig) async -> Result<DaemonConfig, DaemonError> {
        guard let body = try? JSONEncoder().encode(config) else { return .failure(.decodeFailed) }
        return await request(path: "/config", method: "PUT", body: body)
    }

    func errors(limit: Int = 50) async -> Result<ErrorsResponse, DaemonError> {
        await request(path: "/errors?limit=\(limit)", method: "GET")
    }

    func testRoute(provider: Provider, route: Route) async -> Result<TestRouteResponse, DaemonError> {
        let requestBody = TestRouteRequest(provider: provider, route: route)
        guard let body = try? JSONEncoder().encode(requestBody) else { return .failure(.decodeFailed) }
        return await request(path: "/test-route", method: "POST", body: body)
    }

    private func request<T: Decodable>(path: String, method: String, body: Data? = nil) async -> Result<T, DaemonError> {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path))
        // appendingPathComponent escapes "?" - rebuild with URLComponents when there's a query string.
        if path.contains("?"), let url = URL(string: Self.baseURL.absoluteString + path) {
            request = URLRequest(url: url)
        }
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
            guard (200...299).contains(http.statusCode) else { return .failure(.badResponse(http.statusCode)) }
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { return .failure(.decodeFailed) }
            return .success(decoded)
        } catch {
            return .failure(.unreachable)
        }
    }
}
