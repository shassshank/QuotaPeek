import SwiftUI

// MARK: - Reusable Visual Badges & Gauges

/// A capsule badge with custom or default styling.
struct CapsuleBadge: View {
    let text: String
    let color: Color
    var font: Font = .caption2.weight(.medium)
    var hPadding: CGFloat = 6
    var vPadding: CGFloat = 2

    var body: some View {
        Text(text)
            .font(font)
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A compact linear progress bar with rounded ends and animated fill.
struct LinearProgressBar: View {
    let percent: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: height)

                Capsule()
                    .fill(color)
                    .frame(
                        width: max(0, min(geo.size.width, geo.size.width * CGFloat(min(max(percent, 0), 100) / 100.0))),
                        height: height
                    )
                    .animation(.easeInOut(duration: 0.3), value: percent)
            }
        }
        .frame(height: height)
    }
}

/// A circular progress ring rendered using SwiftUI `Circle().trim`.
struct CircularRingProgress: View {
    let percent: Double
    let color: Color
    var lineWidth: CGFloat = 5
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent / 100.0, 0), 1)))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: percent)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Widget Account Models & Identity

struct WidgetAccount: Identifiable, Equatable {
    let id: String
    let displayName: String
    let symbolName: String
    let label: String
    let state: AccountTrustState
    let displayLastError: String?
    let asOf: Int64?
    let activeRoute: Route
    let isCodex: Bool
    let data: ProviderData?
}

extension WidgetAccount {
    /// Copies label, state, error, sync time and route from `account`.
    init(_ account: Account, id: String, displayName: String, symbolName: String, isCodex: Bool, data: ProviderData?) {
        self.init(id: id, displayName: displayName, symbolName: symbolName, label: account.label, state: account.state,
                  displayLastError: account.displayLastError, asOf: account.asOf, activeRoute: account.activeRoute,
                  isCodex: isCodex, data: data)
    }
}

@ViewBuilder
func widgetAccountLabelBadge(_ label: String) -> some View {
    if !label.isEmpty && label != "Default" {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}

func routePill(for account: WidgetAccount) -> some View {
    let title: String
    let color: Color
    switch account.activeRoute {
    case .injection:
        if account.isCodex {
            title = "RPC"
            color = .blue
        } else if account.state == .fresh {
            title = "Live"
            color = .green
        } else {
            title = "Injection"
            color = .secondary
        }
    case .keychain:
        title = "Polled"
        color = .blue
    default:
        title = "Inactive"
        color = .gray
    }

    return CapsuleBadge(text: title, color: color, font: .system(size: 9, weight: .semibold))
}

@ViewBuilder
func freshnessBadge(for account: WidgetAccount) -> some View {
    if account.state == .restored || account.state == .stale {
        let color: Color = account.state == .restored ? .purple : .orange
        Text(account.state == .restored ? "Last known — stale since restart" : "Stale")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct FocusAccountHeader: View {
    let account: WidgetAccount
    var iconFont: Font = .title3.weight(.bold)
    var nameFont: Font = .subheadline.weight(.bold)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.symbolName)
                .font(iconFont)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(account.displayName)
                        .font(nameFont)
                    widgetAccountLabelBadge(account.label)
                }

                freshnessBadge(for: account)

                if let asOf = account.asOf {
                    Text(UsageFormatting.syncAge(asOf))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            routePill(for: account)
        }
    }
}

// MARK: - Shared Metric Calculation & Display Helpers

func displayPercentAndColor(forUsedPercent used: Double, metric: PercentageMetric) -> (value: Double, color: Color) {
    let val = UsageFormatting.displayPercent(forUsedPercent: used, metric: metric)
    return (val, UsageFormatting.colorForPercent(val, metric: metric))
}

struct WidgetMetricItem: Identifiable {
    var id: WidgetMetricKind { kind }
    let kind: WidgetMetricKind
    let title: String
    let percent: Double
    let resetsAt: Int?
}

func categorizeWidgetMetrics(
    data: ProviderData,
    visibleMetrics: Set<WidgetMetricKind>
) -> (primary: WidgetMetricItem?, secondary: [WidgetMetricItem]) {
    var items: [WidgetMetricItem] = []
    if visibleMetrics.contains(.fiveHour), let p5h = data.usedPercent5h {
        items.append(WidgetMetricItem(kind: .fiveHour, title: "5h Window", percent: p5h, resetsAt: data.resetsAt5h))
    }
    if visibleMetrics.contains(.weekly), let pWk = data.usedPercentWeekly {
        items.append(WidgetMetricItem(kind: .weekly, title: "Weekly", percent: pWk, resetsAt: data.resetsAtWeekly))
    }

    guard let first = items.first else { return (nil, []) }
    return (first, Array(items.dropFirst()))
}

