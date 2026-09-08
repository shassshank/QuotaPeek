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

enum AccountTrustState: String, Codable, Equatable, CaseIterable {
    case unknown
    case fresh
    case stale
    case restored
    case error

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .restored: return "Restored"
        case .error: return "Error"
        }
    }
}

struct CredentialLocation: Codable, Equatable {
    var kind: String // "config_dir" | "daemon_token"
    var configDir: String? // required when kind == "config_dir"

    enum CodingKeys: String, CodingKey {
        case kind
        case configDir = "configDir"
        case configDirSnake = "config_dir"
    }

    init(kind: String, configDir: String? = nil) {
        self.kind = kind
        self.configDir = configDir
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(String.self, forKey: .kind)
        self.configDir = (try? container.decodeIfPresent(String.self, forKey: .configDir))
            ?? (try? container.decodeIfPresent(String.self, forKey: .configDirSnake))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(configDir, forKey: .configDir)
    }
}

struct OAuthBootstrap: Codable, Equatable {
    var refreshToken: String
    var email: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refreshToken"
        case refreshTokenSnake = "refresh_token"
        case email
    }

    init(refreshToken: String, email: String) {
        self.refreshToken = refreshToken
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.refreshToken = (try? container.decode(String.self, forKey: .refreshToken))
            ?? (try? container.decode(String.self, forKey: .refreshTokenSnake))
            ?? ""
        self.email = (try? container.decode(String.self, forKey: .email)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(email, forKey: .email)
    }
}

struct CreateAccountRequest: Codable {
    var provider: Provider
    var label: String
    var credentialLocation: CredentialLocation
    var oauthBootstrap: OAuthBootstrap?

    enum CodingKeys: String, CodingKey {
        case provider
        case label
        case credentialLocation = "credentialLocation"
        case credentialLocationSnake = "credential_location"
        case oauthBootstrap = "oauthBootstrap"
        case oauthBootstrapSnake = "oauth_bootstrap"
    }

    init(
        provider: Provider,
        label: String,
        credentialLocation: CredentialLocation,
        oauthBootstrap: OAuthBootstrap? = nil
    ) {
        self.provider = provider
        self.label = label
        self.credentialLocation = credentialLocation
        self.oauthBootstrap = oauthBootstrap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(Provider.self, forKey: .provider)
        self.label = try container.decode(String.self, forKey: .label)
        self.credentialLocation = try (container.decodeIfPresent(CredentialLocation.self, forKey: .credentialLocation)
            ?? container.decode(CredentialLocation.self, forKey: .credentialLocationSnake))
        self.oauthBootstrap = (try? container.decodeIfPresent(OAuthBootstrap.self, forKey: .oauthBootstrap))
            ?? (try? container.decodeIfPresent(OAuthBootstrap.self, forKey: .oauthBootstrapSnake))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encode(credentialLocation, forKey: .credentialLocation)
        try container.encodeIfPresent(oauthBootstrap, forKey: .oauthBootstrap)
    }
}

struct UpdateAccountRequest: Codable {
    var label: String
}

struct ProviderData: Codable, Equatable {
    var usedPercent5h: Double?
    var resetsAt5h: Int?
    var usedPercentWeekly: Double?
    var resetsAtWeekly: Int?
    var usedPercent5hThirdParty: Double?
    var resetsAt5hThirdParty: Int?
    var usedPercentWeeklyThirdParty: Double?
    var resetsAtWeeklyThirdParty: Int?
    var contextWindowUsedPercent: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent5h = "used_percent_5h"
        case resetsAt5h = "resets_at_5h"
        case usedPercentWeekly = "used_percent_weekly"
        case resetsAtWeekly = "resets_at_weekly"
        case usedPercent5hThirdParty = "used_percent_5h_third_party"
        case resetsAt5hThirdParty = "resets_at_5h_third_party"
        case usedPercentWeeklyThirdParty = "used_percent_weekly_third_party"
        case resetsAtWeeklyThirdParty = "resets_at_weekly_third_party"
        case contextWindowUsedPercent = "context_window_used_percent"
    }
}

struct ProviderError: Codable, Equatable {
    var route: Route
    var message: String
    var at: Int
}

struct Account: Codable, Identifiable, Equatable {
    var id: String
    var provider: Provider
    var label: String
    var credentialLocation: CredentialLocation?
    var credentialSource: String?
    var effectiveAccount: String?
    var lastSuccessAt: Int64?
    var lastFailureAt: Int64?
    var lastError: String?
    var routesEnabled: [Route]
    var activeRoute: Route
    var data: ProviderData?
    var asOf: Int64?
    var lastErrorObject: ProviderError?
    var restoredFromDisk: Bool
    var state: AccountTrustState

    /// Convenience accessors
    var isRestoredFromDisk: Bool {
        restoredFromDisk || state == .restored
    }

