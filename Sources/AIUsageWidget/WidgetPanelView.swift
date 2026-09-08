import SwiftUI

/// Floating desktop widget panel view that displays AI provider quota usage.
/// Supports 4 distinct visual styles switched via `displayPrefs.desktopWidgetStyle`:
/// 1. Combined, linear: Stacked account cards with compact horizontal progress bars.
/// 2. Combined, circular: Multi-gauge circular progress rings for each account.
/// 3. Per-agent, linear: Prominent single-account focus with large numbers and linear bars.
/// 4. Per-agent, circular: Prominent single-account dial ring with secondary window metrics.
struct WidgetPanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs: DisplayPreferences

    @State private var selectedAgentIndex: Int = 0

    private var displayedAccounts: [Account] {
        var result: [Account] = []
        for provider in displayPrefs.providerOrder {
            let accts = store.accounts.filter { $0.provider == provider && store.isAccountEnabled($0) }
            result.append(contentsOf: accts)
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
                switch displayPrefs.desktopWidgetStyle {
                case .combinedLinear:
                    CombinedLinearWidgetView(
                        accounts: displayedAccounts,
                        metric: displayPrefs.percentageMetric
                    )
                case .combinedCircular:
                    CombinedCircularWidgetView(
                        accounts: displayedAccounts,
                        metric: displayPrefs.percentageMetric
                    )
                case .perAgentLinear:
                    PerAgentLinearWidgetView(
                        accounts: displayedAccounts,
                        selectedIndex: $selectedAgentIndex,
                        metric: displayPrefs.percentageMetric
                    )
                case .perAgentCircular:
                    PerAgentCircularWidgetView(
                        accounts: displayedAccounts,
                        selectedIndex: $selectedAgentIndex,
                        metric: displayPrefs.percentageMetric
                    )
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("AI USAGE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.8)

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
            Text("No Accounts Enabled")
                .font(.caption.weight(.semibold))
            Text("Enable accounts in menu bar settings.")
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

// MARK: - Style 1: Combined Linear Widget View

private struct CombinedLinearWidgetView: View {
    let accounts: [Account]
    let metric: PercentageMetric

    var body: some View {
        VStack(spacing: 8) {
            ForEach(accounts) { account in
                CombinedLinearAccountCard(account: account, metric: metric)
            }
        }
    }
}

private struct CombinedLinearAccountCard: View {
    let account: Account
    let metric: PercentageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            accountHeader

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
                    VStack(spacing: 4) {
                        linearRow(label: "5h", percent: data.usedPercent5h, resetsAt: data.resetsAt5h)
                        linearRow(label: "Wk", percent: data.usedPercentWeekly, resetsAt: data.resetsAtWeekly)
                        if data.contextWindowUsedPercent != nil {
                            linearRow(label: "Ctx", percent: data.contextWindowUsedPercent, resetsAt: nil)
                        }
                    }
                    .opacity(account.state == .stale ? 0.75 : 1.0)
                } else {
                    Text("No usage data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var accountHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: account.provider.symbolName)
                .font(.caption.weight(.bold))
            Text(account.provider.displayName)
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
    private func linearRow(label: String, percent: Double?, resetsAt: Int?) -> some View {
        if let percent {
            let displayVal = WidgetMetrics.displayPercent(forUsedPercent: percent, metric: metric)
            let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)
            let labelSuffix = metric == .remaining ? "r" : ""

            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)

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
            .accessibilityLabel("\(account.provider.displayName) \(label): \(Int(displayVal)) percent")
        }
    }
}

// MARK: - Style 2: Combined Circular Widget View

private struct CombinedCircularWidgetView: View {
    let accounts: [Account]
    let metric: PercentageMetric

    var body: some View {
        VStack(spacing: 10) {
            ForEach(accounts) { account in
                CombinedCircularAccountCard(account: account, metric: metric)
            }
        }
    }
}

private struct CombinedCircularAccountCard: View {
    let account: Account
    let metric: PercentageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: account.provider.symbolName)
                    .font(.caption.weight(.bold))
                Text(account.provider.displayName)
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
                    HStack(spacing: 12) {
                        if let p5h = data.usedPercent5h {
                            circularMetricItem(label: "5h", percent: p5h, resetsAt: data.resetsAt5h)
                        }
                        if let pWk = data.usedPercentWeekly {
                            circularMetricItem(label: "Weekly", percent: pWk, resetsAt: data.resetsAtWeekly)
                        }
                        if let pCtx = data.contextWindowUsedPercent {
                            circularMetricItem(label: "Context", percent: pCtx, resetsAt: nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(account.state == .stale ? 0.75 : 1.0)
                } else {
                    Text("No usage data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                CircularRingProgress(percent: displayVal, color: color, lineWidth: 4, size: 44)

                VStack(spacing: 0) {
                    Text("\(Int(displayVal))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)

            if let resetsAt {
                Text(WidgetMetrics.formatCountdown(resetsAt))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Int(displayVal)) percent")
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
}

// MARK: - Style 3: Per-Agent Linear Widget View

private struct PerAgentLinearWidgetView: View {
    let accounts: [Account]
    @Binding var selectedIndex: Int
    let metric: PercentageMetric

    private var activeAccount: Account? {
        guard !accounts.isEmpty else { return nil }
        let clamped = min(max(selectedIndex, 0), accounts.count - 1)
        return accounts[clamped]
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
                        Image(systemName: account.provider.symbolName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(account.provider.displayName)
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

                            if let asOf = account.asOf {
                                Text(WidgetMetrics.syncAge(asOf))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()

                        routePill(for: account)
                    }

                    // Content based on account state
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
                            primaryHeadlineBlock(data: data)

                            // Secondary metrics
                            VStack(spacing: 6) {
                                if let pWk = data.usedPercentWeekly {
                                    secondaryRow(label: "Weekly", percent: pWk, resetsAt: data.resetsAtWeekly)
                                }
                                if let pCtx = data.contextWindowUsedPercent {
                                    secondaryRow(label: "Context", percent: pCtx, resetsAt: nil)
                                }
                            }
                            .padding(.top, 2)
                            .opacity(account.state == .stale ? 0.75 : 1.0)
                        } else {
                            Text("No usage data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
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

    private func primaryHeadlineBlock(data: ProviderData) -> some View {
        let rawPercent = data.usedPercent5h ?? data.usedPercentWeekly ?? 0
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: rawPercent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)
        let headlineWindow = data.usedPercent5h != nil ? "5h Window" : "Weekly Window"
        let resetsAt = data.usedPercent5h != nil ? data.resetsAt5h : data.resetsAtWeekly

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .lastTextBaseline) {
                Text("\(Int(displayVal))%")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(color)

                Text(metric == .remaining ? "remaining" : "used")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if let resetsAt {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(WidgetMetrics.formatCountdown(resetsAt))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
            }

            LinearProgressBar(percent: displayVal, color: color, height: 7)

            Text(headlineWindow)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func secondaryRow(label: String, percent: Double, resetsAt: Int?) -> some View {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: percent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)

        return HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

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
    }

    private func routePill(for account: Account) -> some View {
        let title: String
        let color: Color
        switch account.activeRoute {
        case .injection:
            if account.provider == .codex {
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
}

// MARK: - Style 4: Per-Agent Circular Widget View

private struct PerAgentCircularWidgetView: View {
    let accounts: [Account]
    @Binding var selectedIndex: Int
    let metric: PercentageMetric

    private var activeAccount: Account? {
        guard !accounts.isEmpty else { return nil }
        let clamped = min(max(selectedIndex, 0), accounts.count - 1)
        return accounts[clamped]
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
                        Image(systemName: account.provider.symbolName)
                            .font(.caption.weight(.bold))
                        Text(account.provider.displayName)
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
                            primaryDial(data: data)

                            // Secondary metrics in compact pills
                            HStack(spacing: 8) {
                                if let pWk = data.usedPercentWeekly {
                                    secondaryMetricPill(
                                        title: "Weekly",
                                        percent: pWk,
                                        resetsAt: data.resetsAtWeekly
                                    )
                                }
                                if let pCtx = data.contextWindowUsedPercent {
                                    secondaryMetricPill(
                                        title: "Context",
                                        percent: pCtx,
                                        resetsAt: nil
                                    )
                                }
                            }
                            .opacity(account.state == .stale ? 0.75 : 1.0)
                        } else {
                            Text("No usage data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
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

    private func primaryDial(data: ProviderData) -> some View {
        let rawPercent = data.usedPercent5h ?? data.usedPercentWeekly ?? 0
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: rawPercent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)
        let windowLabel = data.usedPercent5h != nil ? "5h Window" : "Weekly"
        let resetsAt = data.usedPercent5h != nil ? data.resetsAt5h : data.resetsAtWeekly

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

            HStack(spacing: 4) {
                Text(windowLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let resetsAt {
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("resets \(WidgetMetrics.formatCountdown(resetsAt))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func secondaryMetricPill(title: String, percent: Double, resetsAt: Int?) -> some View {
        let displayVal = WidgetMetrics.displayPercent(forUsedPercent: percent, metric: metric)
        let color = WidgetMetrics.colorForPercent(displayVal, metric: metric)

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(displayVal))%")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }

            LinearProgressBar(percent: displayVal, color: color, height: 3)

            if let resetsAt {
                Text(WidgetMetrics.formatCountdown(resetsAt))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
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
            switch percent {
            case ..<15: return .red
            case ..<40: return .yellow
            default: return .green
            }
        }
    }

    static func formatCountdown(_ unixSeconds: Int) -> String {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        if interval < 60 { return "<1m" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return (formatter.string(from: interval) ?? "")
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