// MARK: - Widget Components & Helpers

struct WidgetAccountSwitcher: View {
    let count: Int
    @Binding var selectedIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedIndex = (selectedIndex - 1 + count) % count
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(min(selectedIndex + 1, count)) of \(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedIndex = (selectedIndex + 1) % count
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }
}

struct WidgetSecondaryMetricRow: View {
    let label: String
    let percent: Double
    let resetsAt: Int?
    let metric: PercentageMetric
    var barHeight: CGFloat = 4
    var labelWidth: CGFloat = 48
    var hasAccessibilityPercentLabel: Bool = false

    var body: some View {
        let (displayVal, color) = displayPercentAndColor(forUsedPercent: percent, metric: metric)
        let row = HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            LinearProgressBar(percent: displayVal, color: color, height: barHeight)

            Text("\(Int(displayVal))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 30, alignment: .trailing)

            if let resetsAt {
                Text(UsageFormatting.formatCountdown(resetsAt))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        if hasAccessibilityPercentLabel {
            row.accessibilityElement(children: .combine)
                .accessibilityLabel("\(label): \(Int(displayVal)) percent")
        } else {
            row
        }
    }
}

func widgetCompactErrorRow(message: String) -> some View {
    HStack(spacing: 4) {
        Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .font(.caption2)
        Text(message)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

@ViewBuilder
func widgetErrorBanner(message: String, expandWidth: Bool = false) -> some View {
    let content = HStack(spacing: 4) {
        Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .font(.caption)
        Text(message)
            .font(.caption)
            .foregroundStyle(.primary)
    }
    .padding(8)
    let background = RoundedRectangle(cornerRadius: 8)
    if expandWidth {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: background)
    } else {
        content.background(Color.red.opacity(0.1), in: background)
    }
}

enum RelativeDateFormatting {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func format(_ unixSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func format(_ unixSeconds: Int) -> String {
        format(Int64(unixSeconds))
    }
}

extension Array where Element == Route {
    mutating func setRouteEnabled(_ route: Route, enabled: Bool) {
        if enabled, !contains(route) {
            append(route)
        } else if !enabled {
            removeAll { $0 == route }
        }
    }
}

extension DaemonConfig {
    func providerConfigOrDefault(for provider: Provider) -> ProviderConfig {
        config(for: provider) ?? ProviderConfig(
            routesEnabled: [.keychain],
            keychainPollIntervalSec: provider == .codex ? 120 : 60
        )
    }
}


func noMetricsPlaceholder(font: Font, vPadding: CGFloat) -> some View {
    noRecentDataPlaceholder(font: font, text: "No metrics selected")
        .padding(.vertical, vPadding)
}

func noRecentDataPlaceholder(font: Font, text: LocalizedStringKey = "No recent data") -> some View {
    Text(text)
        .font(font)
        .foregroundStyle(.secondary)
}

/// Paginated per-agent widgets: resolves the selected account and its visible metrics.
protocol PagedWidgetView: View {
    var accounts: [WidgetAccount] { get }
    var selectedIndex: Int { get }
    var configuration: WidgetConfiguration { get }
}

extension PagedWidgetView {
    var activeAccount: WidgetAccount? {
        guard !accounts.isEmpty else { return nil }
        let clamped = min(max(selectedIndex, 0), accounts.count - 1)
        return accounts[clamped]
    }

    var visibleMetrics: Set<WidgetMetricKind> {
        guard let account = activeAccount else { return [] }
        return configuration.visibleMetrics(forAccountId: account.id)
    }
}

/// Compact icon + name + label row shared by the combined, per-agent circular and concentric cards.
struct CompactIdentityRow<Trailing: View>: View {
    let account: WidgetAccount
    var spacing: CGFloat = 6
    var nameFont: Font = .caption.weight(.bold)
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: account.symbolName)
                .font(.caption.weight(.bold))
            Text(account.displayName)
                .font(nameFont)

            widgetAccountLabelBadge(account.label)

            Spacer()

            trailing
        }
    }
}

/// Account switcher plus the active account's card, shared by the paginated per-agent widgets.
struct PagedAccountCard<Content: View>: View {
    let accounts: [WidgetAccount]
    @Binding var selectedIndex: Int
    let activeAccount: WidgetAccount?
    @ViewBuilder let content: (WidgetAccount) -> Content

    var body: some View {
        VStack(spacing: 10) {
            if accounts.count > 1 {
                WidgetAccountSwitcher(count: accounts.count, selectedIndex: $selectedIndex)
            }

            if let account = activeAccount {
                content(account)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
