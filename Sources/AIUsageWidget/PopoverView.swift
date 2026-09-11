import AppKit
import SwiftUI

struct PopoverView: View {
    private enum Layout {
        static let width: CGFloat = 320
    }

    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs = DisplayPreferences.shared
    var openSettings: () -> Void
    var closePopover: () -> Void

    @State private var pauseErrorMessage: String?

    private var displayedAccounts: [Account] {
        var result: [Account] = []
        for provider in displayPrefs.providerOrder {
            let accts = store.accounts.filter { $0.provider == provider && store.isAccountEnabled($0) }
            result.append(contentsOf: accts)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !store.isDaemonReachable {
                disconnectedBanner
            }

            if store.isCollectionPaused {
                pausedBanner
            }

            if displayedAccounts.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 10) {
                    ForEach(displayedAccounts) { account in
                        AccountCard(
                            account: account,
                            metric: displayPrefs.percentageMetric,
                            showAntigravityModelBreakdown: displayPrefs.showAntigravityModelBreakdown
                        )
                    }
                }
            }
        }
        .padding(16)
        .frame(width: Layout.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand {
            closePopover()
        }
        .alert("Service Notice", isPresented: Binding(
            get: { pauseErrorMessage != nil },
            set: { if !$0 { pauseErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(pauseErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Label("AI Usage", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh usage data")
            .accessibilityLabel("Refresh usage data")

            Button {
                let target = !store.isCollectionPaused
                Task {
                    let res = await store.setCollectionPaused(target)
                    if case .failure = res {
                        pauseErrorMessage = "Failed to update pause state. Background service may be unreachable."
                    }
                }
            } label: {
                Image(systemName: store.isCollectionPaused ? "play.circle" : "pause.circle")
            }
            .buttonStyle(.borderless)
            .help(store.isCollectionPaused ? "Resume collection" : "Pause collection")
            .accessibilityLabel(store.isCollectionPaused ? "Resume collection" : "Pause collection")

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Open Settings")
        }
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Background service not reachable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: Background service not reachable")
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.blue)
            Text("Data collection is paused")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Resume") {
                Task {
                    let res = await store.setCollectionPaused(false)
                    if case .failure = res {
                        pauseErrorMessage = "Failed to resume data collection. Background service may be unreachable."
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("Resume data collection")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No accounts configured yet")
                .font(.subheadline).bold()
            Text("Enable or add at least one account in Settings to see your AI usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Configure Accounts", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
                .accessibilityLabel("Configure Accounts in Settings")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

}

private struct AccountCard: View {
    let account: Account
    let metric: PercentageMetric
    let showAntigravityModelBreakdown: Bool

    private var provider: Provider { account.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            // Switch on single source of truth: account.state (per Task A4)
            switch account.state {
            case .unknown:
                unknownStateBody

            case .error:
                errorStateBody

            case .restored:
                restoredStateBody

            case .stale:
                staleStateBody

            case .fresh:
                freshStateBody
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(account.state == .stale ? 0.25 : 0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Label(provider.displayName, systemImage: provider.symbolName)
                .font(.subheadline).bold()

            if !account.label.isEmpty && account.label != "Default" {
                Text(account.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }

            if account.state == .error || account.displayLastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help(account.displayLastError ?? "Account reported an issue")
            }

            Spacer()

            if let asOf = account.asOf {
                Text(syncAge(asOf))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            stateBadge
            routeBadge
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch account.state {
        case .restored:
            badge(text: "Last known — stale since restart", color: .purple)
                .help("Usage data restored from disk after daemon restart; not yet re-polled")
        case .stale:
            badge(text: "Stale", color: .orange)
                .help("Data is older than the configured freshness threshold")
        case .error:
            badge(text: "Error", color: .red)
                .help("Polling or credential failure")
        case .unknown:
            badge(text: "No recent data", color: .gray)
                .help("Data is missing or past hard expiry")
        case .fresh:
            EmptyView()
        }
    }

    @ViewBuilder
    private var routeBadge: some View {
        // Never show "Live" unless state is fresh (removes contradictory "Live" + "Stale" bug!)
        switch account.activeRoute {
        case .injection:
            if provider == .codex {
                badge(text: "Polled (RPC)", color: .blue)
            } else if account.state == .fresh {
                badge(text: "Live", color: .green)
            } else {
                badge(text: "Injection", color: .secondary)
            }
        case .keychain:
            badge(text: "Polled", color: .blue)
        default:
            badge(text: "Inactive", color: .gray)
        }
    }

    // MARK: - State-specific bodies

    private var unknownStateBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No recent data")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = account.displayLastError {
                errorLine(error)
            }
        }
    }

    private var errorStateBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            let message = account.displayLastError ?? "Unable to poll account usage."
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var restoredStateBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data = account.data {
                windowRow(label: "5h", percent: data.usedPercent5h, resetsAt: data.resetsAt5h)
                windowRow(label: "Weekly", percent: data.usedPercentWeekly, resetsAt: data.resetsAtWeekly)
                if account.provider == .antigravity && showAntigravityModelBreakdown {
                    windowRow(label: "5h (C/G)", percent: data.usedPercent5hThirdParty, resetsAt: data.resetsAt5hThirdParty)
                    windowRow(label: "Weekly (C/G)", percent: data.usedPercentWeeklyThirdParty, resetsAt: data.resetsAtWeeklyThirdParty)
                }
            } else {
                Text("No data restored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = account.displayLastError {
                errorLine(error)
            }
        }
    }

    private var staleStateBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data = account.data {
                windowRow(label: "5h", percent: data.usedPercent5h, resetsAt: data.resetsAt5h, isMuted: true)
                windowRow(label: "Weekly", percent: data.usedPercentWeekly, resetsAt: data.resetsAtWeekly, isMuted: true)
                if account.provider == .antigravity && showAntigravityModelBreakdown {
                    windowRow(label: "5h (C/G)", percent: data.usedPercent5hThirdParty, resetsAt: data.resetsAt5hThirdParty, isMuted: true)
                    windowRow(label: "Weekly (C/G)", percent: data.usedPercentWeeklyThirdParty, resetsAt: data.resetsAtWeeklyThirdParty, isMuted: true)
                }
            } else {
                Text("Data is stale")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = account.displayLastError {
                errorLine(error)
            }
        }
        .opacity(0.85)
    }

    private var freshStateBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data = account.data {
                windowRow(label: "5h", percent: data.usedPercent5h, resetsAt: data.resetsAt5h)
                windowRow(label: "Weekly", percent: data.usedPercentWeekly, resetsAt: data.resetsAtWeekly)
                if account.provider == .antigravity && showAntigravityModelBreakdown {
                    windowRow(label: "5h (C/G)", percent: data.usedPercent5hThirdParty, resetsAt: data.resetsAt5hThirdParty)
                    windowRow(label: "Weekly (C/G)", percent: data.usedPercentWeeklyThirdParty, resetsAt: data.resetsAtWeeklyThirdParty)
                }
            } else {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = account.displayLastError {
                errorLine(error)
            }
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func errorLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var labelWidth: CGFloat {
        account.provider == .antigravity ? 98 : 46
    }

    private func windowRow(label: String, percent: Double?, resetsAt: Int?, isMuted: Bool = false) -> some View {
        guard let percent else { return AnyView(EmptyView()) }

        let displayPercent: Double
        switch metric {
        case .used:
            displayPercent = min(max(percent, 0), 100)
        case .remaining:
            displayPercent = min(max(100.0 - percent, 0), 100)
        }

        let metricLabel = metric == .remaining ? "rem" : ""
        let percentDisplayString = metricLabel.isEmpty ? "\(Int(displayPercent))%" : "\(Int(displayPercent))% \(metricLabel)"

        var accessibilityText = "\(provider.displayName) (\(account.label)) \(label): \(Int(displayPercent)) percent \(metric.displayName.lowercased())"
        if let resetsAt {
            accessibilityText += ", resets \(resetCountdown(resetsAt))"
        }

        let barColor = isMuted ? colorForPercent(displayPercent, metric: metric).opacity(0.5) : colorForPercent(displayPercent, metric: metric)

        return AnyView(
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .leading)
                    .foregroundStyle(isMuted ? Color.secondary.opacity(0.7) : Color.secondary)
                ProgressView(value: displayPercent, total: 100)
                    .tint(barColor)
                Text(percentDisplayString)
                    .font(.caption.monospacedDigit())
                    .frame(width: metric == .remaining ? 48 : 34, alignment: .trailing)
                    .foregroundStyle(isMuted ? Color.secondary : Color.primary)
                if let resetsAt {
                    Text(resetCountdown(resetsAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        )
    }

    private func colorForPercent(_ percent: Double, metric: PercentageMetric) -> Color {
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

    private func syncAge(_ unixSeconds: Int64) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970) - Int(unixSeconds))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m\(seconds % 60)s ago"
        }
        let hours = minutes / 60
        return "\(hours)h\(minutes % 60)m ago"
    }

    private static let countdownFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    private func resetCountdown(_ unixSeconds: Int) -> String {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        if interval < 60 { return "in <1m" }
        return "in " + (Self.countdownFormatter.string(from: interval) ?? "")
    }
}

