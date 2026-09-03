import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Usage")
                .font(.headline)

            ForEach(Provider.allCases) { provider in
                ProviderRow(provider: provider, usage: usage(for: provider))
                if provider != Provider.allCases.last {
                    Divider()
                }
            }

            Divider()

            HStack {
                Button("Refresh") { store.reload() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func usage(for provider: Provider) -> ProviderUsage? {
        switch provider {
        case .claude: return store.snapshot.claude
        case .codex: return store.snapshot.codex
        case .antigravity: return store.snapshot.antigravity
        }
    }
}

private struct ProviderRow: View {
    let provider: Provider
    let usage: ProviderUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.displayName).font(.subheadline).bold()
                Spacer()
                if let updatedAt = usage?.updatedAt {
                    Text(relativeAge(updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = usage?.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if usage == nil {
                Text("No data yet").font(.caption).foregroundStyle(.secondary)
            } else {
                windowRow(label: "5h", window: usage?.fiveHour)
                windowRow(label: "Weekly", window: usage?.weekly)
            }
        }
    }

    private func windowRow(label: String, window: WindowUsage?) -> AnyView {
        guard let window else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.caption).frame(width: 48, alignment: .leading)
                    ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                    Text("\(Int(window.usedPercent))%")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                if let resetsAt = window.resetsAt {
                    Text("resets \(resetCountdown(resetsAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 52)
                }
            }
        )
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
