import Foundation

/// Types mirror API_CONTRACT.md - the Go daemon is the source of truth for these shapes.

enum Provider: String, CaseIterable, Identifiable, Codable, Equatable {
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

enum Route: String, Codable, Equatable {
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

    // Round 2 Status API additions
    var credentialSource: String?
    var effectiveAccount: String?
    var lastSuccessAt: Int64?
    var lastFailureAt: Int64?
    var lastErrorString: String?

    // Round 3 Status API additions: restart-staleness indicator
    var restoredFromDisk: Bool?
    var staleSinceRestart: Bool?

    /// True if this provider's data was restored from disk and has not had a fresh poll yet.
    var isRestoredFromDisk: Bool {
        if let r = restoredFromDisk, r { return true }
        if let s = staleSinceRestart, s { return true }
        return false
    }

    /// Human-readable error message from either `lastErrorString` or `lastError.message`.
    var displayLastError: String? {
        if let errStr = lastErrorString, !errStr.isEmpty {
            return errStr
        }
        return lastError?.message
    }

    enum CodingKeys: String, CodingKey {
        case provider = "id"
        case routesEnabled = "routes_enabled"
        case routesEnabledCamel = "routesEnabled"
        case activeRoute = "active_route"
        case activeRouteCamel = "activeRoute"
        case data
        case asOf = "as_of"
        case asOfCamel = "asOf"
        case lastError = "last_error"
        case lastErrorCamel = "lastError"
        case credentialSourceSnake = "credential_source"
        case credentialSourceCamel = "credentialSource"
        case effectiveAccountSnake = "effective_account"
        case effectiveAccountCamel = "effectiveAccount"
        case lastSuccessAtSnake = "last_success_at"
        case lastSuccessAtCamel = "lastSuccessAt"
        case lastFailureAtSnake = "last_failure_at"
        case lastFailureAtCamel = "lastFailureAt"
        case restoredFromDiskCamel = "restoredFromDisk"
        case restoredFromDiskSnake = "restored_from_disk"
        case staleSinceRestartCamel = "staleSinceRestart"
        case staleSinceRestartSnake = "stale_since_restart"
        case restored
    }

    init(
        provider: Provider,
        routesEnabled: [Route],
        activeRoute: Route,
        data: ProviderData? = nil,
        asOf: Int? = nil,
        lastError: ProviderError? = nil,
        credentialSource: String? = nil,
        effectiveAccount: String? = nil,
        lastSuccessAt: Int64? = nil,
        lastFailureAt: Int64? = nil,
        lastErrorString: String? = nil,
        restoredFromDisk: Bool? = nil,
        staleSinceRestart: Bool? = nil
    ) {
        self.provider = provider
        self.routesEnabled = routesEnabled
        self.activeRoute = activeRoute
        self.data = data
        self.asOf = asOf
        self.lastError = lastError
        self.credentialSource = credentialSource
        self.effectiveAccount = effectiveAccount
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.lastErrorString = lastErrorString
        self.restoredFromDisk = restoredFromDisk
        self.staleSinceRestart = staleSinceRestart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(Provider.self, forKey: .provider)
        self.routesEnabled = (try? container.decode([Route].self, forKey: .routesEnabled))
            ?? (try? container.decode([Route].self, forKey: .routesEnabledCamel))
            ?? []
        self.activeRoute = (try? container.decode(Route.self, forKey: .activeRoute))
            ?? (try? container.decode(Route.self, forKey: .activeRouteCamel))
            ?? .none
        self.data = try? container.decodeIfPresent(ProviderData.self, forKey: .data)
        self.asOf = (try? container.decodeIfPresent(Int.self, forKey: .asOf))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .asOfCamel))

        // Decode last_error / lastError either as ProviderError object or as a String
        if let errObj = try? container.decodeIfPresent(ProviderError.self, forKey: .lastError) {
            self.lastError = errObj
            self.lastErrorString = errObj.message
        } else if let errObj = try? container.decodeIfPresent(ProviderError.self, forKey: .lastErrorCamel) {
            self.lastError = errObj
            self.lastErrorString = errObj.message
        } else if let errStr = try? container.decodeIfPresent(String.self, forKey: .lastError) {
            self.lastErrorString = errStr
            self.lastError = ProviderError(route: .none, message: errStr, at: Int(Date().timeIntervalSince1970))
        } else if let errStr = try? container.decodeIfPresent(String.self, forKey: .lastErrorCamel) {
            self.lastErrorString = errStr
            self.lastError = ProviderError(route: .none, message: errStr, at: Int(Date().timeIntervalSince1970))
        } else {
            self.lastError = nil
            self.lastErrorString = nil
        }

