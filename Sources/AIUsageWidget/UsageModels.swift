import Foundation

/// Types mirror API_CONTRACT.md exactly - the Go daemon is the source of truth for these shapes.

enum Provider: String, CaseIterable, Identifiable, Codable {
    case claude, codex, antigravity
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "atom"
        }
    }
}

enum Route: String, Codable {
    case keychain
    case injection
    case none
}

struct ProviderData: Codable {
    var usedPercent5h: Double?
    var resetsAt5h: Int?
    var usedPercentWeekly: Double?
    var resetsAtWeekly: Int?
    var contextWindowUsedPercent: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent5h = "used_percent_5h"
        case resetsAt5h = "resets_at_5h"
        case usedPercentWeekly = "used_percent_weekly"
        case resetsAtWeekly = "resets_at_weekly"
        case contextWindowUsedPercent = "context_window_used_percent"
    }
}

struct ProviderError: Codable {
    var route: Route
    var message: String
    var at: Int
}

struct ProviderStatus: Codable, Identifiable {
    var id: Provider { provider }
    var provider: Provider
    var routesEnabled: [Route]
    var activeRoute: Route
    var data: ProviderData?
    var asOf: Int?
    var lastError: ProviderError?

    enum CodingKeys: String, CodingKey {
        case provider = "id"
        case routesEnabled = "routes_enabled"
        case activeRoute = "active_route"
        case data
        case asOf = "as_of"
        case lastError = "last_error"
    }
}

struct StatusResponse: Codable {
    var providers: [ProviderStatus]
}

struct ProviderConfig: Codable {
    var routesEnabled: [Route]
    var keychainPollIntervalSec: Int

    enum CodingKeys: String, CodingKey {
        case routesEnabled = "routes_enabled"
        case keychainPollIntervalSec = "keychain_poll_interval_sec"
    }
}

struct DaemonConfig: Codable {
    var claude: ProviderConfig?
    var codex: ProviderConfig?
    var antigravity: ProviderConfig?
}

struct ErrorLogEntry: Codable, Identifiable {
    var id: String { "\(provider.rawValue)-\(at)-\(message.hashValue)" }
    var provider: Provider
    var route: Route
    var message: String
    var at: Int
}

struct ErrorsResponse: Codable {
    var errors: [ErrorLogEntry]
}
