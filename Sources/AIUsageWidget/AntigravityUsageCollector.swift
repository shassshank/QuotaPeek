import Foundation

/// Fetches Antigravity quota usage from Google's Code Assist backend using the OAuth token
/// Antigravity already stored in the macOS Keychain (service "gemini", account "antigravity").
///
/// Antigravity consumer auth can have an empty quota project. Do not seed discovery with
/// ~/.gemini/antigravity-cli/cache/default_project_id.txt; live CLI logs show that value is
/// unrelated to the project sent by this account and can cause backend project validation errors.
final class AntigravityUsageCollector {
    private struct CredentialError: Error {
        let message: String
    }

    private struct Credentials: Decodable {
        struct Token: Decodable {
            let accessToken: String
            let tokenType: String?
            let expiry: String?
            let refreshToken: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case tokenType = "token_type"
                case expiry
                case refreshToken = "refresh_token"
            }
        }

        let token: Token?
        let accessToken: String?
        let planTier: String?

        enum CodingKeys: String, CodingKey {
            case token
            case accessToken = "access_token"
            case planTier = "plan_tier"
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
    private static let discoveryURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let quotaURLs = [
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
    ]
    private static var cachedDiscovery: (project: String?, planType: String?)?

    // Installed-app OAuth client id/secret pairs used by the locally installed Antigravity CLI
    // to refresh its own already-authorized token. Pairing between id and secret is not known
    // ahead of time, so every combination is tried against Google's token endpoint until one
    // succeeds; the winning pair is then cached for subsequent refreshes this run.
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let oauthClientIDs = [
        "REDACTED-GOOGLE-OAUTH-CLIENT-ID",
        "REDACTED-GOOGLE-OAUTH-CLIENT-ID",
    ]
    private static let oauthClientSecrets = [
        "REDACTED-GOOGLE-OAUTH-CLIENT-SECRET",
        "REDACTED-GOOGLE-OAUTH-CLIENT-SECRET",
    ]
    private static var cachedOAuthPair: (clientID: String, clientSecret: String)?

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

        let storedAccessToken = creds.token?.accessToken ?? creds.accessToken
        guard let storedAccessToken, !storedAccessToken.isEmpty else {
            return ProviderUsage(error: "Could not find Antigravity OAuth access token in Keychain credential")
        }

        var accessToken = storedAccessToken
        if let refreshToken = creds.token?.refreshToken, !refreshToken.isEmpty {
            if let refreshed = await Self.refreshAccessToken(refreshToken: refreshToken) {
                accessToken = refreshed
            }
        }

        let discovery: (project: String?, planType: String?)
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
            request.httpBody = try? JSONSerialization.data(withJSONObject: Self.quotaBody(project: discovery.project))

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

    private static func refreshAccessToken(refreshToken: String) async -> String? {
        let pairsToTry: [(String, String)]
        if let cached = cachedOAuthPair {
            pairsToTry = [(cached.clientID, cached.clientSecret)]
        } else {
            pairsToTry = oauthClientIDs.flatMap { id in oauthClientSecrets.map { (id, $0) } }
        }

        for (clientID, clientSecret) in pairsToTry {
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let form = [
                "grant_type=refresh_token",
                "refresh_token=\(refreshToken)",
                "client_id=\(clientID)",
                "client_secret=\(clientSecret)",
            ].joined(separator: "&")
            request.httpBody = form.data(using: .utf8)

            guard
                let (data, response) = try? await URLSession.shared.data(for: request),
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode),
                let object = try? JSONSerialization.jsonObject(with: data),
                let json = object as? [String: Any],
                let token = json["access_token"] as? String,
                !token.isEmpty
            else { continue }

            cachedOAuthPair = (clientID, clientSecret)
            return token
        }
        return nil
    }

    private static func discoverProject(accessToken: String, credentials: Credentials) async throws -> (project: String?, planType: String?) {
        let body: [String: Any] = [
            "metadata": clientMetadata(),
        ]

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

        let planType = tierDescription(json["paidTier"])
            ?? tierDescription(json["currentTier"])
            ?? credentials.planTier

        return (project, planType)
    }

    // Matches the real Antigravity CLI's request shape exactly (captured via local proxy from
    // a real `agy` `/usage` invocation). Google's backend rejects any other User-Agent with
    // UNSUPPORTED_CLIENT; there is no separate Client-Metadata header.
    private static func applyHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "antigravity/cli/1.1.26 (aidev_client; os_type=darwin; arch=arm64; cl=976013059; auth_method=consumer)",
            forHTTPHeaderField: "User-Agent"
        )
    }

    private static func clientMetadata() -> [String: Any] {
        ["ideType": "ANTIGRAVITY"]
    }

    private static func quotaBody(project: String?) -> [String: Any] {
        guard let project = trimmedNonEmpty(project) else {
            return [:]
        }
        return ["project": project]
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
