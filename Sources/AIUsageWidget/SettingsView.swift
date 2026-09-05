import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            DiagnosticsSettingsTab(store: store)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 460, height: 360)
        .task {
            await store.loadConfig()
            await store.loadErrors()
        }
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var store: UsageStore
    @State private var draft: DaemonConfig = DaemonConfig()
    @State private var saveStatus: String?

    var body: some View {
        Form {
            Section("Claude") {
                routeToggles(for: .claude)
            }
            Section("Codex") {
                Text("Keychain reads Codex's own OAuth token (from macOS Keychain if `codex login` uses keyring storage, otherwise from ~/.codex/auth.json) and polls OpenAI directly. Local RPC instead polls a spawned `codex app-server` process - Codex has no push-based hook, so unlike Claude/Antigravity this is not real-time injection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                routeToggles(for: .codex)
            }
            Section("Antigravity") {
                routeToggles(for: .antigravity)
            }

            if let saveStatus {
                Text(saveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Save") {
                Task {
                    let ok = await store.saveConfig(draft)
                    saveStatus = ok ? "Saved." : "Could not save - is the background service running?"
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = store.config ?? DaemonConfig() }
        .onChange(of: store.config?.claude?.routesEnabled) { _ in draft = store.config ?? draft }
    }

    @ViewBuilder
    private func routeToggles(for provider: Provider, allowKeychain: Bool = true) -> some View {
        let binding = configBinding(for: provider)
        if allowKeychain {
            Toggle("Keychain (poll the provider's API directly)", isOn: routeBinding(binding, .keychain))
        }
        if provider == .codex {
            Toggle("Local RPC (poll `codex app-server` directly, no network call)", isOn: routeBinding(binding, .injection))
        } else {
            Toggle("Injection (real-time push from the provider's own CLI)", isOn: routeBinding(binding, .injection))
        }
        Stepper(
            "Poll interval: \(binding.wrappedValue.keychainPollIntervalSec)s",
            value: Binding(
                get: { binding.wrappedValue.keychainPollIntervalSec },
                set: { binding.wrappedValue.keychainPollIntervalSec = $0 }
            ),
            in: 30...600,
            step: 30
        )
    }

    private func configBinding(for provider: Provider) -> Binding<ProviderConfig> {
        Binding(
            get: {
                switch provider {
                case .claude: return draft.claude ?? ProviderConfig(routesEnabled: [.keychain], keychainPollIntervalSec: 60)
                case .codex: return draft.codex ?? ProviderConfig(routesEnabled: [.injection], keychainPollIntervalSec: 120)
                case .antigravity: return draft.antigravity ?? ProviderConfig(routesEnabled: [.keychain], keychainPollIntervalSec: 60)
                }
            },
            set: { newValue in
                switch provider {
                case .claude: draft.claude = newValue
                case .codex: draft.codex = newValue
                case .antigravity: draft.antigravity = newValue
                }
            }
        )
    }

    private func routeBinding(_ config: Binding<ProviderConfig>, _ route: Route) -> Binding<Bool> {
        Binding(
            get: { config.wrappedValue.routesEnabled.contains(route) },
            set: { isOn in
                var routes = config.wrappedValue.routesEnabled
                if isOn, !routes.contains(route) {
                    routes.append(route)
                } else if !isOn {
                    routes.removeAll { $0 == route }
                }
                config.wrappedValue.routesEnabled = routes
            }
        )
    }
}

private struct DiagnosticsSettingsTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent errors").font(.headline)
                Spacer()
                Button("Refresh") { Task { await store.loadErrors() } }
            }

            if store.errors.isEmpty {
                Text("No errors recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.errors) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.provider.displayName).bold()
                            Text("(\(entry.route.rawValue))")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(relativeAge(entry.at))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private func relativeAge(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct AdvancedSettingsTab: View {
    private var appSupportPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageWidget", isDirectory: true)
            .path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Config & logs").font(.headline)
                Text(appSupportPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Routes explained").font(.headline)
                Text("**Keychain** - the app polls the provider's API directly, using credentials already stored by that CLI on this Mac.")
                    .font(.caption)
                Text("**Injection** - the provider's own CLI pushes live usage data to this app in real time via a small hook, when that provider supports it (Claude, Antigravity).")
                    .font(.caption)
                Text("**Local RPC** (Codex only) - Codex has no push hook, so this app instead spawns `codex app-server` and polls its RPC directly; it's labeled \"Polled\" rather than \"Live\" for that reason.")
                    .font(.caption)
                Text("If both routes are enabled for a provider, the freshest data wins; a stale sample falls back to the other route automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}