    var displayLastError: String? {
        if let errStr = lastError, !errStr.isEmpty {
            return errStr
        }
        return lastErrorObject?.message
    }

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case credentialLocation = "credentialLocation"
        case credentialLocationSnake = "credential_location"
        case credentialSource = "credentialSource"
        case credentialSourceSnake = "credential_source"
        case effectiveAccount = "effectiveAccount"
        case effectiveAccountSnake = "effective_account"
        case lastSuccessAt = "lastSuccessAt"
        case lastSuccessAtSnake = "last_success_at"
        case lastFailureAt = "lastFailureAt"
        case lastFailureAtSnake = "last_failure_at"
        case lastError = "lastError"
        case lastErrorSnake = "last_error"
        case routesEnabled = "routes_enabled"
        case routesEnabledCamel = "routesEnabled"
        case activeRoute = "active_route"
        case activeRouteCamel = "activeRoute"
        case data
        case asOf = "as_of"
        case asOfCamel = "asOf"
        case restoredFromDisk = "restoredFromDisk"
        case restoredFromDiskSnake = "restored_from_disk"
        case state
    }

    init(
        id: String,
        provider: Provider,
        label: String = "Default",
        credentialLocation: CredentialLocation? = nil,
        credentialSource: String? = nil,
        effectiveAccount: String? = nil,
        lastSuccessAt: Int64? = nil,
        lastFailureAt: Int64? = nil,
        lastError: String? = nil,
        routesEnabled: [Route] = [],
        activeRoute: Route = .none,
        data: ProviderData? = nil,
        asOf: Int64? = nil,
        lastErrorObject: ProviderError? = nil,
        restoredFromDisk: Bool = false,
        state: AccountTrustState = .unknown
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.credentialLocation = credentialLocation
        self.credentialSource = credentialSource
        self.effectiveAccount = effectiveAccount
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.lastError = lastError
        self.routesEnabled = routesEnabled
        self.activeRoute = activeRoute
        self.data = data
        self.asOf = asOf
        self.lastErrorObject = lastErrorObject
        self.restoredFromDisk = restoredFromDisk
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode id (or fallback to provider rawValue if legacy)
        let rawId = (try? container.decode(String.self, forKey: .id)) ?? "unknown"
        self.id = rawId

        // Decode provider (or derive from id if legacy)
        if let prov = try? container.decode(Provider.self, forKey: .provider) {
            self.provider = prov
        } else if let prov = Provider(rawValue: rawId) {
            self.provider = prov
        } else {
            self.provider = .claude
        }

        self.label = (try? container.decode(String.self, forKey: .label)) ?? "Default"

        self.credentialLocation = (try? container.decodeIfPresent(CredentialLocation.self, forKey: .credentialLocation))
            ?? (try? container.decodeIfPresent(CredentialLocation.self, forKey: .credentialLocationSnake))

        self.credentialSource = (try? container.decodeIfPresent(String.self, forKey: .credentialSource))
            ?? (try? container.decodeIfPresent(String.self, forKey: .credentialSourceSnake))

        self.effectiveAccount = (try? container.decodeIfPresent(String.self, forKey: .effectiveAccount))
            ?? (try? container.decodeIfPresent(String.self, forKey: .effectiveAccountSnake))

        self.lastSuccessAt = (try? container.decodeIfPresent(Int64.self, forKey: .lastSuccessAt))
            ?? (try? container.decodeIfPresent(Int64.self, forKey: .lastSuccessAtSnake))

        self.lastFailureAt = (try? container.decodeIfPresent(Int64.self, forKey: .lastFailureAt))
            ?? (try? container.decodeIfPresent(Int64.self, forKey: .lastFailureAtSnake))

        // Decode last_error: can be a String or a ProviderError object
        if let errObj = try? container.decodeIfPresent(ProviderError.self, forKey: .lastErrorSnake) {
            self.lastErrorObject = errObj
            self.lastError = errObj.message
        } else if let errObj = try? container.decodeIfPresent(ProviderError.self, forKey: .lastError) {
            self.lastErrorObject = errObj
            self.lastError = errObj.message
        } else if let errStr = try? container.decodeIfPresent(String.self, forKey: .lastError) {
            self.lastError = errStr
            self.lastErrorObject = nil
        } else if let errStr = try? container.decodeIfPresent(String.self, forKey: .lastErrorSnake) {
            self.lastError = errStr
            self.lastErrorObject = nil
        } else {
            self.lastError = nil
            self.lastErrorObject = nil
        }

        self.routesEnabled = (try? container.decode([Route].self, forKey: .routesEnabled))
            ?? (try? container.decode([Route].self, forKey: .routesEnabledCamel))
            ?? []

        self.activeRoute = (try? container.decode(Route.self, forKey: .activeRoute))
            ?? (try? container.decode(Route.self, forKey: .activeRouteCamel))
            ?? .none

        self.data = try? container.decodeIfPresent(ProviderData.self, forKey: .data)

        if let asOfInt64 = try? container.decodeIfPresent(Int64.self, forKey: .asOf) {
            self.asOf = asOfInt64
        } else if let asOfInt = try? container.decodeIfPresent(Int.self, forKey: .asOf) {
            self.asOf = Int64(asOfInt)
        } else if let asOfInt64 = try? container.decodeIfPresent(Int64.self, forKey: .asOfCamel) {
            self.asOf = asOfInt64
        } else if let asOfInt = try? container.decodeIfPresent(Int.self, forKey: .asOfCamel) {
            self.asOf = Int64(asOfInt)
        } else {
            self.asOf = nil
        }

        self.restoredFromDisk = (try? container.decodeIfPresent(Bool.self, forKey: .restoredFromDisk))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .restoredFromDiskSnake))
            ?? false

        if let st = try? container.decodeIfPresent(AccountTrustState.self, forKey: .state) {
            self.state = st
        } else {
            self.state = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(credentialLocation, forKey: .credentialLocation)
        try container.encodeIfPresent(credentialSource, forKey: .credentialSource)
        try container.encodeIfPresent(effectiveAccount, forKey: .effectiveAccount)
        try container.encodeIfPresent(lastSuccessAt, forKey: .lastSuccessAt)
        try container.encodeIfPresent(lastFailureAt, forKey: .lastFailureAt)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(routesEnabled, forKey: .routesEnabled)
        try container.encode(activeRoute, forKey: .activeRoute)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(asOf, forKey: .asOf)
        try container.encode(restoredFromDisk, forKey: .restoredFromDisk)
        try container.encode(state, forKey: .state)
    }
}

