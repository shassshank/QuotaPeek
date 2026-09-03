import Foundation

struct WindowUsage: Codable {
    var usedPercent: Double
    var resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }
}

struct ProviderUsage: Codable {
    var fiveHour: WindowUsage?
    var weekly: WindowUsage?
    var updatedAt: Int?
    var planType: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case weekly
        case updatedAt = "updated_at"
        case planType = "plan_type"
        case error
    }
}

struct UsageSnapshot: Codable {
    var claude: ProviderUsage?
    var codex: ProviderUsage?
    var antigravity: ProviderUsage?
}

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex, antigravity
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
}