        self.credentialSource = (try? container.decodeIfPresent(String.self, forKey: .credentialSourceSnake))
            ?? (try? container.decodeIfPresent(String.self, forKey: .credentialSourceCamel))

        self.effectiveAccount = (try? container.decodeIfPresent(String.self, forKey: .effectiveAccountSnake))
            ?? (try? container.decodeIfPresent(String.self, forKey: .effectiveAccountCamel))

        self.lastSuccessAt = (try? container.decodeIfPresent(Int64.self, forKey: .lastSuccessAtSnake))
            ?? (try? container.decodeIfPresent(Int64.self, forKey: .lastSuccessAtCamel))

        self.lastFailureAt = (try? container.decodeIfPresent(Int64.self, forKey: .lastFailureAtSnake))
            ?? (try? container.decodeIfPresent(Int64.self, forKey: .lastFailureAtCamel))

        // Decode restart staleness indicators (accepting bool or non-zero timestamp)
        var restoredVal = (try? container.decodeIfPresent(Bool.self, forKey: .restoredFromDiskCamel))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .restoredFromDiskSnake))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .restored))
        if restoredVal == nil, let val = try? container.decodeIfPresent(Int64.self, forKey: .restoredFromDiskCamel) {
            restoredVal = (val != 0)
        }
        self.restoredFromDisk = restoredVal

        var staleRestartVal = (try? container.decodeIfPresent(Bool.self, forKey: .staleSinceRestartCamel))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .staleSinceRestartSnake))
        if staleRestartVal == nil, let val = try? container.decodeIfPresent(Int64.self, forKey: .staleSinceRestartCamel) {
            staleRestartVal = (val != 0)
        }
        self.staleSinceRestart = staleRestartVal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(routesEnabled, forKey: .routesEnabled)
        try container.encode(activeRoute, forKey: .activeRoute)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(asOf, forKey: .asOf)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(credentialSource, forKey: .credentialSourceSnake)
        try container.encodeIfPresent(effectiveAccount, forKey: .effectiveAccountSnake)
        try container.encodeIfPresent(lastSuccessAt, forKey: .lastSuccessAtSnake)
        try container.encodeIfPresent(lastFailureAt, forKey: .lastFailureAtSnake)
        try container.encodeIfPresent(restoredFromDisk, forKey: .restoredFromDiskCamel)
        try container.encodeIfPresent(staleSinceRestart, forKey: .staleSinceRestartCamel)
    }
}

struct StatusResponse: Codable {
    var providers: [ProviderStatus]
}

struct ProviderConfig: Codable, Equatable {
    var routesEnabled: [Route]
    var keychainPollIntervalSec: Int
    var notifyThresholdPercent: Int?

    enum CodingKeys: String, CodingKey {
        case routesEnabled = "routes_enabled"
        case routesEnabledCamel = "routesEnabled"
        case keychainPollIntervalSec = "keychain_poll_interval_sec"
        case keychainPollIntervalSecCamel = "keychainPollIntervalSec"
        case notifyThresholdPercent = "notify_threshold_percent"
        case notifyThresholdPercentCamel = "notifyThresholdPercent"
    }

    init(routesEnabled: [Route], keychainPollIntervalSec: Int, notifyThresholdPercent: Int? = nil) {
        self.routesEnabled = routesEnabled
        self.keychainPollIntervalSec = keychainPollIntervalSec
        self.notifyThresholdPercent = notifyThresholdPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.routesEnabled = (try? container.decode([Route].self, forKey: .routesEnabled))
            ?? (try? container.decode([Route].self, forKey: .routesEnabledCamel))
            ?? []
        self.keychainPollIntervalSec = (try? container.decode(Int.self, forKey: .keychainPollIntervalSec))
            ?? (try? container.decode(Int.self, forKey: .keychainPollIntervalSecCamel))
            ?? 60
        self.notifyThresholdPercent = (try? container.decodeIfPresent(Int.self, forKey: .notifyThresholdPercent))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .notifyThresholdPercentCamel))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(routesEnabled, forKey: .routesEnabled)
        try container.encode(keychainPollIntervalSec, forKey: .keychainPollIntervalSec)
        try container.encodeIfPresent(notifyThresholdPercent, forKey: .notifyThresholdPercent)
    }
}

struct DaemonConfig: Codable, Equatable {
    var claudePollingMode: String?
    var claude: ProviderConfig?
    var codex: ProviderConfig?
    var antigravity: ProviderConfig?

    // Round 2 additions
    var staleAfterSeconds: Int?
    var collectionPaused: Bool?

