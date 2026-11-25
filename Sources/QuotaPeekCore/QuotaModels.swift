import Foundation

// Quota models shared by the QuotaPeek app and its widget extension.

public enum Provider: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    case claude, codex, antigravity
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    public var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "atom"
        }
    }
}

public enum AccountTrustState: String, Codable, Equatable, CaseIterable, Sendable {
    case unknown
    case fresh
    case stale
    case restored
    case error

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .restored: return "Restored"
        case .error: return "Error"
        }
    }
}

/// Usage for one account. Percentages are "used", 0-100; resets are Unix seconds.
public struct ProviderData: Codable, Equatable, Sendable {
    public var usedPercent5h: Double?
    public var resetsAt5h: Int?
    public var usedPercentWeekly: Double?
    public var resetsAtWeekly: Int?
    public var usedPercent5hThirdParty: Double?
    public var resetsAt5hThirdParty: Int?
    public var usedPercentWeeklyThirdParty: Double?
    public var resetsAtWeeklyThirdParty: Int?
    public var contextWindowUsedPercent: Double?

    public init(
        usedPercent5h: Double? = nil,
        resetsAt5h: Int? = nil,
        usedPercentWeekly: Double? = nil,
        resetsAtWeekly: Int? = nil,
        usedPercent5hThirdParty: Double? = nil,
        resetsAt5hThirdParty: Int? = nil,
        usedPercentWeeklyThirdParty: Double? = nil,
        resetsAtWeeklyThirdParty: Int? = nil,
        contextWindowUsedPercent: Double? = nil
    ) {
        self.usedPercent5h = usedPercent5h
        self.resetsAt5h = resetsAt5h
        self.usedPercentWeekly = usedPercentWeekly
        self.resetsAtWeekly = resetsAtWeekly
        self.usedPercent5hThirdParty = usedPercent5hThirdParty
        self.resetsAt5hThirdParty = resetsAt5hThirdParty
        self.usedPercentWeeklyThirdParty = usedPercentWeeklyThirdParty
        self.resetsAtWeeklyThirdParty = resetsAtWeeklyThirdParty
        self.contextWindowUsedPercent = contextWindowUsedPercent
    }

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

    /// The Antigravity Claude/GPT ("third party") pool presented as its own
    /// 5h/weekly pair, or nil when the account reports no such pool.
    public var thirdPartyPool: ProviderData? {
        guard usedPercent5hThirdParty != nil || usedPercentWeeklyThirdParty != nil else { return nil }
        return ProviderData(usedPercent5h: usedPercent5hThirdParty, resetsAt5h: resetsAt5hThirdParty,
                            usedPercentWeekly: usedPercentWeeklyThirdParty, resetsAtWeekly: resetsAtWeeklyThirdParty)
    }

    /// Copy with every window whose reset time is at or before `date` zeroed:
    /// a new window starts empty. Used to pre-schedule widget timeline entries.
    public func afterResets(through date: Date) -> ProviderData {
        let limit = Int(date.timeIntervalSince1970)
        var out = self
        func zero(_ pct: WritableKeyPath<ProviderData, Double?>, _ reset: WritableKeyPath<ProviderData, Int?>) {
            if let at = out[keyPath: reset], at <= limit, out[keyPath: pct] != nil {
                out[keyPath: pct] = 0
                out[keyPath: reset] = nil
            }
        }
        zero(\.usedPercent5h, \.resetsAt5h)
        zero(\.usedPercentWeekly, \.resetsAtWeekly)
        zero(\.usedPercent5hThirdParty, \.resetsAt5hThirdParty)
        zero(\.usedPercentWeeklyThirdParty, \.resetsAtWeeklyThirdParty)
        return out
    }

    /// Reset times after `date`, ascending.
    public func upcomingResets(after date: Date = Date()) -> [Int] {
        let limit = Int(date.timeIntervalSince1970)
        return [resetsAt5h, resetsAtWeekly, resetsAt5hThirdParty, resetsAtWeeklyThirdParty]
            .compactMap { $0 }
            .filter { $0 > limit }
            .sorted()
    }
}

/// Whether percentages represent used quota or remaining quota.
public enum PercentageMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case used = "used"
    case remaining = "remaining"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .used: return "Used"
        case .remaining: return "Remaining"
        }
    }
}

public enum WidgetMetricKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case fiveHour = "5h"
    case weekly = "weekly"
    case context = "context"
    case claudeGptWeekly = "claude_gpt_weekly"

    public static let offerable: [WidgetMetricKind] = [.fiveHour, .weekly]

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .weekly: return "Weekly window"
        case .context: return "Context window"
        case .claudeGptWeekly: return "Claude/GPT quota"
        }
    }
}

/// Layout style shared by the floating desktop panel and the native widget.
public enum DesktopWidgetStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case combinedLinear = "combined_linear"
    case combinedCircular = "combined_circular"
    case perAgentLinear = "per_agent_linear"
    case perAgentCircular = "per_agent_circular"
    case concentricRings = "concentric_rings"
    case singleAgentFocus = "single_agent_focus"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .combinedLinear: return "Combined (linear bars)"
        case .combinedCircular: return "Combined (circular rings)"
        case .perAgentLinear: return "Per-agent (linear bars)"
        case .perAgentCircular: return "Per-agent (circular rings)"
        case .concentricRings: return "Concentric rings (5h / weekly)"
        case .singleAgentFocus: return "Single agent focus"
        }
    }

    /// Styles that show one account at a time.
    public var isSingleAccount: Bool {
        switch self {
        case .perAgentLinear, .perAgentCircular, .singleAgentFocus: return true
        case .combinedLinear, .combinedCircular, .concentricRings: return false
        }
    }
}
