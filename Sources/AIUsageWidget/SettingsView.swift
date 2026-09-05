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
        .frame(width: 480, height: 480)
        .task {
            await store.loadConfig()
            await store.loadErrors()
        }
    }
}

private struct RouteKey: Hashable {
    let provider: Provider
    let route: Route
}

private struct RouteTestState {
    var isLoading: Bool
    var result: TestRouteResponse?
}

private enum LaunchAgentManager {
    static let serviceName = "com.aiusagewidget.app"

    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(serviceName).plist")
            .path
    }

    static var isPlistInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func isLoaded() -> Bool {
        guard isPlistInstalled else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", serviceName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    static func setEnabled(_ enable: Bool) -> Bool {
        guard isPlistInstalled else { return false }
        let path = plistPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = enable ? ["load", path] : ["unload", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var store: UsageStore
    @State private var draft: DaemonConfig = DaemonConfig()
    @State private var saveStatus: String?
    @State private var testStatuses: [RouteKey: RouteTestState] = [:]
    @State private var isLaunchAgentInstalled: Bool = false
    @State private var isLaunchAtLoginEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { isLaunchAtLoginEnabled },
                    set: { enable in
                        isLaunchAtLoginEnabled = enable
                        LaunchAgentManager.setEnabled(enable)
                    }
                ))
                .disabled(!isLaunchAgentInstalled)
                .help(isLaunchAgentInstalled ? "Start AI Usage Widget automatically when logging in" : "App was not installed via install.sh")
            }

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
        .onAppear {
            if let config = store.config {
                draft = config
            }
            isLaunchAgentInstalled = LaunchAgentManager.isPlistInstalled
            isLaunchAtLoginEnabled = LaunchAgentManager.isLoaded()
        }
        .onChange(of: store.config) { newConfig in
            if let newConfig {
                draft = newConfig
            }
        }
    }

    @ViewBuilder
    private func routeToggles(for provider: Provider, allowKeychain: Bool = true) -> some View {
        let binding = configBinding(for: provider)
        if allowKeychain {
            routeToggleRow(for: provider, route: .keychain, label: "Keychain (poll the provider's API directly)", binding: binding)
        }
        if provider == .codex {
            routeToggleRow(for: provider, route: .injection, label: "Local RPC (poll `codex app-server` directly, no network call)", binding: binding)
        } else {
            routeToggleRow(for: provider, route: .injection, label: "Injection (real-time push from the provider's own CLI)", binding: binding)
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
        Toggle("Notify near limit", isOn: Binding(
            get: { binding.wrappedValue.notifyThresholdPercent != nil },
            set: { isOn in
                if isOn {
                    binding.wrappedValue.notifyThresholdPercent = binding.wrappedValue.notifyThresholdPercent ?? 90
                } else {
                    binding.wrappedValue.notifyThresholdPercent = nil
                }
            }
        ))
        if let threshold = binding.wrappedValue.notifyThresholdPercent {
            Stepper(
                "Threshold: \(threshold)%",
                value: Binding(
                    get: { binding.wrappedValue.notifyThresholdPercent ?? 90 },
                    set: { binding.wrappedValue.notifyThresholdPercent = $0 }
                ),
                in: 1...100,
                step: 5
            )
            .padding(.leading, 18)
        }
    }

    @ViewBuilder
    private func routeToggleRow(
        for provider: Provider,
        route: Route,
        label: String,
        binding: Binding<ProviderConfig>
    ) -> some View {
        let key = RouteKey(provider: provider, route: route)
        let testState = testStatuses[key]

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(label, isOn: routeBinding(binding, route))
                Spacer()
                if testState?.isLoading == true {
                    ProgressView()
                        .controlSize(.small)
                } else if let result = testState?.result {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                }
                Button("Test") {
                    testRoute(provider: provider, route: route)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(testState?.isLoading == true)
            }

            if let result = testState?.result, let message = result.message, !message.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: result.ok ? "checkmark" : "xmark")
                        .font(.caption2)
                        .foregroundStyle(result.ok ? .green : .red)
                        .padding(.top, 1)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(result.ok ? Color.secondary : Color.red)
                }
                .padding(.leading, 18)
            }
        }
    }

    private func testRoute(provider: Provider, route: Route) {
        let key = RouteKey(provider: provider, route: route)
        testStatuses[key] = RouteTestState(isLoading: true, result: nil)
        Task {
            let res = await store.testRoute(provider: provider, route: route)
            let result: TestRouteResponse
            switch res {
            case .success(let response):
                result = response
            case .failure(let error):
                let message: String
                switch error {
                case .unreachable: message = "Daemon unreachable"
                case .badResponse(let code): message = "Daemon returned error (\(code))"
                case .decodeFailed: message = "Failed to parse response"
                }
                result = TestRouteResponse(ok: false, provider: provider, route: route, message: message)
            }
            testStatuses[key] = RouteTestState(isLoading: false, result: result)

            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if testStatuses[key]?.isLoading == false {
                testStatuses[key] = nil
            }
        }
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
