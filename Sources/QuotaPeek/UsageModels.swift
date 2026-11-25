import Foundation
import QuotaPeekCore

// Provider, AccountTrustState and ProviderData live in QuotaPeekCore.

/// Where a reading may come from. The raw values match the config.json the
/// old daemon wrote, so existing settings carry over unchanged.
enum Route: String, Codable, Equatable {
    /// Readings pushed by the agent itself: statusline hooks (Claude,
    /// Antigravity) and session logs (Codex).
    case injection
    /// The web fallback, using the CLI's stored login (Claude, Codex).
    case keychain
    case none
}

struct CredentialLocation: Codable, Equatable {
    static let configDirKind = "config_dir"
    /// Antigravity: identified only through its statusline hook.
    static let hookKind = "hook"

    var kind: String
    var configDir: String?

    init(kind: String, configDir: String? = nil) {
        self.kind = kind
        self.configDir = configDir
    }

    enum CodingKeys: String, CodingKey { case kind, configDir, config_dir }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? Self.configDirKind
        // The daemon's own OAuth token store is gone; those accounts are hook-only now.
        self.kind = kind == "daemon_token" ? Self.hookKind : kind
        self.configDir = (try? c.decodeIfPresent(String.self, forKey: .configDir))
            ?? (try? c.decodeIfPresent(String.self, forKey: .config_dir))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(configDir, forKey: .configDir)
    }
}

/// An account as stored in config.json.
struct AccountConfig: Codable, Equatable, Identifiable {
    var id: String
    var provider: Provider
    var label: String
    var credentialLocation: CredentialLocation

    static func defaultID(for provider: Provider) -> String { "acct_\(provider.rawValue)_default" }

    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "acct_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The account a fresh install starts with for each provider (same as the old daemon).
    static func makeDefault(_ provider: Provider) -> AccountConfig {
        let location: CredentialLocation
        switch provider {
        case .antigravity:
            location = CredentialLocation(kind: CredentialLocation.hookKind)
        case .claude, .codex:
            location = CredentialLocation(kind: CredentialLocation.configDirKind,
                                          configDir: LocalQuotaParser.canonicalConfigDir(nil, provider: provider))
        }
        return AccountConfig(id: defaultID(for: provider), provider: provider, label: "Default", credentialLocation: location)
    }
}

struct ProviderConfig: Codable, Equatable {
    var routesEnabled: [Route]
    var notifyThresholdPercent: Int?

    init(routesEnabled: [Route], notifyThresholdPercent: Int? = nil) {
        self.routesEnabled = routesEnabled
        self.notifyThresholdPercent = notifyThresholdPercent
    }

    static func defaults(for provider: Provider) -> ProviderConfig {
        ProviderConfig(routesEnabled: provider.supportsWebFallback ? [.injection, .keychain] : [.injection])
    }

    enum CodingKeys: String, CodingKey {
        case routes_enabled, routesEnabled, notify_threshold_percent, notifyThresholdPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode each route on its own so one unknown value doesn't drop the rest.
        let raw = (try? c.decode([String].self, forKey: .routes_enabled))
            ?? (try? c.decode([String].self, forKey: .routesEnabled)) ?? []
        self.routesEnabled = raw.compactMap(Route.init(rawValue:)).filter { $0 != .none }
        self.notifyThresholdPercent = (try? c.decodeIfPresent(Int.self, forKey: .notify_threshold_percent))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .notifyThresholdPercent))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(routesEnabled, forKey: .routes_enabled)
        try c.encodeIfPresent(notifyThresholdPercent, forKey: .notify_threshold_percent)
    }
}

/// Everything QuotaPeek persists apart from UI preferences. Stored as
/// config.json in the support folder, in the same shape the old daemon used,
/// so upgrading keeps the user's accounts and settings.
struct AppConfig: Codable, Equatable {
    static let currentVersion = 2

    var version: Int
    var accounts: [AccountConfig]
    var staleAfterSeconds: Int
    var collectionPaused: Bool
    var statuslineShowOtherAgents: Bool
    var claude: ProviderConfig
    var codex: ProviderConfig
    var antigravity: ProviderConfig

    init(
        accounts: [AccountConfig] = Provider.allCases.map(AccountConfig.makeDefault),
        staleAfterSeconds: Int = 600,
        collectionPaused: Bool = false,
        statuslineShowOtherAgents: Bool = true,
        claude: ProviderConfig = .defaults(for: .claude),
        codex: ProviderConfig = .defaults(for: .codex),
        antigravity: ProviderConfig = .defaults(for: .antigravity)
    ) {
        self.version = Self.currentVersion
        self.accounts = accounts
        self.staleAfterSeconds = staleAfterSeconds
        self.collectionPaused = collectionPaused
        self.statuslineShowOtherAgents = statuslineShowOtherAgents
        self.claude = claude
        self.codex = codex
        self.antigravity = antigravity
    }

