import Foundation

/// Fetches Antigravity quota usage from Google's Code Assist backend using the OAuth token
/// Antigravity already stored in the macOS Keychain (service "gemini", account "antigravity").
/// This never reads or writes Antigravity config/settings files.
///
/// Public Antigravity docs confirm that its `/usage` command refreshes quota from a backend
/// service and that status-line quota buckets carry remaining_fraction/reset_time values. The
/// Code Assist RPC URLs and the loadCodeAssist project-discovery flow match the public Gemini CLI
/// implementation. Antigravity-specific metadata is still inferred, so parsing remains defensive.
final class AntigravityUsageCollector {
    private struct CredentialError: Error {
        let message: String
    }

    private struct Credentials: Decodable {
        struct Token: Decodable {
            let accessToken: String
            let tokenType: String?
            let expiry: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case tokenType = "token_type"
                case expiry
            }
        }

        let token: Token?
        let accessToken: String?
        let planTier: String?
        let project: String?
        let projectId: String?
        let quotaProject: String?

        enum CodingKeys: String, CodingKey {
            case token
            case accessToken = "access_token"
            case planTier = "plan_tier"
            case project
            case projectId = "project_id"
            case quotaProject = "quota_project"
        }
    }

    private struct QuotaWindow {
        let id: String
        let displayName: String?
        let window: String?
        let remainingFraction: Double
        let resetTime: String?
    }

    private static let keychainService = "gemini"
    private static let keychainAccount = "antigravity"
    private static let keyringPrefix = "go-keyring-base64:"
    private static let discoveryURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let quotaURLs = [
        URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
        URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
    ]
    private static var cachedDiscovery: (project: String, planType: String?)?

    func refreshCache() async {
        let usage = await fetch()
        UsageCache.merge(provider: "antigravity", usage: usage)
    }

    func fetch() async -> ProviderUsage {
        let credentialResult = Self.loadCredentials()
        guard case .success(let creds) = credentialResult else {
            if case .failure(let error) = credentialResult {
                return ProviderUsage(error: error.message)
            }
            return ProviderUsage(error: "Antigravity credentials not found")
        }

        let accessToken = creds.token?.accessToken ?? creds.accessToken
        guard let accessToken, !accessToken.isEmpty else {
            return ProviderUsage(error: "Could not find Antigravity OAuth access token in Keychain credential")
        }

        let discovery: (project: String, planType: String?)
        if let cached = Self.cachedDiscovery {
            discovery = cached
        } else {
            do {
                discovery = try await Self.discoverProject(accessToken: accessToken, credentials: creds)
                Self.cachedDiscovery = discovery
            } catch {
                return ProviderUsage(error: "Antigravity discovery failed: \(Self.errorMessage(error))")
            }
        }

        var lastFailure = "No quota endpoint attempted"
        for url in Self.quotaURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            Self.applyHeaders(to: &request, accessToken: accessToken)
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["project": discovery.project])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastFailure = "No HTTP response from \(url.host ?? "Google quota endpoint")"
                    continue
                }
                guard (200...299).contains(http.statusCode) else {
                    lastFailure = "\(url.lastPathComponent) returned status \(http.statusCode): \(Self.bodyPreview(data))"
                    continue
                }
                guard let usage = Self.parse(data: data, planType: discovery.planType ?? creds.planTier) else {
                    lastFailure = "\(url.lastPathComponent) returned no parseable quota buckets"
                    continue
                }
                return usage
            } catch {
                lastFailure = "\(url.lastPathComponent) request failed: \(error.localizedDescription)"
            }
        }

        return ProviderUsage(error: "Antigravity quota failed: \(lastFailure)")
    }

    private static func discoverProject(accessToken: String, credentials: Credentials) async throws -> (project: String, planType: String?) {
        let existingProject = [credentials.project, credentials.projectId, credentials.quotaProject].compactMap { $0 }.first
        var body: [String: Any] = [
            "metadata": clientMetadata(duetProject: existingProject),
        ]
        if let existingProject {
            body["cloudaicompanionProject"] = existingProject
        }

        var request = URLRequest(url: discoveryURL)
        request.httpMethod = "POST"
        applyHeaders(to: &request, accessToken: accessToken)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CredentialError(message: "No HTTP response from loadCodeAssist")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CredentialError(message: "loadCodeAssist returned status \(http.statusCode): \(bodyPreview(data))")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw CredentialError(message: "loadCodeAssist returned non-JSON response")
        }

        let project = stringValue(json["cloudaicompanionProject"])
            ?? nestedString(json["cloudaicompanionProject"], key: "id")
            ?? existingProject
        guard let project, !project.isEmpty else {
            throw CredentialError(message: "loadCodeAssist returned no cloudaicompanionProject")
        }

        let planType = tierDescription(json["paidTier"])
            ?? tierDescription(json["currentTier"])
            ?? credentials.planTier

        return (project, planType)
    }

    private static func applyHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("google-api-nodejs-client/9.15.1", forHTTPHeaderField: "User-Agent")
        request.setValue(
            "{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}",
            forHTTPHeaderField: "Client-Metadata"
        )
    }

    private static func clientMetadata(duetProject: String? = nil) -> [String: Any] {
        var metadata: [String: Any] = [
            "ideType": "IDE_UNSPECIFIED",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
        ]
        if let duetProject {
            metadata["duetProject"] = duetProject
        }
        return metadata
    }

    private static func tierDescription(_ value: Any?) -> String? {
        guard let tier = value as? [String: Any] else { return nil }
        let id = stringValue(tier["id"])
        let name = stringValue(tier["name"])
        return [name, id].compactMap { $0 }.first
    }

    private static func nestedString(_ value: Any?, key: String) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        return stringValue(dict[key])
    }

    private static func bodyPreview(_ data: Data) -> String {
        guard !data.isEmpty else { return "<empty body>" }
        let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
        return String(text.prefix(600))
    }

    private static func errorMessage(_ error: Error) -> String {
        if let credentialError = error as? CredentialError {
            return credentialError.message
        }
        return error.localizedDescription
    }

    private static func loadCredentials() -> Result<Credentials, CredentialError> {
        guard let raw = KeychainReader.readString(service: keychainService, account: keychainAccount) else {
            return .failure(CredentialError(message: "Antigravity credentials not found in Keychain (service \"gemini\", account \"antigravity\")"))
        }
        guard raw.hasPrefix(keyringPrefix) else {
            return .failure(CredentialError(message: "Antigravity Keychain credential did not have expected go-keyring-base64 prefix"))
        }
        let encoded = String(raw.dropFirst(keyringPrefix.count))
        guard let decoded = Data(base64Encoded: encoded) else {
            return .failure(CredentialError(message: "Could not base64-decode Antigravity Keychain credential"))
        }
        do {
            return .success(try JSONDecoder().decode(Credentials.self, from: decoded))
        } catch {
            return .failure(CredentialError(message: "Could not parse Antigravity Keychain credential JSON"))
        }
    }

    private static func parse(data: Data, planType: String?) -> ProviderUsage? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else { return nil }

        let buckets = collectBuckets(from: json)
        guard !buckets.isEmpty else { return nil }

        var fiveHour: WindowUsage?
        var weekly: WindowUsage?

        for bucket in buckets {
            let usage = WindowUsage(
                usedPercent: ((1 - bucket.remainingFraction) * 100).rounded(toPlaces: 1),
                resetsAt: bucket.resetTime.flatMap(parseResetTime)
            )
            let label = [bucket.id, bucket.displayName, bucket.window]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")

            if label.contains("week") || label.contains("7d") {
                weekly = chooseMoreUsed(current: weekly, candidate: usage)
            } else if label.contains("5h") || label.contains("5 hour") || label.contains("hour") {
                fiveHour = chooseMoreUsed(current: fiveHour, candidate: usage)
            } else if weekly == nil {
                weekly = usage
            }
        }

        guard fiveHour != nil || weekly != nil else { return nil }
        return ProviderUsage(
            fiveHour: fiveHour,
            weekly: weekly,
            updatedAt: Int(Date().timeIntervalSince1970),
            planType: planType,
            error: nil
        )
    }

    private static func collectBuckets(from value: Any) -> [QuotaWindow] {
        var buckets: [QuotaWindow] = []

        func walk(_ value: Any, inheritedId: String? = nil) {
            if let dict = value as? [String: Any] {
                if let bucket = quotaWindow(from: dict, fallbackId: inheritedId) {
                    buckets.append(bucket)
                }
                for (key, child) in dict {
                    walk(child, inheritedId: key)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    walk(child, inheritedId: inheritedId)
                }
            }
        }

        walk(value)
        return buckets
    }

    private static func quotaWindow(from dict: [String: Any], fallbackId: String?) -> QuotaWindow? {
        guard let remaining = doubleValue(dict["remainingFraction"] ?? dict["remaining_fraction"]) else {
            return nil
        }

        let id = stringValue(dict["bucketId"] ?? dict["bucket_id"] ?? dict["id"] ?? dict["modelId"] ?? dict["model_id"])
            ?? fallbackId
            ?? "quota"
        let displayName = stringValue(dict["displayName"] ?? dict["display_name"] ?? dict["name"])
        let window = stringValue(dict["window"] ?? dict["windowName"] ?? dict["window_name"] ?? dict["quotaType"] ?? dict["quota_type"])
        let resetTime = stringValue(dict["resetTime"] ?? dict["reset_time"])

        return QuotaWindow(id: id, displayName: displayName, window: window, remainingFraction: remaining, resetTime: resetTime)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        return nil
    }

    private static func parseResetTime(_ value: String) -> Int? {
        if let unix = Double(value) {
            return Int(unix)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return Int(date.timeIntervalSince1970)
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value).map { Int($0.timeIntervalSince1970) }
    }

    private static func chooseMoreUsed(current: WindowUsage?, candidate: WindowUsage) -> WindowUsage {
        guard let current else { return candidate }
        return candidate.usedPercent > current.usedPercent ? candidate : current
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
