import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs = DisplayPreferences.shared

    var body: some View {
        TabView {
            AccountsSettingsTab(store: store)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            GeneralSettingsTab(store: store, displayPrefs: displayPrefs)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ProviderHealthTab(store: store)
                .tabItem { Label("Account Health", systemImage: "person.badge.shield.checkmark") }
            DiagnosticsSettingsTab(store: store)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 720, minHeight: 580, idealHeight: 720)
        .task {
            await store.loadConfig()
            await store.loadErrors()
            await store.reload()
        }
    }
}

private struct RouteKey: Hashable {
    let accountId: String
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

// MARK: - Accounts Tab (Task A3)

private struct AccountsSettingsTab: View {
    @ObservedObject var store: UsageStore
    @State private var selectedAccountId: String?
    @State private var isShowingAddSheet = false
    @State private var editingLabel = ""
    @State private var isRenaming = false
    @State private var renameError: String?
    @State private var accountToDelete: Account?
    @State private var showDeleteConfirmation = false
    @State private var testStatuses: [RouteKey: RouteTestState] = [:]
    @State private var draftConfig: DaemonConfig = DaemonConfig()
    @State private var hasInitializedConfig = false

    private var selectedAccount: Account? {
        store.accounts.first { $0.id == selectedAccountId } ?? store.accounts.first
    }