/// Backward compatibility alias during transition
typealias ProviderStatus = Account

struct StatusResponse: Codable {
    var accounts: [Account]

    enum CodingKeys: String, CodingKey {
        case accounts
        case providers
    }

    init(accounts: [Account] = []) {
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let accs = try? container.decode([Account].self, forKey: .accounts) {
            self.accounts = accs
        } else if let provs = try? container.decode([Account].self, forKey: .providers) {
            self.accounts = provs
        } else {
            self.accounts = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accounts, forKey: .accounts)
    }
}

struct AccountsResponse: Codable {
    var accounts: [Account]

    enum CodingKeys: String, CodingKey {
        case accounts
    }

    init(accounts: [Account] = []) {
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accounts = (try? container.decode([Account].self, forKey: .accounts)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accounts, forKey: .accounts)
    }
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
    var staleAfterSeconds: Int?
    var collectionPaused: Bool?
    var statuslineShowOtherAgents: Bool?

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
        case statuslineShowOtherAgentsSnake = "statusline_show_other_agents"
        case statuslineShowOtherAgentsCamel = "statuslineShowOtherAgents"
    }

    init(
        claudePollingMode: String? = nil,
        claude: ProviderConfig? = nil,
        codex: ProviderConfig? = nil,
        antigravity: ProviderConfig? = nil,
        staleAfterSeconds: Int? = nil,
        collectionPaused: Bool? = nil,
        statuslineShowOtherAgents: Bool? = nil
    ) {
        self.claudePollingMode = claudePollingMode
        self.claude = claude
        self.codex = codex
        self.antigravity = antigravity
        self.staleAfterSeconds = staleAfterSeconds
        self.collectionPaused = collectionPaused
        self.statuslineShowOtherAgents = statuslineShowOtherAgents
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
        self.statuslineShowOtherAgents = (try? container.decodeIfPresent(Bool.self, forKey: .statuslineShowOtherAgentsSnake))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .statuslineShowOtherAgentsCamel))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(claudePollingMode, forKey: .claudePollingMode)
        try container.encodeIfPresent(claude, forKey: .claude)
        try container.encodeIfPresent(codex, forKey: .codex)
        try container.encodeIfPresent(antigravity, forKey: .antigravity)
        try container.encodeIfPresent(staleAfterSeconds, forKey: .staleAfterSecondsCamel)
        try container.encodeIfPresent(collectionPaused, forKey: .collectionPausedCamel)
        try container.encodeIfPresent(statuslineShowOtherAgents, forKey: .statuslineShowOtherAgentsSnake)
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
    var accountId: String
    var provider: Provider
    var route: Route
}

struct TestRouteResponse: Codable {
    var ok: Bool
    var provider: Provider?
    var route: Route?
    var message: String?
}

struct ResetCredentialsResponse: Codable {
    var ok: Bool?
    var provider: String?
    var message: String?
}

struct SimpleSuccessResponse: Codable {
    var ok: Bool
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

// MARK: - History Models

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
