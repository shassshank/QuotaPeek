import AppKit
import Charts
import SwiftUI

struct PopoverView: View {
    private enum Layout {
        static let width: CGFloat = 300
    }

    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs = DisplayPreferences.shared
    var openSettings: () -> Void
    var closePopover: () -> Void

    private var enabledProviders: [Provider] {
        displayPrefs.providerOrder.filter { store.isProviderEnabled($0) }
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

            if enabledProviders.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 10) {
                    ForEach(enabledProviders) { provider in
                        ProviderCard(
                            status: store.providers[provider],
                            history: store.history[provider],
                            metric: displayPrefs.percentageMetric,
                            isStale: store.isProviderStale(provider)
                        )
                    }
                }
            }

            Divider()

            footer
        }
        .padding(16)
        .frame(width: Layout.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand {
            closePopover()
        }
    }

    private var header: some View {
        HStack {
            Label("AI Usage", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
            Spacer()
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
                Task { _ = await store.setCollectionPaused(false) }
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
            Text("No providers configured yet")
                .font(.subheadline).bold()
            Text("Enable at least one provider route in Settings to see your AI usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Configure Providers", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
                .accessibilityLabel("Configure Providers in Settings")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.refresh() }
            } label: {
                HStack(spacing: 4) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
            }
            .disabled(store.isRefreshing)
            .accessibilityLabel("Refresh usage data")

            Button {
                Task { _ = await store.setCollectionPaused(!store.isCollectionPaused) }
            } label: {
                Image(systemName: store.isCollectionPaused ? "play.circle" : "pause.circle")
            }
            .buttonStyle(.borderless)
            .help(store.isCollectionPaused ? "Resume collection" : "Pause collection")
            .accessibilityLabel(store.isCollectionPaused ? "Resume collection" : "Pause collection")

            Spacer()

            Button("Quit", action: quitApplication)
                .accessibilityLabel("Quit application")
        }
    }

    private func quitApplication() {
        NSApp.terminate(nil)
    }
}

private struct ProviderCard: View {
    let status: ProviderStatus?
    let history: [HistoryPoint]?
    let metric: PercentageMetric
    let isStale: Bool

    private var provider: Provider { status?.provider ?? .claude }

    private var sparklineTintColor: Color {
        let latestUsage = history?.last?.usedPercent ?? status?.data?.usedPercent5h ?? status?.data?.usedPercentWeekly ?? 0
        return colorForPercent(latestUsage, metric: metric)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(provider.displayName, systemImage: provider.symbolName)
                    .font(.subheadline).bold()
                if status?.displayLastError != nil || status?.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help(status?.displayLastError ?? "Error")
                }
                Spacer()
                if let asOf = status?.asOf {
                    Text(syncAge(asOf))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if status?.isRestoredFromDisk == true {
                    badge(text: "Restored", color: .purple)
                        .help("Usage data restored from disk after daemon restart")
                } else if isStale {
                    badge(text: "Stale", color: .orange)
                        .help("Data is older than freshness threshold")
                }
                routeBadge
            }

            if let data = status?.data {
                windowRow(label: "5h", percent: data.usedPercent5h, resetsAt: data.resetsAt5h)
                windowRow(label: "Weekly", percent: data.usedPercentWeekly, resetsAt: data.resetsAtWeekly)
                windowRow(label: "Context", percent: data.contextWindowUsedPercent, resetsAt: nil)
                if let error = status?.displayLastError {
                    errorLine(error)
                }
                if let history, history.count >= 2 {
                    SparklineView(points: history, tintColor: sparklineTintColor)
                }
            } else if let error = status?.displayLastError {
                errorLine(error)
                if let history, history.count >= 2 {
                    SparklineView(points: history, tintColor: sparklineTintColor)
                }
            } else {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var routeBadge: some View {
        switch status?.activeRoute {
        case .injection:
            if provider == .codex {
                badge(text: "Polled (RPC)", color: .blue)
            } else {
                badge(text: "Live", color: .green)
            }
        case .keychain:
            badge(text: "Polled", color: .blue)
        default:
            badge(text: "No data", color: .gray)
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

    private func windowRow(label: String, percent: Double?, resetsAt: Int?) -> some View {
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

        var accessibilityText = "\(provider.displayName) \(label): \(Int(displayPercent)) percent \(metric.displayName.lowercased())"
        if let resetsAt {
            accessibilityText += ", resets \(resetCountdown(resetsAt))"
        }

        return AnyView(
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .frame(width: 46, alignment: .leading)
                    .foregroundStyle(.secondary)
                ProgressView(value: displayPercent, total: 100)
                    .tint(colorForPercent(displayPercent, metric: metric))
                Text(percentDisplayString)
                    .font(.caption.monospacedDigit())
                    .frame(width: metric == .remaining ? 48 : 34, alignment: .trailing)
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
            switch percent {
            case ..<15: return .red
            case ..<40: return .yellow
            default: return .green
            }
        }
    }

    private func syncAge(_ unixSeconds: Int) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970) - unixSeconds)
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

    private func resetCountdown(_ unixSeconds: Int) -> String {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        if interval < 60 { return "in <1m" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return "in " + (formatter.string(from: interval) ?? "")
    }
}

private struct SparklineView: View {
    let points: [HistoryPoint]
    var tintColor: Color = .accentColor

    private var sortedPoints: [HistoryPoint] {
        points.sorted { $0.at < $1.at }
    }

    private var burnRateText: String? {
        let pts = sortedPoints
        guard pts.count >= 2,
              let first = pts.first,
              let last = pts.last else { return nil }
        let timeDiffHours = Double(last.at - first.at) / 3600.0
        guard timeDiffHours >= 0.05 else { return nil } // at least 3 minutes between points
        let usageDiff = last.usedPercent - first.usedPercent
        let ratePerHour = usageDiff / timeDiffHours
        let sign = ratePerHour >= 0 ? "+" : ""
        return String(format: "%@%.1f%%/h", sign, ratePerHour)
    }

    private var yDomain: ClosedRange<Double> {
        let values = sortedPoints.map(\.usedPercent)
        let minVal = max(0, (values.min() ?? 0) - 2)
        let maxVal = min(100, (values.max() ?? 100) + 2)
        if minVal >= maxVal {
            return max(0, minVal - 5)...min(100, maxVal + 5)
        }
        return minVal...maxVal
    }

    var body: some View {
        if sortedPoints.count >= 2 {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Trend")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let burnRate = burnRateText {
                        Text(burnRate)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Burn rate per hour based on recent usage")
                    }
                }

                Chart(sortedPoints) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Usage", point.usedPercent)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [tintColor.opacity(0.25), tintColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Usage", point.usedPercent)
                    )
                    .foregroundStyle(tintColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: yDomain)
                .frame(height: 30)
            }
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Usage trend: \(burnRateText ?? "history sparkline")")
        } else {
            EmptyView()
        }
    }
}
