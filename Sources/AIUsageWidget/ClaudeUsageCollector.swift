import Foundation

/// Fetches live Claude Code rate-limit usage directly from Anthropic's API, using the OAuth
/// token Claude Code already stored in the macOS Keychain (service "Claude Code-credentials").
/// This never reads or writes any Claude Code config/settings file — the only external touch
/// is a single minimal (max_tokens: 1) authenticated request to api.anthropic.com, whose response
/// headers carry the same rate-limit numbers Claude Code's own status line shows.
///
/// Confirmed header shape (verified against a real account 2026-09-04):
///   anthropic-ratelimit-unified-5h-utilization   -> fraction 0...1 used
///   anthropic-ratelimit-unified-5h-reset         -> unix timestamp (seconds)
///   anthropic-ratelimit-unified-7d-utilization
///   anthropic-ratelimit-unified-7d-reset
final class ClaudeUsageCollector {
    private struct OAuthCreds: Decodable {
        struct Inner: Decodable {
            let accessToken: String
            let subscriptionType: String?
            let rateLimitTier: String?
        }
        let claudeAiOauth: Inner
    }

    private static let keychainService = "Claude Code-credentials"
    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Fetches fresh usage and merges it into the shared usage.json cache under the "claude" key,
    /// leaving whatever other providers (e.g. codex) already wrote there untouched.
    func refreshCache() async {
        let usage = await fetch()
        UsageCache.merge(provider: "claude", usage: usage)
    }

    func fetch() async -> ProviderUsage {
        guard let credsData = KeychainReader.readData(service: Self.keychainService) else {
            return ProviderUsage(error: "Claude Code credentials not found in Keychain (is Claude Code installed and logged in?)")
        }
        guard let creds = try? JSONDecoder().decode(OAuthCreds.self, from: credsData) else {
            return ProviderUsage(error: "Could not parse Claude Code Keychain credentials")
        }

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(creds.claudeAiOauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ProviderUsage(error: "No HTTP response from Anthropic API")
            }
            guard (200...299).contains(http.statusCode) else {
                return ProviderUsage(error: "Anthropic API returned status \(http.statusCode)")
            }
            return Self.parse(headers: http.allHeaderFields, planType: creds.claudeAiOauth.subscriptionType ?? creds.claudeAiOauth.rateLimitTier)
        } catch {
            return ProviderUsage(error: "Request failed: \(error.localizedDescription)")
        }
    }

    private static func parse(headers: [AnyHashable: Any], planType: String?) -> ProviderUsage {
        func header(_ name: String) -> String? {
            for (key, value) in headers {
                if let keyStr = key as? String, keyStr.caseInsensitiveCompare(name) == .orderedSame {
                    return "\(value)"
                }
            }
            return nil
        }

        func window(utilizationHeader: String, resetHeader: String) -> WindowUsage? {
            guard let utilStr = header(utilizationHeader), let utilization = Double(utilStr) else { return nil }
            let resetsAt = header(resetHeader).flatMap { Int(Double($0) ?? 0) }
            return WindowUsage(usedPercent: (utilization * 100).rounded(toPlaces: 1), resetsAt: resetsAt)
        }

        let usage = ProviderUsage(
            fiveHour: window(utilizationHeader: "anthropic-ratelimit-unified-5h-utilization",
                              resetHeader: "anthropic-ratelimit-unified-5h-reset"),
            weekly: window(utilizationHeader: "anthropic-ratelimit-unified-7d-utilization",
                            resetHeader: "anthropic-ratelimit-unified-7d-reset"),
            updatedAt: Int(Date().timeIntervalSince1970),
            planType: planType,
            error: nil
        )
        return usage
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