    enum CodingKeys: String, CodingKey {
        case claudePollingMode = "claude_polling_mode"
        case claudePollingModeCamel = "claudePollingMode"
        case claude
        case codex
        case antigravity
        case staleAfterSecondsSnake = "stale_after_seconds"
        case staleAfterSecondsCamel = "staleAfterSeconds"
        case collectionPausedSnake = "collection_paused"
        case collectionPausedCamel = "collectionPaused"
    }

    init(
        claudePollingMode: String? = nil,
        claude: ProviderConfig? = nil,
        codex: ProviderConfig? = nil,
        antigravity: ProviderConfig? = nil,
        staleAfterSeconds: Int? = nil,
        collectionPaused: Bool? = nil
    ) {
        self.claudePollingMode = claudePollingMode
        self.claude = claude
        self.codex = codex
        self.antigravity = antigravity
        self.staleAfterSeconds = staleAfterSeconds
        self.collectionPaused = collectionPaused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.claudePollingMode = (try? container.decodeIfPresent(String.self, forKey: .claudePollingMode))
            ?? (try? container.decodeIfPresent(String.self, forKey: .claudePollingModeCamel))
        self.claude = try? container.decodeIfPresent(ProviderConfig.self, forKey: .claude)
        self.codex = try? container.decodeIfPresent(ProviderConfig.self, forKey: .codex)
        self.antigravity = try? container.decodeIfPresent(ProviderConfig.self, forKey: .antigravity)
        self.staleAfterSeconds = (try? container.decodeIfPresent(Int.self, forKey: .staleAfterSecondsSnake))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .staleAfterSecondsCamel))
        self.collectionPaused = (try? container.decodeIfPresent(Bool.self, forKey: .collectionPausedSnake))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .collectionPausedCamel))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(claudePollingMode, forKey: .claudePollingMode)
        try container.encodeIfPresent(claude, forKey: .claude)
        try container.encodeIfPresent(codex, forKey: .codex)
        try container.encodeIfPresent(antigravity, forKey: .antigravity)
        try container.encodeIfPresent(staleAfterSeconds, forKey: .staleAfterSecondsCamel)
        try container.encodeIfPresent(collectionPaused, forKey: .collectionPausedCamel)
    }

    func config(for provider: Provider) -> ProviderConfig? {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        case .antigravity: return antigravity
        }
    }
}

struct TestRouteRequest: Codable {
    var provider: Provider
    var route: Route
}

struct TestRouteResponse: Codable {
    var ok: Bool
    var provider: Provider
    var route: Route
    var message: String?
}

struct ResetCredentialsResponse: Codable {
    var ok: Bool?
    var message: String?
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

// MARK: - Round 3 History Models

struct HistoryPoint: Codable, Identifiable {
    var id: String { "\(at)-\(usedPercent)" }
    var at: Int64
    var usedPercent: Double

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(at))
    }

    enum CodingKeys: String, CodingKey {
        case at
        case timestamp
        case time
        case usedPercentCamel = "usedPercent"
        case usedPercentSnake = "used_percent"
        case usedPercentage = "used_percentage"
        case usage
        case percent
    }

    init(at: Int64, usedPercent: Double) {
        self.at = at
        self.usedPercent = usedPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let atVal = try? container.decode(Int64.self, forKey: .at) {
            self.at = atVal
        } else if let atVal = try? container.decode(Int64.self, forKey: .timestamp) {
            self.at = atVal
        } else if let atVal = try? container.decode(Int64.self, forKey: .time) {
            self.at = atVal
        } else if let atDouble = try? container.decode(Double.self, forKey: .at) {
            self.at = Int64(atDouble)
        } else {
            self.at = 0
        }

        if let val = try? container.decode(Double.self, forKey: .usedPercentCamel) {
            self.usedPercent = val
        } else if let val = try? container.decode(Double.self, forKey: .usedPercentSnake) {
            self.usedPercent = val
        } else if let val = try? container.decode(Double.self, forKey: .usedPercentage) {
            self.usedPercent = val
        } else if let val = try? container.decode(Double.self, forKey: .usage) {
            self.usedPercent = val
        } else if let val = try? container.decode(Double.self, forKey: .percent) {
            self.usedPercent = val
        } else {
            self.usedPercent = 0.0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at, forKey: .at)
        try container.encode(usedPercent, forKey: .usedPercentCamel)
    }
}

struct HistoryResponse: Codable {
    var points: [HistoryPoint]

    enum CodingKeys: String, CodingKey {
        case points
        case data
        case history
    }

    init(points: [HistoryPoint] = []) {
        self.points = points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.points = (try? container.decode([HistoryPoint].self, forKey: .points))
            ?? (try? container.decode([HistoryPoint].self, forKey: .data))
            ?? (try? container.decode([HistoryPoint].self, forKey: .history))
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }
}
