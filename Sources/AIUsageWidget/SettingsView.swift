import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs = DisplayPreferences.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store, displayPrefs: displayPrefs)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ProviderHealthTab(store: store)
                .tabItem { Label("Provider Health", systemImage: "person.badge.shield.checkmark") }
            DiagnosticsSettingsTab(store: store)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 680, minHeight: 560, idealHeight: 700)
        .task {
            await store.loadConfig()
            await store.loadErrors()
            await store.reload()
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
        process.arguments = enable ? ["load", "-w", path] : ["unload", "-w", path]
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
    @ObservedObject var displayPrefs: DisplayPreferences
    @State private var draft: DaemonConfig = DaemonConfig()
    @State private var saveStatus: String?
    @State private var isSaving: Bool = false
    @State private var hasInitialized: Bool = false
    @State private var saveTask: Task<Void, Never>?
    @State private var testStatuses: [RouteKey: RouteTestState] = [:]
    @State private var isLaunchAgentInstalled: Bool = false
    @State private var isLaunchAtLoginEnabled: Bool = false

    var body: some View {
        Form {
            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { isLaunchAtLoginEnabled },
                    set: { enable in
                        isLaunchAtLoginEnabled = enable
                        LaunchAgentManager.setEnabled(enable)
                    }
                ))
                .disabled(!isLaunchAgentInstalled)
                .help(isLaunchAgentInstalled ? "Start AI Usage Widget automatically when logging in" : "App was not installed via install.sh")
                .accessibilityLabel("Launch at login")
                .accessibilityHint("Start AI Usage Widget automatically when logging into macOS")
            }

            Section("Data Collection") {
                Toggle("Pause data collection", isOn: Binding(
                    get: { store.isCollectionPaused },
                    set: { paused in
                        Task {
                            _ = await store.setCollectionPaused(paused)
                        }
                    }
                ))
                .accessibilityLabel("Pause data collection")
                .accessibilityHint("Temporarily halts background polling and quota requests without quitting the app")

                Text("Temporarily halts background polling and quota requests without stopping the daemon or quitting the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Mark data stale after: \(formatDuration(draft.staleAfterSeconds ?? 600))",
                    value: Binding(
                        get: { draft.staleAfterSeconds ?? 600 },
                        set: { draft.staleAfterSeconds = max(60, $0) }
                    ),
                    in: 60...3600,
                    step: 60
                )
                .accessibilityLabel("Freshness policy threshold")
                .accessibilityValue(formatDuration(draft.staleAfterSeconds ?? 600))

                Text("Controls when cached provider usage data is shown as \"stale\" with a warning indicator. Minimum threshold is 60 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar & Display") {
                Picker("Menu bar display mode", selection: $displayPrefs.menuBarMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Menu bar display mode")

                Picker("Percentage style", selection: $displayPrefs.percentageMetric) {
                    ForEach(PercentageMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Percentage metric style")

                Text("Choose whether percentages throughout the widget and menu bar reflect quota used or quota remaining.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider display order")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(Array(displayPrefs.providerOrder.enumerated()), id: \.element) { index, provider in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .help("Drag to reorder")

                            Label(provider.displayName, systemImage: provider.symbolName)
                                .font(.body)

                            Spacer()

                            Button {
                                displayPrefs.moveUp(provider: provider)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            .help("Move up")
                            .accessibilityLabel("Move \(provider.displayName) up")

                            Button {
                                displayPrefs.moveDown(provider: provider)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == displayPrefs.providerOrder.count - 1)
                            .help("Move down")
                            .accessibilityLabel("Move \(provider.displayName) down")
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 4)
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

            Section {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving changes...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let saveStatus {
                        Image(systemName: saveStatus.contains("Could not") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(saveStatus.contains("Could not") ? .orange : .green)
                        Text(saveStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Text("All changes saved automatically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let config = store.config {
                draft = config
                hasInitialized = true
            }
            isLaunchAgentInstalled = LaunchAgentManager.isPlistInstalled
            isLaunchAtLoginEnabled = LaunchAgentManager.isLoaded()
        }
        .onChange(of: store.config) { newConfig in
            if let newConfig {
                if !hasInitialized {
                    draft = newConfig
                    hasInitialized = true
                } else if draft != newConfig && !isSaving {
                    draft = newConfig
                }
            }
        }
        .onChange(of: draft) { newDraft in
            guard hasInitialized else { return }
            guard newDraft != store.config else { return }

            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                isSaving = true
                let ok = await store.saveConfig(newDraft)
                isSaving = false
                saveStatus = ok ? "Saved automatically" : "Could not save - background service unreachable"
            }
        }
        .onDisappear {
            saveTask?.cancel()
            if hasInitialized && draft != store.config {
                Task {
                    await store.saveConfig(draft)
                }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds % 60 == 0 {
            let mins = seconds / 60
            return mins == 1 ? "1 min" : "\(mins) mins"
        } else {
            let mins = seconds / 60
            let rem = seconds % 60
            return "\(mins)m \(rem)s"
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
        .accessibilityLabel("\(provider.displayName) poll interval")

        Toggle("Notify near limit", isOn: Binding(
            get: { binding.wrappedValue.notifyThresholdPercent != nil },
            set: { isOn in
                if isOn {
                    binding.wrappedValue.notifyThresholdPercent = binding.wrappedValue.notifyThresholdPercent ?? 90
                    Task {
                        await NotificationManager.shared.requestAuthorization()
                    }
                } else {
                    binding.wrappedValue.notifyThresholdPercent = nil
                }
            }
        ))
        .accessibilityLabel("\(provider.displayName) notify near limit")

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
            .accessibilityLabel("\(provider.displayName) notification threshold")

            Button("Send test notification") {
                NotificationManager.shared.sendTestNotification(for: provider)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.leading, 18)
            .accessibilityLabel("Send test notification for \(provider.displayName)")
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
                    .accessibilityLabel("Enable \(route.rawValue) for \(provider.displayName)")
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
                .accessibilityLabel("Test \(route.rawValue) for \(provider.displayName)")
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

private struct ProviderHealthTab: View {
    @ObservedObject var store: UsageStore
    @State private var providerToReset: Provider?
    @State private var showResetConfirmation: Bool = false
    @State private var isResetting: Bool = false
    @State private var resetResultAlert: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Provider.allCases) { provider in
                    providerHealthCard(for: provider)
                }
            }
            .padding()
        }
        .alert("Reset \(providerToReset?.displayName ?? "") Credentials?", isPresented: $showResetConfirmation) {
            Button("Reset Credentials", role: .destructive) {
                if let provider = providerToReset {
                    performReset(for: provider)
                }
            }
            Button("Cancel", role: .cancel) {
                providerToReset = nil
            }
        } message: {
            Text("This will clear cached OAuth tokens and stored session credentials for \(providerToReset?.displayName ?? ""). You may need to log in again using its command-line tool.")
        }
        .alert(resetResultAlert ?? "Notice", isPresented: Binding(
            get: { resetResultAlert != nil },
            set: { if !$0 { resetResultAlert = nil } }
        )) {
            Button("OK", role: .cancel) { }
        }
    }

    private func providerHealthCard(for provider: Provider) -> some View {
        let status = store.providers[provider]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(provider.displayName, systemImage: provider.symbolName)
                    .font(.headline)

                Spacer()

                if let route = status?.activeRoute, route != .none {
                    Text(route == .injection ? (provider == .codex ? "Local RPC" : "Injection") : "Keychain")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.blue)
                } else {
                    Text("Inactive")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(spacing: 6) {
                healthRow(
                    title: "Credential Source",
                    value: status?.credentialSource ?? defaultCredentialSource(for: provider),
                    icon: "key.fill"
                )

                if let account = status?.effectiveAccount, !account.isEmpty {
                    healthRow(title: "Account", value: account, icon: "person.crop.circle")
                }

                healthRow(
                    title: "Last Success",
                    value: status?.lastSuccessAt != nil ? relativeTimestamp(status!.lastSuccessAt!) : "No recorded success",
                    icon: "checkmark.circle",
                    tint: status?.lastSuccessAt != nil ? .green : .secondary
                )

                if let failureAt = status?.lastFailureAt {
                    healthRow(
                        title: "Last Failure",
                        value: relativeTimestamp(failureAt),
                        icon: "xmark.circle",
                        tint: .orange
                    )
                }

                if let error = status?.displayLastError, !error.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last Error")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    providerToReset = provider
                    showResetConfirmation = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise.circle")
                        Text("Reset Credentials")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isResetting)
                .accessibilityLabel("Reset credentials for \(provider.displayName)")
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func healthRow(title: String, value: String, icon: String, tint: Color = .primary) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint == .primary ? Color.secondary : tint)
                .frame(width: 16)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
        }
    }

    private func defaultCredentialSource(for provider: Provider) -> String {
        switch provider {
        case .claude: return "macOS Keychain / Session"
        case .codex: return "Keychain / ~/.codex/auth.json"
        case .antigravity: return "macOS Keychain / OAuth"
        }
    }

    private func relativeTimestamp(_ unixSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func performReset(for provider: Provider) {
        isResetting = true
        Task {
            let result = await store.resetCredentials(for: provider)
            isResetting = false
            switch result {
            case .success(let response):
                resetResultAlert = response.message ?? "Credentials for \(provider.displayName) have been reset."
            case .failure(let error):
                resetResultAlert = "Failed to reset credentials: \(error)"
            }
        }
    }
}

private struct DiagnosticsSettingsTab: View {
    @ObservedObject var store: UsageStore

    private var appSupportPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsageWidget", isDirectory: true)
            .path
    }

    private var logFilePath: String {
        (appSupportPath as NSString).appendingPathComponent("daemon.log")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent errors").font(.headline)
                Spacer()
                Button("Refresh") { Task { await store.loadErrors() } }
                    .accessibilityLabel("Refresh error log")
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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Diagnostics & Files").font(.subheadline).bold()
                HStack(spacing: 12) {
                    Button("Reveal Config in Finder") {
                        revealInFinder(path: appSupportPath)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Reveal configuration folder in Finder")

                    Button("Reveal Log in Finder") {
                        revealInFinder(path: logFilePath)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Reveal daemon log file in Finder")
                }
            }
            .padding(.top, 4)
        }
        .padding()
    }

    private func relativeAge(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func revealInFinder(path: String) {
        let fileURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            let folderURL = fileURL.hasDirectoryPath ? fileURL : fileURL.deletingLastPathComponent()
            NSWorkspace.shared.open(folderURL)
        }
    }
}

private struct AdvancedSettingsTab: View {
    private var appSupportPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsageWidget", isDirectory: true)
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
