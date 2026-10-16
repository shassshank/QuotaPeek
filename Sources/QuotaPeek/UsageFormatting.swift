import SwiftUI

// MARK: - Shared Metric and Formatting Helpers

extension AccountTrustState {
    var color: Color {
        switch self {
        case .fresh: return .green
        case .stale: return .orange
        case .restored: return .purple
        case .error: return .red
        case .unknown: return .gray
        }
    }
}

enum UsageFormatting {
    static func displayPercent(forUsedPercent used: Double, metric: PercentageMetric) -> Double {
        switch metric {
        case .used:
            return min(max(used, 0), 100)
        case .remaining:
            return min(max(100.0 - used, 0), 100)
        }
    }

    static func colorForPercent(_ percent: Double, metric: PercentageMetric) -> Color {
        switch metric {
        case .used:
            switch percent {
            case ..<60: return .green
            case ..<85: return .yellow
            default: return .red
            }
        case .remaining:
            if percent > 40 {
                return .green
            } else if percent > 15 {
                return .yellow
            } else {
                return .red
            }
        }
    }

    private static let countdownFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    /// "now", "<1m" or e.g. "2h 5m"; with `inPrefix`, future values read "in <1m" / "in 2h 5m".
    static func formatCountdown(_ unixSeconds: Int, inPrefix: Bool = false) -> String {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let prefix = inPrefix ? "in " : ""
        if interval < 60 { return prefix + "<1m" }
        return prefix + (countdownFormatter.string(from: interval) ?? "")
    }

    /// "42s ago", "5m ago", "2h ago"; with `detailed`, "5m12s ago" / "2h5m ago".
    static func syncAge(_ unixSeconds: Int64, detailed: Bool = false) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970) - Int(unixSeconds))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return detailed ? "\(minutes)m\(seconds % 60)s ago" : "\(minutes)m ago"
        }
        let hours = minutes / 60
        return detailed ? "\(hours)h\(minutes % 60)m ago" : "\(hours)h ago"
    }
}
