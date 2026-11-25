import Foundation
import QuotaPeekCore

// Provider, AccountTrustState and ProviderData live in QuotaPeekCore.

/// Where a reading may come from.
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

    /// The account a fresh install starts with for each provider.
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

    enum CodingKeys: String, CodingKey { case routesEnabled, notifyThresholdPercent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode each route on its own so one unknown value doesn't drop the rest.
        let raw = (try? c.decode([String].self, forKey: .routesEnabled)) ?? []
        self.routesEnabled = raw.compactMap(Route.init(rawValue:)).filter { $0 != .none }
        self.notifyThresholdPercent = try? c.decodeIfPresent(Int.self, forKey: .notifyThresholdPercent)
    }
}

/// Everything QuotaPeek persists apart from UI preferences, stored as
/// config.json in the support folder. Missing fields take their defaults.
struct AppConfig: Codable, Equatable {
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
        case accounts, staleAfterSeconds, collectionPaused, statuslineShowOtherAgents, claude, codex, antigravity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accounts = ((try? c.decodeIfPresent([LossyAccount].self, forKey: .accounts)) ?? nil)?
            .compactMap(\.value) ?? Provider.allCases.map(AccountConfig.makeDefault)
        self.staleAfterSeconds = max(60, (try? c.decodeIfPresent(Int.self, forKey: .staleAfterSeconds)) ?? 600)
        self.collectionPaused = (try? c.decodeIfPresent(Bool.self, forKey: .collectionPaused)) ?? false
        self.statuslineShowOtherAgents = (try? c.decodeIfPresent(Bool.self, forKey: .statuslineShowOtherAgents)) ?? true
        func provider(_ key: CodingKeys, _ p: Provider) -> ProviderConfig {
            ((try? c.decodeIfPresent(ProviderConfig.self, forKey: key)) ?? nil) ?? .defaults(for: p)
        }
        self.claude = provider(.claude, .claude)
        self.codex = provider(.codex, .codex)
        self.antigravity = provider(.antigravity, .antigravity)
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
