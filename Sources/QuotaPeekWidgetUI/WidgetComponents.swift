import QuotaPeekCore
import SwiftUI

/// One metric of one row, resolved for display.
struct MetricValue: Identifiable {
    var id: WidgetMetricKind { kind }
    let kind: WidgetMetricKind
    let shortLabel: String
    let title: String
    let used: Double
    let resetsAt: Int?

    func display(_ metric: PercentageMetric) -> (value: Double, color: Color) {
        UsageFormatting.displayPercentAndColor(forUsedPercent: used, metric: metric)
    }

    func percentString(_ metric: PercentageMetric) -> String {
        "\(Int(display(metric).value.rounded()))%"
    }

    func metricWord(_ metric: PercentageMetric) -> String {
        metric == .remaining ? "left" : "used"
    }

    func qualifiedLabel(_ metric: PercentageMetric) -> String {
        "\(shortLabel) \(metricWord(metric))"
    }

    func fullQualifiedLabel(_ metric: PercentageMetric) -> String {
        "\(title) \(metricWord(metric))"
    }
}

extension QuotaWidgetContent {
    /// The row's visible metrics in display order (5h first, then weekly).
    func metricValues(for row: DisplayedAccount) -> [MetricValue] {
        guard let data = row.data else { return [] }
        let visible = metrics(for: row)
        var out: [MetricValue] = []
        if visible.contains(.fiveHour), let p = data.usedPercent5h {
            out.append(MetricValue(kind: .fiveHour, shortLabel: "5h", title: "5-hour", used: p, resetsAt: data.resetsAt5h))
        }
        if visible.contains(.weekly), let p = data.usedPercentWeekly {
            out.append(MetricValue(kind: .weekly, shortLabel: "Wk", title: "Weekly", used: p, resetsAt: data.resetsAtWeekly))
        }
        return out
    }

    var metricWord: String {
        metric == .remaining ? "left" : "used"
    }

    var hasStaleOrRestoredRows: Bool {
        rows.contains { $0.state == .stale || $0.state == .restored }
    }

    func staleSyncNote(now: Date) -> String? {
        guard hasStaleOrRestoredRows, let latest = rows.compactMap(\.asOf).max() else { return nil }
        return "Updated \(UsageFormatting.syncAge(latest, now: now))"
    }
}

/// Compact trust-state badge for non-fresh accounts (all text >= 11pt).
struct StateIndicator: View {
    let state: AccountTrustState
    var compact: Bool = false

    var body: some View {
        switch state {
        case .fresh:
            EmptyView()
        case .stale, .restored, .error, .unknown:
            if compact {
                StatusDot(color: state.color, size: 7)
                    .accessibilityLabel(state.displayName)
            } else {
                Text(state == .unknown ? "No data" : state.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.color)
                    .lineLimit(1)
            }
        }
    }
}

/// Provider SF Symbol + account name (+ optional label and non-fresh state).
struct AccountIdentityHeader: View {
    let row: DisplayedAccount
    var fontSize: CGFloat = 13
    var showLabel: Bool = true
    var compactState: Bool = false
    var now: Date? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: row.symbolName)
                .font(.system(size: max(11, fontSize - 1), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: fontSize + 2)
            Text(row.displayName)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if showLabel, let label = row.visibleLabel {
                Text(label)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if compactState, row.state == .stale, let now, let asOf = row.asOf {
                HStack(spacing: 4) {
                    Text(UsageFormatting.syncAge(asOf, now: now))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    StatusDot(color: row.state.color, size: 7)
                }
            } else {
                StateIndicator(state: row.state, compact: compactState)
            }
        }
    }
}

/// Clean horizontal bar row: "5h  [====---]  58%  2h 14m"
struct LinearMetricLine: View {
    let value: MetricValue
    let metric: PercentageMetric
    let now: Date
    var barHeight: CGFloat = 5
    var showCountdown: Bool = true
    var labelWidth: CGFloat = 20
    var spacing: CGFloat = 6
    var percentMinWidth: CGFloat = 32

    var body: some View {
        let (pct, color) = value.display(metric)
        HStack(spacing: spacing) {
            Text(value.shortLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            WidgetBarTrack(percent: pct, color: color, height: barHeight)

            Text(value.percentString(metric))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(minWidth: percentMinWidth, alignment: .trailing)

            if showCountdown, let reset = value.resetsAt {
                Text(UsageFormatting.formatCountdown(reset, now: now))
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact inline metric pair used in Medium/Large secondary account rows.
struct CompactAccountRow: View {
    let row: DisplayedAccount
    let content: QuotaWidgetContent

    var body: some View {
        let values = content.metricValues(for: row)
        HStack(spacing: 6) {
            Image(systemName: row.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(row.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if values.isEmpty || row.state == .error || row.state == .unknown {
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
            } else {
                HStack(spacing: 10) {
                    ForEach(values) { value in
                        let (_, color) = value.display(content.metric)
                        HStack(spacing: 4) {
                            StatusDot(color: color, size: 6)
                            Text("\(value.shortLabel) \(value.percentString(content.metric))")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            StateIndicator(state: row.state, compact: true)
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }
}

/// Shown when a row has no usable numbers.
struct RowPlaceholderText: View {
    let row: DisplayedAccount
    let hasMetricsSelected: Bool

    var body: some View {
        Text(!hasMetricsSelected ? "No metrics" : row.state == .error ? "Error" : "No data")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Subtle bottom line for metric mode, overflow count, or stale update timestamp.
struct WidgetFooterBar: View {
    let leading: String?
    let trailing: String?

    var body: some View {
        if leading != nil || trailing != nil {
            HStack(spacing: 6) {
                if let leading {
                    Text(leading)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
        }
    }
}

/// Empty / app-not-running / error states.
struct MessageView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
