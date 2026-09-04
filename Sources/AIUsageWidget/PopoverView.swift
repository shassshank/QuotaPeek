import AppKit
import SwiftUI

struct PopoverView: View {
    private enum Layout {
        static let width: CGFloat = 300
    }

    @ObservedObject var store: UsageStore
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !store.isDaemonReachable {
                disconnectedBanner
            }

            VStack(spacing: 10) {
                ForEach(Provider.allCases) { provider in
                    ProviderCard(status: store.providers[provider])
                }
            }

            Divider()

            footer
        }
        .padding(16)
        .frame(width: Layout.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
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
            .help("Settings")
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
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
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

            Spacer()

            Button("Quit", action: quitApplication)
        }
    }

    private func quitApplication() {
        NSApp.terminate(nil)
    }
}

private struct ProviderCard: View {
    let status: ProviderStatus?

    private var provider: Provider { status?.provider ?? .claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(provider.displayName, systemImage: provider.symbolName)
                    .font(.subheadline).bold()
                Spacer()
                routeBadge
            }

            if let error = status?.lastError {
                errorLine(error)
            } else if let data = status?.data {
                windowRow(label: "5h", percent: data.usedPercent5h, resetsAt: data.resetsAt5h)
                windowRow(label: "Weekly", percent: data.usedPercentWeekly, resetsAt: data.resetsAtWeekly)
                if let asOf = status?.asOf {
                    Text("Updated \(relativeAge(asOf))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
            badge(text: "Live", color: .green)
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

    private func errorLine(_ error: ProviderError) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func windowRow(label: String, percent: Double?, resetsAt: Int?) -> some View {
        guard let percent else { return AnyView(EmptyView()) }
        let clamped = min(max(percent, 0), 100)
        return AnyView(
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .frame(width: 46, alignment: .leading)
                    .foregroundStyle(.secondary)
                ProgressView(value: clamped, total: 100)
                    .tint(colorForPercent(clamped))
                Text("\(Int(clamped))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
                if let resetsAt {
                    Text(resetCountdown(resetsAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        )
    }

    private func colorForPercent(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .red
        }
    }

    private func relativeAge(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func resetCountdown(_ unixSeconds: Int) -> String {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval > 3600 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return "in " + (formatter.string(from: interval) ?? "")
    }
}