    func config(for provider: Provider) -> ProviderConfig {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        case .antigravity: return antigravity
        }
    }

    mutating func setConfig(_ value: ProviderConfig, for provider: Provider) {
        switch provider {
        case .claude: claude = value
        case .codex: codex = value
        case .antigravity: antigravity = value
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, accounts, claude, codex, antigravity
        case staleAfterSeconds, stale_after_seconds
        case collectionPaused, collection_paused
        case statusline_show_other_agents, statuslineShowOtherAgents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fileVersion = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        self.version = Self.currentVersion
        self.accounts = ((try? c.decodeIfPresent([LossyAccount].self, forKey: .accounts)) ?? nil)?
            .compactMap(\.value) ?? Provider.allCases.map(AccountConfig.makeDefault)
        self.staleAfterSeconds = max(60, (try? c.decodeIfPresent(Int.self, forKey: .staleAfterSeconds))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .stale_after_seconds)) ?? 600)
        self.collectionPaused = (try? c.decodeIfPresent(Bool.self, forKey: .collectionPaused))
            ?? (try? c.decodeIfPresent(Bool.self, forKey: .collection_paused)) ?? false
        self.statuslineShowOtherAgents = (try? c.decodeIfPresent(Bool.self, forKey: .statusline_show_other_agents))
            ?? (try? c.decodeIfPresent(Bool.self, forKey: .statuslineShowOtherAgents)) ?? true
        func provider(_ key: CodingKeys, _ p: Provider) -> ProviderConfig {
            ((try? c.decodeIfPresent(ProviderConfig.self, forKey: key)) ?? nil) ?? .defaults(for: p)
        }
        self.claude = provider(.claude, .claude)
        self.codex = provider(.codex, .codex)
        self.antigravity = provider(.antigravity, .antigravity)
        if fileVersion < 2 { migrateFromDaemon() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(staleAfterSeconds, forKey: .staleAfterSeconds)
        try c.encode(collectionPaused, forKey: .collectionPaused)
        try c.encode(statuslineShowOtherAgents, forKey: .statusline_show_other_agents)
        try c.encode(claude, forKey: .claude)
        try c.encode(codex, forKey: .codex)
        try c.encode(antigravity, forKey: .antigravity)
    }

    /// The daemon's routes meant something slightly different: Codex had no
    /// local route (session logs are read now), and Antigravity's web route
    /// used a token the daemon kept itself, which no longer exists. A provider
    /// the user had switched off entirely stays off.
    private mutating func migrateFromDaemon() {
        for p in Provider.allCases {
            var cfg = config(for: p)
            guard !cfg.routesEnabled.isEmpty else { continue }
            if !p.supportsWebFallback { cfg.routesEnabled.removeAll { $0 == .keychain } }
            if p == .codex || cfg.routesEnabled.isEmpty, !cfg.routesEnabled.contains(.injection) {
                cfg.routesEnabled.insert(.injection, at: 0)
            }
            setConfig(cfg, for: p)
        }
    }

    /// Skips account entries this version can't read instead of losing them all.
    private struct LossyAccount: Decodable {
        let value: AccountConfig?
        init(from decoder: Decoder) throws { value = try? AccountConfig(from: decoder) }
    }
}

extension Provider {
    /// Claude and Codex expose a usage endpoint the CLI's own login can read.
    var supportsWebFallback: Bool { self != .antigravity }
}

/// What the UI shows for one account: its configuration plus the latest reading.
struct Account: Identifiable, Equatable {
    var id: String
    var provider: Provider
    var label: String
    var credentialLocation: CredentialLocation?
    var routesEnabled: [Route]
    /// Where the current numbers came from.
    var activeRoute: Route
    var data: ProviderData?
    /// Unix seconds of the reading in `data`.
    var asOf: Int64?
    /// Why the latest attempt to get numbers failed, if it did.
    var lastError: String?
    var state: AccountTrustState

    init(
        id: String,
        provider: Provider,
        label: String = "Default",
        credentialLocation: CredentialLocation? = nil,
        routesEnabled: [Route] = [],
        activeRoute: Route = .none,
        data: ProviderData? = nil,
        asOf: Int64? = nil,
        lastError: String? = nil,
        state: AccountTrustState = .unknown
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.credentialLocation = credentialLocation
        self.routesEnabled = routesEnabled
        self.activeRoute = activeRoute
        self.data = data
        self.asOf = asOf
        self.lastError = lastError
        self.state = state
    }

    var displayLastError: String? {
        guard let lastError, !lastError.isEmpty else { return nil }
        return lastError
    }
}

/// Result of checking one route from Settings.
struct RouteCheckResult: Equatable {
    var ok: Bool
    var message: String
}
