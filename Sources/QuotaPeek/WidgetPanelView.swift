import SwiftUI

/// Floating desktop widget panel view that displays AI provider quota usage.
/// Supports 6 distinct visual styles switched via `configuration.style`:
/// 1. Combined, linear: Stacked account cards with compact horizontal progress bars.
/// 2. Combined, circular: Multi-gauge circular progress rings for each account.
/// 3. Per-agent, linear: Single-account focus with large numbers and linear bars, paginated when multi-account.
/// 4. Per-agent, circular: Single-account dial ring with secondary window metrics, paginated when multi-account.
/// 5. Concentric rings: Nested circular progress rings (outer: 5h, inner: weekly) with legend.
/// 6. Single-agent focus: Minimal, unpaginated single-account glance card with a bold dominant metric.
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

struct WidgetPanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs: DisplayPreferences
    let configuration: WidgetConfiguration

    @State private var selectedAgentIndex: Int = 0

    private var displayedAccounts: [WidgetAccount] {
        var realAccounts: [Account] = []
        for provider in displayPrefs.providerOrder {
            let accts = store.accounts.filter { $0.provider == provider && store.isAccountEnabled($0) }
            realAccounts.append(contentsOf: accts)
        }
        let remainder = store.accounts.filter { store.isAccountEnabled($0) && !realAccounts.contains($0) }
        realAccounts.append(contentsOf: remainder)

        let scoped = realAccounts.filter { configuration.scope.includes($0.id) }

        var result: [WidgetAccount] = []
        for account in scoped {
            result.append(WidgetAccount(
                id: account.id,
                displayName: account.provider.displayName,
                symbolName: account.provider.symbolName,
                label: account.label,
                state: account.state,
                displayLastError: account.displayLastError,
                asOf: account.asOf,
                activeRoute: account.activeRoute,
                isCodex: account.provider == .codex,
                data: account.data
            ))

            let cgAccountId = "\(account.id):claude_gpt"
            if account.provider == .antigravity,
               displayPrefs.showAntigravityModelBreakdown,
               configuration.scope.includes(cgAccountId),
               let data = account.data,
               data.usedPercent5hThirdParty != nil || data.usedPercentWeeklyThirdParty != nil {
                let cgData = ProviderData(
                    usedPercent5h: data.usedPercent5hThirdParty,
                    resetsAt5h: data.resetsAt5hThirdParty,
                    usedPercentWeekly: data.usedPercentWeeklyThirdParty,
                    resetsAtWeekly: data.resetsAtWeeklyThirdParty,
                    usedPercent5hThirdParty: nil,
                    resetsAt5hThirdParty: nil,
                    usedPercentWeeklyThirdParty: nil,
                    resetsAtWeeklyThirdParty: nil,
                    contextWindowUsedPercent: nil
                )
                result.append(WidgetAccount(
                    id: cgAccountId,
                    displayName: "Claude/GPT",
                    symbolName: "sparkles",
                    label: account.label,
                    state: account.state,
                    displayLastError: account.displayLastError,
                    asOf: account.asOf,
                    activeRoute: account.activeRoute,
                    isCodex: false,
                    data: cgData
                ))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 10) {
            headerBar

            if !store.isDaemonReachable {
                disconnectedBanner
            }

            if store.isCollectionPaused {
                pausedBanner
            }

            if displayedAccounts.isEmpty {
                emptyStateView
            } else {
                switch configuration.style {
                case .combinedLinear:
                    CombinedLinearWidgetView(
                        accounts: displayedAccounts,
                        metric: displayPrefs.percentageMetric,
                        configuration: configuration
                    )
                case .combinedCircular:
                    CombinedCircularWidgetView(
                        accounts: displayedAccounts,
                        metric: displayPrefs.percentageMetric,
                        configuration: configuration
                    )
                case .perAgentLinear:
                    PerAgentLinearWidgetView(
                        accounts: displayedAccounts,
                        selectedIndex: $selectedAgentIndex,
                        metric: displayPrefs.percentageMetric,
                        configuration: configuration
                    )
                case .perAgentCircular:
                    PerAgentCircularWidgetView(
                        accounts: displayedAccounts,
                        selectedIndex: $selectedAgentIndex,
                        metric: displayPrefs.percentageMetric,
                        configuration: configuration
                    )
                case .concentricRings:
                    ConcentricRingsWidgetView(
                        accounts: displayedAccounts,
                        metric: displayPrefs.percentageMetric,
                        configuration: configuration
                    )
                case .singleAgentFocus:
                    SingleAgentFocusWidgetView(
                        accounts: displayedAccounts,
                        isSingleAccountScope: configuration.scope.includedAccountIds?.count == 1,
                        metric: displayPrefs.percentageMetric,
                        configuration: configuration
                    )
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(
            // .allowsHitTesting(false): a Material fill compiles to a real
            // NSVisualEffectView subview, which - unlike plain SwiftUI shapes -
            // claims mouse events for its whole area. Left hit-testable, it sits
            // between every click and the panel's contentView, so
            // isMovableByWindowBackground (DesktopWidgetPanel) never sees a
            // background hit and the widget can't be dragged. Disabling hit
            // testing here lets clicks pass through to the window for dragging
            // while real controls (e.g. the refresh button) above it in the
            // view tree still get theirs first.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .allowsHitTesting(false)
        )
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(configuration.name.isEmpty ? "QUOTAPEEK" : configuration.name.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .lineLimit(1)

            Spacer()

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh usage")
                .accessibilityLabel("Refresh usage")
            }
        }
    }

    // MARK: - Status Banners

    private var disconnectedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption2)
            Text("Service unreachable")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Background service unreachable")
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption2)
            Text("Collection paused")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Resume") {
                Task { _ = await store.setCollectionPaused(false) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(configuration.scope.includedAccountIds != nil ? "No Selected Accounts Available" : "No Accounts Enabled")
                .font(.caption.weight(.semibold))
            Text(configuration.scope.includedAccountIds != nil ? "Select enabled accounts in this widget’s settings." : "Enable accounts in menu bar settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Shared Route & Badge Helpers

private func routePill(for account: WidgetAccount) -> some View {
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

    return Text(title)
        .font(.system(size: 9, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
}

private func statusColor(for state: AccountTrustState) -> Color {
    switch state {
    case .fresh: return .green
    case .stale: return .orange
    case .restored: return .purple
    case .error: return .red
    case .unknown: return .gray
    }
}

// MARK: - Style 1: Combined Linear Widget View

private struct CombinedLinearWidgetView: View {
    let accounts: [WidgetAccount]
    let metric: PercentageMetric
    let configuration: WidgetConfiguration

    var body: some View {
        VStack(spacing: 8) {
            ForEach(accounts) { account in
                CombinedLinearAccountCard(account: account, metric: metric, visibleMetrics: configuration.visibleMetrics(forAccountId: account.id))
            }
        }
    }
}

private struct CombinedLinearAccountCard: View {
    let account: WidgetAccount
    let metric: PercentageMetric
    let visibleMetrics: Set<WidgetMetricKind>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            accountHeader

            if visibleMetrics.isDisjoint(with: WidgetMetricKind.offerable) {
                Text("No metrics selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                switch account.state {
                case .unknown:
                    Text("No recent data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .error:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption2)
                        Text(account.displayLastError ?? "Polling error")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .restored, .stale, .fresh:
                    if let data = account.data {
                        let has5h = visibleMetrics.contains(.fiveHour) && data.usedPercent5h != nil
                        let hasWk = visibleMetrics.contains(.weekly) && data.usedPercentWeekly != nil

                        if !has5h && !hasWk {
                            Text("No usage data")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 4) {
                                if has5h {
                                    linearRow(label: "5h", percent: data.usedPercent5h, resetsAt: data.resetsAt5h)
                                }
                                if hasWk {
                                    linearRow(label: "Wk", percent: data.usedPercentWeekly, resetsAt: data.resetsAtWeekly)
                                }
                            }
                            .opacity(account.state == .stale ? 0.75 : 1.0)
                        }
                    } else {
                        Text("No usage data")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var accountHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: account.symbolName)
                .font(.caption.weight(.bold))
            Text(account.displayName)
                .font(.caption.weight(.semibold))

            if !account.label.isEmpty && account.label != "Default" {
                Text(account.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            stateBadge
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch account.state {
        case .restored:
            miniBadge(text: "Restored", color: .purple)
        case .stale:
            miniBadge(text: "Stale", color: .orange)
        case .error:
            miniBadge(text: "Error", color: .red)
        case .unknown:
            miniBadge(text: "No Data", color: .gray)
        case .fresh:
            EmptyView()
        }
    }

    private func miniBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func linearRow(
        label: String,
        percent: Double?,
        resetsAt: Int?,
        labelWidth: CGFloat = 24,
        accessibilityLabelText: String? = nil
    ) -> some View {
        if let percent {
            let displayVal = WidgetMetrics.displayPercent(forUsedPercent: percent, metric: metric)
            let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)
            let labelSuffix = metric == .remaining ? "r" : ""

            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)

                LinearProgressBar(percent: displayVal, color: color, height: 4)

                Text("\(Int(displayVal))%\(labelSuffix)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 32, alignment: .trailing)

                if let resetsAt {
                    Text(WidgetMetrics.formatCountdown(resetsAt))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(accessibilityLabelText ?? "\(account.displayName) \(label)"): \(Int(displayVal)) percent")
        }
    }
}

// MARK: - Style 2: Combined Circular Widget View

private struct CombinedCircularWidgetView: View {
    let accounts: [WidgetAccount]
    let metric: PercentageMetric
    let configuration: WidgetConfiguration

    var body: some View {
        VStack(spacing: 10) {
            ForEach(accounts) { account in
                CombinedCircularAccountCard(account: account, metric: metric, visibleMetrics: configuration.visibleMetrics(forAccountId: account.id))
            }
        }
    }
}

private struct CombinedCircularAccountCard: View {
    let account: WidgetAccount
    let metric: PercentageMetric
    let visibleMetrics: Set<WidgetMetricKind>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: account.symbolName)
                    .font(.caption.weight(.bold))
                Text(account.displayName)
                    .font(.caption.weight(.semibold))

                if !account.label.isEmpty && account.label != "Default" {
                    Text(account.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                if account.state != .fresh {
                    Text(account.state.displayName)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(statusColor(for: account.state).opacity(0.15), in: Capsule())
                        .foregroundStyle(statusColor(for: account.state))
                }
            }

            if visibleMetrics.isDisjoint(with: WidgetMetricKind.offerable) {
                Text("No metrics selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                switch account.state {
                case .unknown:
                    Text("No recent data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .error:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption2)
                        Text(account.displayLastError ?? "Polling error")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .restored, .stale, .fresh:
                    if let data = account.data {
                        let has5h = visibleMetrics.contains(.fiveHour) && data.usedPercent5h != nil
                        let hasWk = visibleMetrics.contains(.weekly) && data.usedPercentWeekly != nil

                        if !has5h && !hasWk {
                            Text("No usage data")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 12) {
                                if has5h, let percent = data.usedPercent5h {
                                    circularMetricItem(label: "5h", percent: percent, resetsAt: data.resetsAt5h)
                                }
                                if hasWk, let percent = data.usedPercentWeekly {
                                    circularMetricItem(label: "Weekly", percent: percent, resetsAt: data.resetsAtWeekly)
                                }
                            }
                            .opacity(account.state == .restored || account.state == .stale ? 0.75 : 1.0)
                        }
                    } else {
                        Text("No usage data")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func circularMetricItem(label: String, percent: Double, resetsAt: Int?) -> some View {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: percent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)

        return VStack(spacing: 3) {
            ZStack {
                CircularRingProgress(percent: displayVal, color: color, lineWidth: 4, size: 52)

                VStack(spacing: 0) {
                    Text("\(Int(displayVal))%")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            if let resetsAt {
                Text(WidgetMetrics.formatCountdown(resetsAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Int(displayVal)) percent")
    }
}

// MARK: - Style 3: Per-Agent Linear Widget View

@ViewBuilder
private func freshnessBadge(for account: WidgetAccount) -> some View {
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

private struct PerAgentLinearWidgetView: View {
    let accounts: [WidgetAccount]
    @Binding var selectedIndex: Int
    let metric: PercentageMetric
    let configuration: WidgetConfiguration

    private var activeAccount: WidgetAccount? {
        guard !accounts.isEmpty else { return nil }
        let clamped = min(max(selectedIndex, 0), accounts.count - 1)
        return accounts[clamped]
    }

    private var visibleMetrics: Set<WidgetMetricKind> {
        guard let account = activeAccount else { return [] }
        return configuration.visibleMetrics(forAccountId: account.id)
    }

    var body: some View {
        VStack(spacing: 10) {
            if accounts.count > 1 {
                accountSwitcher
            }

            if let account = activeAccount {
                VStack(alignment: .leading, spacing: 10) {
                    // Agent Identity
                    HStack(spacing: 8) {
                        Image(systemName: account.symbolName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(account.displayName)
                                    .font(.subheadline.weight(.bold))
                                if !account.label.isEmpty && account.label != "Default" {
                                    Text(account.label)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                                }
                            }

                            freshnessBadge(for: account)

                            if let asOf = account.asOf {
                                Text(WidgetMetrics.syncAge(asOf))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()

                        routePill(for: account)
                    }

                    if visibleMetrics.isDisjoint(with: WidgetMetricKind.offerable) {
                        Text("No metrics selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        switch account.state {
                        case .unknown:
                            Text("No recent data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .error:
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                    Text(account.displayLastError ?? "Polling error")
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        case .restored, .stale, .fresh:
                            if let data = account.data {
                                let (primaryMetric, secondaryMetrics) = categorizeMetrics(data: data)
                                if let primary = primaryMetric {
                                    VStack(spacing: 6) {
                                        primaryHeadlineBlock(
                                            title: primary.title,
                                            percent: primary.percent,
                                            resetsAt: primary.resetsAt
                                        )

                                        if !secondaryMetrics.isEmpty {
                                            VStack(spacing: 6) {
                                                ForEach(secondaryMetrics, id: \.kind) { sec in
                                                    secondaryRow(
                                                        label: sec.title,
                                                        percent: sec.percent,
                                                        resetsAt: sec.resetsAt
                                                    )
                                                }
                                            }
                                            .padding(.top, 2)
                                        }
                                    }
                                    .opacity(account.state == .restored || account.state == .stale ? 0.85 : 1.0)
                                } else {
                                    Text("No usage data")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("No usage data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private struct MetricItem {
        let kind: WidgetMetricKind
        let title: String
        let percent: Double
        let resetsAt: Int?
    }

    private func categorizeMetrics(data: ProviderData) -> (primary: MetricItem?, secondary: [MetricItem]) {
        var items: [MetricItem] = []
        if visibleMetrics.contains(.fiveHour), let p5h = data.usedPercent5h {
            items.append(MetricItem(kind: .fiveHour, title: "5h Window", percent: p5h, resetsAt: data.resetsAt5h))
        }
        if visibleMetrics.contains(.weekly), let pWk = data.usedPercentWeekly {
            items.append(MetricItem(kind: .weekly, title: "Weekly", percent: pWk, resetsAt: data.resetsAtWeekly))
        }

        guard let first = items.first else { return (nil, []) }
        return (first, Array(items.dropFirst()))
    }

    private var accountSwitcher: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedIndex = (selectedIndex - 1 + accounts.count) % accounts.count
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(min(selectedIndex + 1, accounts.count)) of \(accounts.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedIndex = (selectedIndex + 1) % accounts.count
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func primaryHeadlineBlock(title: String, percent: Double, resetsAt: Int?) -> some View {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: percent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)

        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(displayVal))%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                if let resetsAt {
                    Text("Resets in \(WidgetMetrics.formatCountdown(resetsAt))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            LinearProgressBar(percent: displayVal, color: color, height: 6)

            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func secondaryRow(label: String, percent: Double, resetsAt: Int?, labelWidth: CGFloat = 48) -> some View {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: percent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)

        return HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            LinearProgressBar(percent: displayVal, color: color, height: 4)

            Text("\(Int(displayVal))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 30, alignment: .trailing)

            if let resetsAt {
                Text(WidgetMetrics.formatCountdown(resetsAt))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Int(displayVal)) percent")
    }
}

// MARK: - Style 4: Per-Agent Circular Widget View

private struct PerAgentCircularWidgetView: View {
    let accounts: [WidgetAccount]
    @Binding var selectedIndex: Int
    let metric: PercentageMetric
    let configuration: WidgetConfiguration

    private var activeAccount: WidgetAccount? {
        guard !accounts.isEmpty else { return nil }
        let clamped = min(max(selectedIndex, 0), accounts.count - 1)
        return accounts[clamped]
    }

    private var visibleMetrics: Set<WidgetMetricKind> {
        guard let account = activeAccount else { return [] }
        return configuration.visibleMetrics(forAccountId: account.id)
    }

    var body: some View {
        VStack(spacing: 10) {
            if accounts.count > 1 {
                accountSwitcher
            }

            if let account = activeAccount {
                VStack(spacing: 10) {
                    // Identity row
                    HStack(spacing: 6) {
                        Image(systemName: account.symbolName)
                            .font(.caption.weight(.bold))
                        Text(account.displayName)
                            .font(.caption.weight(.bold))

                        if !account.label.isEmpty && account.label != "Default" {
                            Text(account.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                        }

                        Spacer()

                        if account.state != .fresh {
                            Text(account.state.displayName)
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }

                    if visibleMetrics.isDisjoint(with: WidgetMetricKind.offerable) {
                        Text("No metrics selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        switch account.state {
                        case .unknown:
                            Text("No recent data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .error:
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                Text(account.displayLastError ?? "Polling error")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                            .padding(8)
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        case .restored, .stale, .fresh:
                            if let data = account.data {
                                let (primaryMetric, secondaryMetrics) = categorizeMetrics(data: data)
                                if let primary = primaryMetric {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 12) {
                                        primaryDial(title: primary.title, percent: primary.percent, resetsAt: primary.resetsAt)
                                        ForEach(secondaryMetrics, id: \.kind) { secondary in
                                            primaryDial(title: secondary.title, percent: secondary.percent, resetsAt: secondary.resetsAt)
                                        }
                                    }
                                    .opacity(account.state == .restored || account.state == .stale ? 0.75 : 1.0)
                                } else {
                                    Text("No usage data")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("No usage data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private struct MetricItem {
        let kind: WidgetMetricKind
        let title: String
        let percent: Double
        let resetsAt: Int?
    }

    private func categorizeMetrics(data: ProviderData) -> (primary: MetricItem?, secondary: [MetricItem]) {
        var items: [MetricItem] = []
        if visibleMetrics.contains(.fiveHour), let p5h = data.usedPercent5h {
            items.append(MetricItem(kind: .fiveHour, title: "5h Window", percent: p5h, resetsAt: data.resetsAt5h))
        }
        if visibleMetrics.contains(.weekly), let pWk = data.usedPercentWeekly {
            items.append(MetricItem(kind: .weekly, title: "Weekly", percent: pWk, resetsAt: data.resetsAtWeekly))
        }

        guard let first = items.first else { return (nil, []) }
        return (first, Array(items.dropFirst()))
    }

    private var accountSwitcher: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedIndex = (selectedIndex - 1 + accounts.count) % accounts.count
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(min(selectedIndex + 1, accounts.count)) of \(accounts.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedIndex = (selectedIndex + 1) % accounts.count
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func primaryDial(title: String, percent: Double, resetsAt: Int?) -> some View {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: percent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)

        return VStack(spacing: 4) {
            ZStack {
                CircularRingProgress(percent: displayVal, color: color, lineWidth: 7, size: 84)

                VStack(spacing: 1) {
                    Text("\(Int(displayVal))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(metric == .remaining ? "remaining" : "used")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let resetsAt {
                    Text(WidgetMetrics.formatCountdown(resetsAt))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

}

// MARK: - Style 5: Concentric Rings Widget View

private struct ConcentricRingsWidgetView: View {
    let accounts: [WidgetAccount]
    let metric: PercentageMetric
    let configuration: WidgetConfiguration

    var body: some View {
        if accounts.count == 1, let account = accounts.first {
            SingleAccountConcentricCard(
                account: account,
                metric: metric,
                visibleMetrics: configuration.visibleMetrics(forAccountId: account.id)
            )
        } else {
            MultiAccountConcentricView(
                accounts: accounts,
                metric: metric,
                configuration: configuration
            )
        }
    }
}

private struct RingData: Identifiable {
    let id: WidgetMetricKind
    let kind: WidgetMetricKind
    let label: String
    let positionName: String
    let percent: Double
    let color: Color
    let resetsAt: Int?
}

private func extractRings(
    from data: ProviderData,
    visibleMetrics: Set<WidgetMetricKind>,
    metric: PercentageMetric
) -> [RingData] {
    var rings: [RingData] = []
    if visibleMetrics.contains(.fiveHour), let p5h = data.usedPercent5h {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: p5h, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)
        rings.append(RingData(
            id: .fiveHour,
            kind: .fiveHour,
            label: "5h",
            positionName: "Outer",
            percent: displayVal,
            color: color,
            resetsAt: data.resetsAt5h
        ))
    }
    if visibleMetrics.contains(.weekly), let pWk = data.usedPercentWeekly {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: pWk, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)
        rings.append(RingData(
            id: .weekly,
            kind: .weekly,
            label: "Weekly",
            positionName: rings.isEmpty ? "Outer" : "Inner",
            percent: displayVal,
            color: color,
            resetsAt: data.resetsAtWeekly
        ))
    }
    return rings
}

/// Draws 1-3 nested concentric circular rings centered around a shared origin.
private struct ConcentricRingsGauge: View {
    let rings: [RingData]
    let baseSize: CGFloat
    let ringWidth: CGFloat
    let ringSpacing: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.element.id) { index, ring in
                let ringSize = max(10, baseSize - CGFloat(index) * (ringWidth + ringSpacing) * 2)
                CircularRingProgress(
                    percent: ring.percent,
                    color: ring.color,
                    lineWidth: ringWidth,
                    size: ringSize
                )
            }
        }
        .frame(width: baseSize, height: baseSize)
    }
}

/// Prominent single-account card with a large nested concentric rings gauge and detailed legend.
private struct SingleAccountConcentricCard: View {
    let account: WidgetAccount
    let metric: PercentageMetric
    let visibleMetrics: Set<WidgetMetricKind>

    var body: some View {
        VStack(spacing: 10) {
            // Identity Header
            HStack(spacing: 6) {
                Image(systemName: account.symbolName)
                    .font(.caption.weight(.bold))
                Text(account.displayName)
                    .font(.caption.weight(.bold))

                if !account.label.isEmpty && account.label != "Default" {
                    Text(account.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                if account.state != .fresh {
                    Text(account.state.displayName)
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(statusColor(for: account.state).opacity(0.15), in: Capsule())
                        .foregroundStyle(statusColor(for: account.state))
                } else {
                    routePill(for: account)
                }
            }

            if visibleMetrics.isDisjoint(with: WidgetMetricKind.offerable) {
                Text("No metrics selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                switch account.state {
                case .unknown:
                    Text("No recent data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .error:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(account.displayLastError ?? "Polling error")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                case .restored, .stale, .fresh:
                    if let data = account.data {
                        let rings = extractRings(from: data, visibleMetrics: visibleMetrics, metric: metric)

                        if rings.isEmpty {
                            Text("No usage data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 12) {
                                ZStack {
                                    ConcentricRingsGauge(
                                        rings: rings,
                                        baseSize: 104,
                                        ringWidth: 7,
                                        ringSpacing: 4
                                    )

                                    Image(systemName: account.symbolName)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(account.displayName) concentric usage gauge")

                                concentricLegend(title: nil, rings: rings)
                            }
                            .opacity(account.state == .stale ? 0.75 : 1.0)
                        }
                    } else {
                        Text("No usage data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func concentricLegend(title: String?, rings: [RingData]) -> some View {
        VStack(spacing: title != nil ? 3 : 0) {
            if let title {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            HStack(spacing: title != nil ? 4 : 12) {
                ForEach(rings) { ring in
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(ring.color)
                                .frame(width: title != nil ? 5 : 6, height: title != nil ? 5 : 6)
                            Text(ring.label)
                                .font(.system(size: title != nil ? 8.5 : 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }

                        Text("\(Int(ring.percent))%")
                            .font(.system(size: title != nil ? 10 : 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)

                        Text(ring.positionName)
                            .font(.system(size: title != nil ? 7.5 : 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        if let resetsAt = ring.resetsAt {
                            Text(WidgetMetrics.formatCountdown(resetsAt))
                                .font(.system(size: title != nil ? 6.5 : 7, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(title != nil ? 6 : 8)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

}

/// Multi-account small-multiples layout when scope is all agents in concentricRings style.
private struct MultiAccountConcentricView: View {
    let accounts: [WidgetAccount]
    let metric: PercentageMetric
    let configuration: WidgetConfiguration

    var body: some View {
        VStack(spacing: 10) {
            if accounts.allSatisfy({ configuration.visibleMetrics(forAccountId: $0.id).isDisjoint(with: WidgetMetricKind.offerable) }) {
                Text("No metrics selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(accounts) { account in
                        MultiAccountConcentricCell(
                            account: account,
                            metric: metric,
                            visibleMetrics: configuration.visibleMetrics(forAccountId: account.id)
                        )
                    }
                }
            }
        }
    }
}

private struct MultiAccountConcentricCell: View {
    let account: WidgetAccount
    let metric: PercentageMetric
    let visibleMetrics: Set<WidgetMetricKind>

    var body: some View {
        VStack(spacing: 6) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: account.symbolName)
                    .font(.system(size: 9, weight: .bold))
                Text(account.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if account.state != .fresh {
                    Circle()
                        .fill(statusColor(for: account.state))
                        .frame(width: 5, height: 5)
                }
            }

            if !account.label.isEmpty && account.label != "Default" {
                Text(account.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }

            switch account.state {
            case .unknown:
                Text("No data")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(height: 58)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(height: 58)
            case .restored, .stale, .fresh:
                if let data = account.data {
                    let rings = extractRings(from: data, visibleMetrics: visibleMetrics, metric: metric)

                    if rings.isEmpty {
                        Text("No data")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(height: 58)
                    } else {
                        ZStack {
                            ConcentricRingsGauge(
                                rings: rings,
                                baseSize: 58,
                                ringWidth: 4,
                                ringSpacing: 2.5
                            )

                            if let top = rings.first {
                                Text("\(Int(top.percent))%")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .opacity(account.state == .stale ? 0.75 : 1.0)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(account.displayName) concentric usage gauge")

                        // Missing metrics differ per account, so label each card's actual rings.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(rings) { ring in
                                Text("\(ring.label) (\(ring.positionName.lowercased()))")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("No data")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(height: 58)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Style 6: Single-Agent Focus Widget View

private struct SingleAgentFocusWidgetView: View {
    let accounts: [WidgetAccount]
    let isSingleAccountScope: Bool
    let metric: PercentageMetric
    let configuration: WidgetConfiguration

    private var targetAccount: WidgetAccount? {
        accounts.first
    }

    private var visibleMetrics: Set<WidgetMetricKind> {
        guard let account = targetAccount else { return [] }
        return configuration.visibleMetrics(forAccountId: account.id)
    }

    var body: some View {
        if let account = targetAccount {
            VStack(alignment: .leading, spacing: 8) {
                // Scope hint if user selected all-agents scope for single-agent-focus style
                if !isSingleAccountScope && accounts.count > 1 {
                    HStack(spacing: 3) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 8))
                        Text("Showing first account • Single agent view")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.tertiary)
                }

                // Account Identity
                HStack(spacing: 8) {
                    Image(systemName: account.symbolName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(account.displayName)
                                .font(.headline.weight(.bold))
                            if !account.label.isEmpty && account.label != "Default" {
                                Text(account.label)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            }
                        }

                        freshnessBadge(for: account)

                        if let asOf = account.asOf {
                            Text(WidgetMetrics.syncAge(asOf))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    routePill(for: account)
                }

                if visibleMetrics.isDisjoint(with: WidgetMetricKind.offerable) {
                    Text("No metrics selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    switch account.state {
                    case .unknown:
                        Text("No recent data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .error:
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text(account.displayLastError ?? "Polling error")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    case .restored, .stale, .fresh:
                        if let data = account.data {
                            let (dominantMetric, secondaryMetrics) = pickDominantAndSecondary(data: data)
                            if let dominant = dominantMetric {
                                dominantFocusCard(dominant: dominant)
                                    .opacity(account.state == .restored || account.state == .stale ? 0.85 : 1.0)

                                if !secondaryMetrics.isEmpty {
                                    secondaryMetricsList(metrics: secondaryMetrics)
                                        .opacity(account.state == .restored || account.state == .stale ? 0.85 : 1.0)
                                }
                            } else {
                                Text("No usage data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No usage data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private struct MetricCandidate {
        let kind: WidgetMetricKind
        let title: String
        let percent: Double
        let resetsAt: Int?
    }

    private func pickDominantAndSecondary(data: ProviderData) -> (dominant: MetricCandidate?, secondary: [MetricCandidate]) {
        var candidates: [MetricCandidate] = []
        if visibleMetrics.contains(.fiveHour), let p5h = data.usedPercent5h {
            candidates.append(MetricCandidate(kind: .fiveHour, title: "5-Hour Window", percent: p5h, resetsAt: data.resetsAt5h))
        }
        if visibleMetrics.contains(.weekly), let pWk = data.usedPercentWeekly {
            candidates.append(MetricCandidate(kind: .weekly, title: "Weekly Window", percent: pWk, resetsAt: data.resetsAtWeekly))
        }

        guard !candidates.isEmpty else { return (nil, []) }

        // Pick 5h if visible and has data, otherwise pick highest visible metric
        let dominant: MetricCandidate
        if let fiveHour = candidates.first(where: { $0.kind == .fiveHour }) {
            dominant = fiveHour
        } else {
            dominant = candidates.max(by: { $0.percent < $1.percent }) ?? candidates[0]
        }

        let secondary = candidates.filter { $0.kind != dominant.kind }
        return (dominant, secondary)
    }

    private func dominantFocusCard(dominant: MetricCandidate) -> some View {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: dominant.percent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(displayVal))")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: 0) {
                    Text("%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(color)

                    Text(metric == .remaining ? "remaining" : "used")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(dominant.title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)

                    if let resetsAt = dominant.resetsAt {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                            Text(WidgetMetrics.formatCountdown(resetsAt))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            // Supporting linear progress indicator
            LinearProgressBar(percent: displayVal, color: color, height: 6)
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(dominant.title): \(Int(displayVal)) percent")
    }

    private func secondaryMetricsList(metrics: [MetricCandidate]) -> some View {
        VStack(spacing: 5) {
            ForEach(metrics, id: \.kind) { item in
                let displayVal = WidgetMetrics.displayPercent(forUsedPercent: item.percent, metric: metric)
                let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)

                HStack(spacing: 6) {
                    Text(item.title.replacingOccurrences(of: " Window", with: ""))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)

                    LinearProgressBar(percent: displayVal, color: color, height: 3.5)

                    Text("\(Int(displayVal))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 30, alignment: .trailing)

                    if let resetsAt = item.resetsAt {
                        Text(WidgetMetrics.formatCountdown(resetsAt))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Reusable Visual Components

/// A circular progress ring rendered using SwiftUI `Circle().trim`.
private struct CircularRingProgress: View {
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

/// A compact linear progress bar with rounded ends and animated fill.
private struct LinearProgressBar: View {
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

// MARK: - Metric and Formatting Helpers

private enum WidgetMetrics {
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

    static func formatCountdown(_ unixSeconds: Int) -> String {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        if interval < 60 { return "<1m" }
        return (countdownFormatter.string(from: interval) ?? "")
    }

    static func syncAge(_ unixSeconds: Int64) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970) - Int(unixSeconds))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
