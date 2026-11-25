import QuotaPeekCore
import SwiftUI

// Building blocks for the widget styles. Visual language follows the desktop
// panel (same gauges, colours, labels) so both surfaces read the same.

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

    func percentText(_ metric: PercentageMetric) -> String {
        "\(Int(display(metric).value.rounded()))%" + (metric == .remaining ? "r" : "")
    }
}

extension QuotaWidgetContent {
    /// The row's visible metrics in display order (5h first, then weekly).
    func metricValues(for row: DisplayedAccount) -> [MetricValue] {
        guard let data = row.data else { return [] }
        let visible = metrics(for: row)
        var out: [MetricValue] = []
        if visible.contains(.fiveHour), let p = data.usedPercent5h {
            out.append(MetricValue(kind: .fiveHour, shortLabel: "5h", title: "5h window", used: p, resetsAt: data.resetsAt5h))
        }
        if visible.contains(.weekly), let p = data.usedPercentWeekly {
            out.append(MetricValue(kind: .weekly, shortLabel: "Wk", title: "Weekly", used: p, resetsAt: data.resetsAtWeekly))
        }
        return out
    }
}

struct StateBadge: View {
    let state: AccountTrustState

    var body: some View {
        switch state {
        case .fresh:
            EmptyView()
        case .stale, .restored, .error, .unknown:
            CapsuleBadge(text: state == .unknown ? "No data" : state.displayName, color: state.color,
                         font: .system(size: 8, weight: .semibold), hPadding: 4, vPadding: 1)
        }
    }
}

struct IdentityRow: View {
    let row: DisplayedAccount
    var nameFont: Font = .system(size: 11, weight: .semibold)
    var showLabel = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.symbolName)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 13)
            Text(row.displayName)
                .font(nameFont)
                .lineLimit(1)
            if showLabel, let label = row.visibleLabel {
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            StateBadge(state: row.state)
        }
    }
}

/// "5h ▓▓▓░░ 58% 2h 5m"
struct MetricRow: View {
    let value: MetricValue
    let metric: PercentageMetric
    let now: Date
    var barHeight: CGFloat = 4
    var showCountdown = true

    var body: some View {
        let (pct, color) = value.display(metric)
        HStack(spacing: 5) {
            Text(value.shortLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            LinearProgressBar(percent: pct, color: color, height: barHeight)
            Text(value.percentText(metric))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(minWidth: 30, alignment: .trailing)
            if showCountdown, let reset = value.resetsAt {
                Text(UsageFormatting.formatCountdown(reset, now: now))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A ring with the percentage in the middle and an optional caption below.
struct LabeledRing: View {
    let value: MetricValue
    let metric: PercentageMetric
    var size: CGFloat = 46
    var lineWidth: CGFloat = 5
    var caption: String?

    var body: some View {
        let (pct, color) = value.display(metric)
        VStack(spacing: 3) {
            ZStack {
                CircularRingProgress(percent: pct, color: color, lineWidth: lineWidth, size: size)
                VStack(spacing: 0) {
                    Text(value.percentText(metric))
                        .font(.system(size: max(9, size * 0.24), weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if size >= 60 {
                        Text(value.shortLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: size - lineWidth * 2)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Header shown on medium and large widgets.
struct WidgetHeader: View {
    let content: QuotaWidgetContent
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 9, weight: .semibold))
            Text("QUOTAPEEK")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
            Spacer()
            if let newest = content.rows.compactMap(\.asOf).max() {
                Text(UsageFormatting.syncAge(newest, now: now))
                    .font(.system(size: 8))
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// Shown when a row has no usable numbers.
struct RowPlaceholder: View {
    let row: DisplayedAccount
    let hasMetricsSelected: Bool

    var body: some View {
        Text(!hasMetricsSelected ? "No metrics selected" : row.state == .error ? "Polling error" : "No recent data")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
    }
}

/// "+2 more" when a size can't fit every selected account.
struct OverflowNote: View {
    let hidden: Int

    var body: some View {
        if hidden > 0 {
            Text("+\(hidden) more")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}

struct MessageView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