    var body: some View {
        HSplitView {
            // Left list of accounts grouped by provider
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedAccountId) {
                    ForEach(Provider.allCases) { provider in
                        let providerAccounts = store.accounts.filter { $0.provider == provider }
                        Section(header: Label(provider.displayName, systemImage: provider.symbolName)) {
                            if providerAccounts.isEmpty {
                                Text("No accounts configured")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(providerAccounts) { account in
                                    accountListRow(account)
                                        .tag(account.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button {
                        isShowingAddSheet = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(8)

                    Spacer()
                }
                .background(.quaternary.opacity(0.2))
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            // Right detail pane for selected account
            ScrollView {
                if let account = selectedAccount {
                    VStack(alignment: .leading, spacing: 16) {
                        accountHeader(account)

                        Divider()

                        accountRenameSection(account)

                        Divider()

                        accountRouteConfigSection(account)

                        Divider()

                        accountActionsSection(account)
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No account selected")
                            .font(.headline)
                        Text("Select an account on the left or click 'Add Account'.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
            .frame(minWidth: 320)
        }
        .onAppear {
            if selectedAccountId == nil {
                selectedAccountId = store.accounts.first?.id
            }
            if let cfg = store.config {
                draftConfig = cfg
                hasInitializedConfig = true
            }
            if let acct = selectedAccount {
                editingLabel = acct.label
            }
        }
        .onChange(of: selectedAccountId) { _ in
            if let acct = selectedAccount {
                editingLabel = acct.label
            }
        }
        .onChange(of: store.config) { newCfg in
            if let newCfg, !hasInitializedConfig {
                draftConfig = newCfg
                hasInitializedConfig = true
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddAccountSheet(store: store) { newAccount in
                selectedAccountId = newAccount.id
                editingLabel = newAccount.label
            }
        }
        .alert("Remove Account?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive) {
                if let acct = accountToDelete {
                    Task {
                        _ = await store.deleteAccount(id: acct.id)
                        if selectedAccountId == acct.id {
                            selectedAccountId = store.accounts.first?.id
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                accountToDelete = nil
            }
        } message: {
            Text("Are you sure you want to remove '\(accountToDelete?.label ?? "")'? Its stored quota history will be deleted. CLI credentials on your Mac remain untouched.")
        }
    }

    private func accountListRow(_ account: Account) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .font(.body)
                    .bold(account.label == "Default")

                if let dir = account.credentialLocation?.configDir {
                    Text(shortenPath(dir))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if account.credentialLocation?.kind == "daemon_token" {
                    Text("daemon token")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            stateTag(account.state)
        }
        .padding(.vertical, 2)
    }

    private func stateTag(_ state: AccountTrustState) -> some View {
        Text(state.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(stateColor(state).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(stateColor(state))
    }

    private func stateColor(_ state: AccountTrustState) -> Color {
        switch state {
        case .fresh: return .green
        case .stale: return .orange
        case .restored: return .purple
        case .error: return .red
        case .unknown: return .gray
        }
    }

    private func accountHeader(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(account.provider.displayName, systemImage: account.provider.symbolName)
                    .font(.title2).bold()
                Spacer()
                stateTag(account.state)
            }

            if let dir = account.credentialLocation?.configDir {
                HStack {
                    Text("Config Dir:").font(.caption).foregroundStyle(.secondary)
                    Text(dir).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else if account.credentialLocation?.kind == "daemon_token" {
                Text("Credential: Managed by daemon (OAuth token)").font(.caption).foregroundStyle(.secondary)
            }

            if let effective = account.effectiveAccount, !effective.isEmpty {
                HStack {
                    Text("Logged in as:").font(.caption).foregroundStyle(.secondary)
                    Text(effective).font(.caption.bold())
                }
            }
        }
    }

    private func accountRenameSection(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account Label").font(.headline)
            HStack {
                TextField("Label", text: $editingLabel)
                    .textFieldStyle(.roundedBorder)

                Button("Save Label") {
                    let newLabel = editingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newLabel.isEmpty, newLabel != account.label else { return }
                    isRenaming = true
                    Task {
                        let res = await store.updateAccount(id: account.id, label: newLabel)
                        isRenaming = false
                        if case .failure(let err) = res {
                            renameError = "Failed to rename: \(err)"
                        }
                    }
                }
                .disabled(isRenaming || editingLabel.trimmingCharacters(in: .whitespacesAndNewlines) == account.label || editingLabel.isEmpty)
            }
            if let err = renameError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func accountRouteConfigSection(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Routes & Polling for \(account.provider.displayName)")
                .font(.headline)

            let binding = configBinding(for: account.provider)

            if account.provider == .claude {
                // For Claude, "inference polling" and the Keychain route are the same thing
                // (inference mode is what actually drives the Keychain-credentialed poll), so
                // this reuses routeToggleRow (Test button included) with an overridden isOn
                // binding that keeps claudePollingMode and routesEnabled in lockstep instead
                // of two checkboxes that could disagree.
                routeToggleRow(
                    for: account,
                    route: .keychain,
                    label: "Enable inference polling (Keychain route)",
                    binding: binding,
                    isOnOverride: Binding(
                        get: { draftConfig.claudePollingMode == "inference" },
                        set: { isOn in
                            draftConfig.claudePollingMode = isOn ? "inference" : "disabled"
                            var routes = binding.wrappedValue.routesEnabled
                            if isOn, !routes.contains(.keychain) {
                                routes.append(.keychain)
                            } else if !isOn {
                                routes.removeAll { $0 == .keychain }
                            }
                            binding.wrappedValue.routesEnabled = routes
                            Task { _ = await store.saveConfig(draftConfig) }
                        }
                    )
                )
                Text("Off by default: sends a real one-token inference request every \(binding.wrappedValue.keychainPollIntervalSec)s (~\(requestsPerDay(intervalSec: binding.wrappedValue.keychainPollIntervalSec))/day) to read live rate-limit headers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                routeToggleRow(for: account, route: .keychain, label: "Keychain (poll CLI credentials)", binding: binding)
            }

            if account.provider == .codex {
                routeToggleRow(for: account, route: .injection, label: "Local RPC (poll `codex app-server`)", binding: binding)
            } else {
                routeToggleRow(for: account, route: .injection, label: "Injection (real-time CLI hook push)", binding: binding)
            }

            Stepper(
                "Poll interval: \(binding.wrappedValue.keychainPollIntervalSec)s",
                value: Binding(
                    get: { binding.wrappedValue.keychainPollIntervalSec },
                    set: {
                        binding.wrappedValue.keychainPollIntervalSec = $0
                        Task { _ = await store.saveConfig(draftConfig) }
                    }
                ),
                in: 30...600,
                step: 30
            )
            .font(.caption)

            Toggle("Notify near limit", isOn: Binding(
                get: { binding.wrappedValue.notifyThresholdPercent != nil },
                set: { isOn in
                    if isOn {
                        binding.wrappedValue.notifyThresholdPercent = binding.wrappedValue.notifyThresholdPercent ?? 90
                        Task {
                            await NotificationManager.shared.requestAuthorization()
                            _ = await store.saveConfig(draftConfig)
                        }
                    } else {
                        binding.wrappedValue.notifyThresholdPercent = nil
                        Task { _ = await store.saveConfig(draftConfig) }
                    }
                }
            ))
            .font(.caption)

            if let threshold = binding.wrappedValue.notifyThresholdPercent {
                Stepper(
                    "Threshold: \(threshold)%",
                    value: Binding(
                        get: { binding.wrappedValue.notifyThresholdPercent ?? 90 },
                        set: {
                            binding.wrappedValue.notifyThresholdPercent = $0
                            Task { _ = await store.saveConfig(draftConfig) }
                        }
                    ),
                    in: 1...100,
                    step: 5
                )
                .font(.caption)
                .padding(.leading, 16)
            }
        }
    }

    private func requestsPerDay(intervalSec: Int) -> String {
        guard intervalSec > 0 else { return "0" }
        let perDay = 86_400 / intervalSec
        return NumberFormatter.localizedString(from: NSNumber(value: perDay), number: .decimal)
    }

    private func routeToggleRow(
        for account: Account,
        route: Route,
        label: String,
        binding: Binding<ProviderConfig>,
        isOnOverride: Binding<Bool>? = nil
    ) -> some View {
        let key = RouteKey(accountId: account.id, provider: account.provider, route: route)
        let testState = testStatuses[key]

        let isOnBinding = isOnOverride ?? Binding(
            get: { binding.wrappedValue.routesEnabled.contains(route) },
            set: { isOn in
                var routes = binding.wrappedValue.routesEnabled
                if isOn, !routes.contains(route) {
                    routes.append(route)
                } else if !isOn {
                    routes.removeAll { $0 == route }
                }
                binding.wrappedValue.routesEnabled = routes
                Task { _ = await store.saveConfig(draftConfig) }
            }
        )

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(label, isOn: isOnBinding)
                .font(.caption)

                Spacer()

                if testState?.isLoading == true {
                    ProgressView().controlSize(.small)
                } else if let result = testState?.result {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                }

                Button("Test") {
                    testRoute(account: account, route: route)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(testState?.isLoading == true)
            }

            if let result = testState?.result, let msg = result.message, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(result.ok ? Color.secondary : Color.red)
                    .padding(.leading, 18)
            }
        }
    }

    private func testRoute(account: Account, route: Route) {
        let key = RouteKey(accountId: account.id, provider: account.provider, route: route)
        testStatuses[key] = RouteTestState(isLoading: true, result: nil)
        Task {
            let res = await store.testRoute(accountId: account.id, provider: account.provider, route: route)
            let result: TestRouteResponse
            switch res {
            case .success(let response):
                result = response
            case .failure(let error):
                let msg: String
                switch error {
                case .unreachable: msg = "Daemon unreachable"
                case .badResponse(let code): msg = "Daemon error (\(code))"
                case .decodeFailed: msg = "Failed to parse response"
                }
                result = TestRouteResponse(ok: false, provider: account.provider, route: route, message: msg)
            }
            testStatuses[key] = RouteTestState(isLoading: false, result: result)

            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if testStatuses[key]?.isLoading == false {
                testStatuses[key] = nil
            }
        }
    }

    private func accountActionsSection(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account Actions").font(.headline)

            HStack(spacing: 12) {
                Button {
                    Task {
                        _ = await store.resetCredentials(accountId: account.id)
                    }
                } label: {
                    Label("Reset Credentials", systemImage: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    accountToDelete = account
                    showDeleteConfirmation = true
                } label: {
                    Label("Remove Account", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func configBinding(for provider: Provider) -> Binding<ProviderConfig> {
        Binding(
            get: {
                switch provider {
                case .claude: return draftConfig.claude ?? ProviderConfig(routesEnabled: [.keychain], keychainPollIntervalSec: 60)
                case .codex: return draftConfig.codex ?? ProviderConfig(routesEnabled: [.injection], keychainPollIntervalSec: 120)
                case .antigravity: return draftConfig.antigravity ?? ProviderConfig(routesEnabled: [.keychain], keychainPollIntervalSec: 60)
                }
            },
            set: { newValue in
                switch provider {
                case .claude: draftConfig.claude = newValue
                case .codex: draftConfig.codex = newValue
                case .antigravity: draftConfig.antigravity = newValue
                }
            }
        )
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Add Account Sheet

private struct AddAccountSheet: View {
    @ObservedObject var store: UsageStore
    var onCreated: (Account) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: Provider = .claude
    @State private var label: String = ""
    @State private var configDir: String = "~/.claude"
    @State private var antigravityRefreshToken: String = ""
    @State private var antigravityEmail: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account")
                .font(.headline)

            Picker("Provider", selection: $selectedProvider) {
                ForEach(Provider.allCases) { prov in
                    Text(prov.displayName).tag(prov)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedProvider) { prov in
                switch prov {
                case .claude:
                    configDir = "~/.claude"
                    if label.isEmpty || label == "Codex" || label == "Antigravity" { label = "Claude Work" }
                case .codex:
                    configDir = "~/.codex"
                    if label.isEmpty || label == "Claude" || label == "Antigravity" { label = "Codex Work" }
                case .antigravity:
                    if label.isEmpty || label == "Claude" || label == "Codex" { label = "Personal Gmail" }
                }
            }

            TextField("Account Label (e.g. Work, Personal)", text: $label)
                .textFieldStyle(.roundedBorder)

            if selectedProvider == .claude || selectedProvider == .codex {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configuration Directory")
                        .font(.caption).bold()
                    TextField("Config Dir (e.g. ~/.claude-work)", text: $configDir)
                        .textFieldStyle(.roundedBorder)
                    Text("The daemon isolates credentials per account by targeting this directory (\(selectedProvider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME")).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Antigravity manual capture flow
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google OAuth Token (Advanced/Manual)")
                        .font(.caption).bold()
                    SecureField("OAuth Refresh Token", text: $antigravityRefreshToken)
                        .textFieldStyle(.roundedBorder)
                    TextField("Account Email", text: $antigravityEmail)
                        .textFieldStyle(.roundedBorder)
                    Text("Enter your OAuth refresh token and associated email address. The daemon will securely store and refresh this token directly.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Account") {
                    createAccount()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitDisabled)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if label.isEmpty {
                label = "Work"
            }
        }
    }

    private var isSubmitDisabled: Bool {
        if isCreating { return true }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if selectedProvider == .claude || selectedProvider == .codex {
            return configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return antigravityRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || antigravityEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func createAccount() {
        isCreating = true
        errorMessage = nil

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

        let req: CreateAccountRequest
        if selectedProvider == .claude || selectedProvider == .codex {
            let expanded = (configDir.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            req = CreateAccountRequest(
                provider: selectedProvider,
                label: trimmedLabel,
                credentialLocation: CredentialLocation(kind: "config_dir", configDir: expanded)
            )
        } else {
            req = CreateAccountRequest(
                provider: .antigravity,
                label: trimmedLabel,
                credentialLocation: CredentialLocation(kind: "daemon_token"),
                oauthBootstrap: OAuthBootstrap(
                    refreshToken: antigravityRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: antigravityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        Task {
            let result = await store.createAccount(req)
            isCreating = false
            switch result {
            case .success(let account):
                onCreated(account)
                dismiss()
            case .failure(let error):
                switch error {
                case .badResponse(let code):
                    if code == 409 {
                        errorMessage = "An account with this configuration directory already exists."
                    } else {
                        errorMessage = "Server error (\(code)). Check daemon logs."
                    }
                case .unreachable:
                    errorMessage = "Background service is not reachable."
                case .decodeFailed:
                    errorMessage = "Failed to parse daemon response."
                }
            }
        }
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs: DisplayPreferences
    @State private var draft: DaemonConfig = DaemonConfig()
    @State private var saveStatus: String?
    @State private var isSaving: Bool = false
    @State private var hasInitialized: Bool = false
    @State private var saveTask: Task<Void, Never>?
    @State private var isLaunchAgentInstalled: Bool = false
    @State private var isLaunchAtLoginEnabled: Bool = false
    @State private var launchAtLoginError: String?
    @State private var pauseError: String?

    // Uninstall state (Task D11)
    @State private var showUninstallConfirmation = false
    @State private var uninstallResultAlert: String?
    @State private var isUninstallSuccessful = false

    var body: some View {
        Form {
            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { isLaunchAtLoginEnabled },
                    set: { enable in
                        let prev = isLaunchAtLoginEnabled
                        let success = LaunchAgentManager.setEnabled(enable)
                        if success {
                            isLaunchAtLoginEnabled = enable
                        } else {
                            // Revert on failure (Task D9)
                            isLaunchAtLoginEnabled = prev
                            launchAtLoginError = "Failed to update launch at login setting via launchctl."
                        }
                    }
                ))
                .disabled(!isLaunchAgentInstalled)
                .help(isLaunchAgentInstalled ? "Start AI Usage Widget automatically when logging in" : "App was not installed via install.sh")
                .accessibilityLabel("Launch at login")

                if let err = launchAtLoginError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section("Data Collection") {
                Toggle("Pause data collection", isOn: Binding(
                    get: { store.isCollectionPaused },
                    set: { paused in
                        Task {
                            let res = await store.setCollectionPaused(paused)
                            if case .failure(let err) = res {
                                pauseError = "Failed to update pause state: \(err)"
                            } else {
                                pauseError = nil
                            }
                        }
                    }
                ))
                .accessibilityLabel("Pause data collection")

                if let err = pauseError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

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

                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider display order")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(Array(displayPrefs.providerOrder.enumerated()), id: \.element) { index, provider in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)

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

                            Button {
                                displayPrefs.moveDown(provider: provider)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == displayPrefs.providerOrder.count - 1)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 4)
            }

            Section("Desktop Widgets") {
                if displayPrefs.widgetConfigurations.isEmpty {
                    Text("No desktop widgets configured yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach($displayPrefs.widgetConfigurations) { configuration in
                    widgetConfigurationRow(configuration)
                }

                Button {
                    displayPrefs.addWidgetConfiguration()
                } label: {
                    Label("Add Widget", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            // Task D11: Uninstall button with confirmation dialog
            Section("Maintenance & Uninstall") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstall AI Usage Widget")
                            .font(.body)
                        Text("Stops the background service, removes launch agents, and clears installed hooks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uninstall AIUsageWidget…", role: .destructive) {
                        showUninstallConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
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
        .alert("Uninstall AIUsageWidget?", isPresented: $showUninstallConfirmation) {
            Button("Uninstall", role: .destructive) {
                runUninstallScript()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will invoke the official uninstaller to remove the background daemon LaunchAgent, clear statusLine hooks, and remove installed binaries.")
        }
        .alert("Uninstall Result", isPresented: Binding(
            get: { uninstallResultAlert != nil },
            set: { if !$0 {
                uninstallResultAlert = nil
                if isUninstallSuccessful {
                    NSApp.terminate(nil)
                }
            }}
        )) {
            Button("OK", role: .cancel) {
                if isUninstallSuccessful {
                    NSApp.terminate(nil)
                }
            }
        } message: {
            Text(uninstallResultAlert ?? "")
        }
    }

    private func widgetConfigurationRow(_ configuration: Binding<WidgetConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Enabled", isOn: configuration.isEnabled)
                TextField("Widget name", text: configuration.name)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    displayPrefs.removeWidgetConfiguration(id: configuration.wrappedValue.id)
                } label: {
                    Label("Remove Widget", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Picker("Widget style", selection: configuration.style) {
                ForEach(DesktopWidgetStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)

            Picker("Scope", selection: Binding<String?>(
                get: { configuration.wrappedValue.scope.accountId },
                set: { accountId in
                    configuration.wrappedValue.scope = accountId.map { .singleAgent($0) } ?? .allAgents
                }
            )) {
                Text("All agents (combined)").tag(nil as String?)
                ForEach(store.accounts.filter { store.isAccountEnabled($0) }) { account in
                    Text("\(account.provider.displayName) — \(account.label)")
                        .tag(Optional(account.id))
                }
            }
            .pickerStyle(.menu)

            ForEach(WidgetMetricKind.allCases) { metric in
                Toggle(metric.displayName, isOn: Binding(
                    get: { configuration.wrappedValue.visibleMetrics.contains(metric) },
                    set: { isVisible in
                        if isVisible {
                            configuration.wrappedValue.visibleMetrics.insert(metric)
                        } else {
                            configuration.wrappedValue.visibleMetrics.remove(metric)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 4)
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

    /// Task D11: Executes fixed contract uninstaller at ~/Library/Application Support/AIUsageWidget/bin/uninstall.sh
    private func runUninstallScript() {
        let scriptPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsageWidget/bin/uninstall.sh")
            .path

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            uninstallResultAlert = "Uninstaller script not found at expected path:\n\(scriptPath)"
            isUninstallSuccessful = false
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                isUninstallSuccessful = true
                uninstallResultAlert = "AIUsageWidget uninstalled successfully. The application will now close."
            } else {
                isUninstallSuccessful = false
                uninstallResultAlert = "Uninstall failed with exit code \(process.terminationStatus)."
            }
        } catch {
            isUninstallSuccessful = false
            uninstallResultAlert = "Failed to run uninstall script: \(error.localizedDescription)"
        }
    }
}

// MARK: - Health Tab (Per-Account Health)

private struct ProviderHealthTab: View {
    @ObservedObject var store: UsageStore
    @State private var accountToReset: Account?
    @State private var showResetConfirmation: Bool = false
    @State private var isResetting: Bool = false
    @State private var resetResultAlert: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.accounts.isEmpty {
                    Text("No accounts found.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(store.accounts) { account in
                        accountHealthCard(for: account)
                    }
                }
            }
            .padding()
        }
        .alert("Reset \(accountToReset?.label ?? "") (\(accountToReset?.provider.displayName ?? "")) Credentials?", isPresented: $showResetConfirmation) {
            Button("Reset Credentials", role: .destructive) {
                if let account = accountToReset {
                    performReset(for: account)
                }
            }
            Button("Cancel", role: .cancel) {
                accountToReset = nil
            }
        } message: {
            Text("This will clear daemon credential discovery caches and daemon-owned tokens for \(accountToReset?.label ?? ""). CLI credentials and Keychain items are not deleted.")
        }
        .alert(resetResultAlert ?? "Notice", isPresented: Binding(
            get: { resetResultAlert != nil },
            set: { if !$0 { resetResultAlert = nil } }
        )) {
            Button("OK", role: .cancel) { }
        }
    }

    private func accountHealthCard(for account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(account.provider.displayName) - \(account.label)", systemImage: account.provider.symbolName)
                    .font(.headline)

                Spacer()

                Text(account.state.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(healthStateColor(account.state).opacity(0.15), in: Capsule())
                    .foregroundStyle(healthStateColor(account.state))
            }

            Divider()

            VStack(spacing: 6) {
                healthRow(
                    title: "Credential Source",
                    value: account.credentialSource ?? "Discovered on poll",
                    icon: "key.fill"
                )

                if let loc = account.credentialLocation?.configDir {
                    healthRow(title: "Config Directory", value: loc, icon: "folder.fill")
                }

                if let email = account.effectiveAccount, !email.isEmpty {
                    healthRow(title: "Effective Account", value: email, icon: "person.crop.circle")
                }

                healthRow(
                    title: "Last Success",
                    value: account.lastSuccessAt != nil ? relativeTimestamp(account.lastSuccessAt!) : "No recorded success",
                    icon: "checkmark.circle",
                    tint: account.lastSuccessAt != nil ? .green : .secondary
                )

                if let failureAt = account.lastFailureAt {
                    healthRow(
                        title: "Last Failure",
                        value: relativeTimestamp(failureAt),
                        icon: "xmark.circle",
                        tint: .orange
                    )
                }

                if let error = account.displayLastError, !error.isEmpty {
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
                    accountToReset = account
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
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func healthStateColor(_ state: AccountTrustState) -> Color {
        switch state {
        case .fresh: return .green
        case .stale: return .orange
        case .restored: return .purple
        case .error: return .red
        case .unknown: return .gray
        }
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func relativeTimestamp(_ unixSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func performReset(for account: Account) {
        isResetting = true
        Task {
            let result = await store.resetCredentials(accountId: account.id)
            isResetting = false
            switch result {
            case .success(let response):
                resetResultAlert = response.message ?? "Credentials for \(account.label) have been reset."
            case .failure(let error):
                resetResultAlert = "Failed to reset credentials: \(error)"
            }
        }
    }
}

// MARK: - Diagnostics Tab

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

                    Button("Reveal Log in Finder") {
                        revealInFinder(path: logFilePath)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

// MARK: - Advanced Tab

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
                Text("Multi-Account Model (P5)").font(.headline)
                Text("Accounts are managed independently with their own configuration directories or tokens. Claude and Codex accounts point to isolated config directories (like ~/.claude-work or ~/.codex-personal). Antigravity accounts use daemon-managed OAuth tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Routes explained").font(.headline)
                Text("**Keychain** - the app polls the provider's API directly using credentials discovered from CLI stores.")
                    .font(.caption)
                Text("**Injection** - provider CLIs push live usage updates to the daemon in real time via statusLine hooks (Claude, Antigravity).")
                    .font(.caption)
                Text("**Local RPC** (Codex only) - Codex polls `codex app-server` RPC without external network calls.")
                    .font(.caption)
                Text("Trust states: fresh (live), stale (exceeded freshness threshold), restored (stale since daemon restart), unknown (no recent observation), error (poll failure).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}
