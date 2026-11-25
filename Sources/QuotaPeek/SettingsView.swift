import QuotaPeekCore
import AppKit
import Darwin
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
            WidgetSettingsTab(store: store, displayPrefs: displayPrefs)
                .tabItem { Label("Widget", systemImage: "rectangle.on.desktop") }
            ProviderHealthTab(store: store)
                .tabItem { Label("Account Health", systemImage: "person.badge.shield.checkmark") }
            AdvancedSettingsTab(store: store)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 720, minHeight: 580, idealHeight: 720)
        .onAppear { store.loadErrors() }
    }
}

private struct RouteKey: Hashable {
    let accountId: String
    let route: Route
}

private struct RouteTestState {
    var isLoading: Bool
    var result: RouteCheckResult?
}

private enum LaunchAgentManager {
    static let serviceName = "com.quotapeek.app"

    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(serviceName).plist")
            .path
    }

    static var isPlistInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// gui/<uid>/<label> target string launchctl's per-user domain commands expect.
    private static var guiTarget: String {
        "gui/\(getuid())/\(serviceName)"
    }

    /// launchctl calls are normally fast, but nothing guarantees that: a hung
    /// launchctl would otherwise block whichever thread calls waitUntilExit()
    /// forever. This bounds the wait and force-terminates the process if it
    /// hasn't exited within `timeout` seconds.
    private static func waitWithTimeout(_ process: Process, timeout: TimeInterval = 5.0) {
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
    }

    /// Whether the LaunchAgent is currently disabled via a launchctl override
    /// (i.e. `launchctl disable`d — this does NOT affect the already-running
    /// process, only whether it launches again at next login/boot).
    ///
    /// Note: this reflects the *enabled/disabled* override, not whether the
    /// job happens to be loaded/running right now — that distinction is the
    /// whole point of using `enable`/`disable` instead of `load -w`/`unload -w`.
    ///
    /// Shells out synchronously - call from a background queue (see `isLoadedAsync`).
    static func isLoaded() -> Bool {
        guard isPlistInstalled else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print-disabled", "gui/\(getuid())/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            waitWithTimeout(process)
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                // If we can't determine the override state, assume enabled
                // (the common/default case) rather than reporting disabled.
                return true
            }
            // Lines look like: "\t\"com.quotapeek.app\" => disabled"
            for line in output.split(separator: "\n") {
                guard line.contains(serviceName) else { continue }
                return !line.contains("=> disabled")
            }
            // Not listed in the disabled table at all means it's enabled.
            return true
        } catch {
            return true
        }
    }

    /// Async wrapper around `isLoaded()` that runs the shell-out off the main
    /// thread and delivers the result back on the main thread.
    static func isLoadedAsync(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = isLoaded()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Shells out synchronously - call from a background queue (see `setEnabledAsync`).
    @discardableResult
    static func setEnabled(_ enable: Bool) -> Bool {
        guard isPlistInstalled else { return false }
        // `enable`/`disable` only flips a persisted override in launchd's
        // per-user domain — it never loads, unloads, starts, or stops the
        // job, so it cannot touch the already-running app process. This is
        // the same mechanism macOS's own "Open at Login" toggle uses.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [enable ? "enable" : "disable", guiTarget]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            waitWithTimeout(process)
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Async wrapper around `setEnabled(_:)` that runs the shell-out off the main
    /// thread and delivers the result back on the main thread.
    static func setEnabledAsync(_ enable: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = setEnabled(enable)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - Accounts Tab (Task A3)

private struct AccountsSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs = DisplayPreferences.shared
    @State private var selectedAccountId: String?
    @State private var isShowingAddSheet = false
    @State private var editingLabel = ""
    @State private var renameError: String?
    @State private var accountToDelete: Account?
    @State private var showDeleteConfirmation = false
    @State private var testStatuses: [RouteKey: RouteTestState] = [:]

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
            if let acct = selectedAccount {
                editingLabel = acct.label
            }
        }
        .onChange(of: selectedAccountId) { _ in
            renameError = nil
            if let acct = selectedAccount {
                editingLabel = acct.label
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
                    _ = store.deleteAccount(id: acct.id)
                    if selectedAccountId == acct.id {
                        selectedAccountId = store.accounts.first?.id
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                accountToDelete = nil
            }
        } message: {
            Text("Are you sure you want to remove '\(accountToDelete?.label ?? "")'? QuotaPeek stops showing it. CLI logins on your Mac remain untouched.")
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
                } else if account.provider == .antigravity {
                    Text("statusline hook")
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
            .background(state.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(state.color)
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
            } else if account.provider == .antigravity {
                Text("Read from agy's statusline hook").font(.caption).foregroundStyle(.secondary)
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
                    if case .failure(let err) = store.renameAccount(id: account.id, label: newLabel) {
                        renameError = err.description
                    } else {
                        renameError = nil
                    }
                }
                .disabled(editingLabel.trimmingCharacters(in: .whitespacesAndNewlines) == account.label || editingLabel.isEmpty)
            }
            if let err = renameError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func accountRouteConfigSection(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources for \(account.provider.displayName)")
                .font(.headline)

            let binding = configBinding(for: account.provider)

            routeToggleRow(for: account, route: .injection, label: liveRouteLabel(account.provider), binding: binding)

            if account.provider.supportsWebFallback {
                routeToggleRow(for: account, route: .keychain, label: "Web fallback when local data is stale", binding: binding)
                Text("Uses the CLI's saved login, read-only, only while QuotaPeek is on screen and the agent hasn't reported for 15 minutes (at most every 10 minutes).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }

            Toggle("Notify near limit", isOn: Binding(
                get: { binding.wrappedValue.notifyThresholdPercent != nil },
                set: { isOn in
                    if isOn {
                        binding.wrappedValue.notifyThresholdPercent = binding.wrappedValue.notifyThresholdPercent ?? 90
                        Task { await NotificationManager.shared.requestAuthorization() }
                    } else {
                        binding.wrappedValue.notifyThresholdPercent = nil
                    }
                }
            ))
            .font(.caption)

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
                .font(.caption)
                .padding(.leading, 16)
            }

            if account.provider == .antigravity {
                Divider()
                Toggle("Show Claude/GPT quota", isOn: $displayPrefs.showAntigravityModelBreakdown)
                    .font(.caption)
                Text("Shows Antigravity's separate Claude/GPT quota as its own entry in the popover and widgets.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
    }

    private func liveRouteLabel(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "Live from Claude Code's statusline"
        case .codex: return "Live from Codex session logs"
        case .antigravity: return "Live from agy's statusline"
        }
    }

    private func routeToggleRow(
        for account: Account,
        route: Route,
        label: String,
        binding: Binding<ProviderConfig>
    ) -> some View {
        let key = RouteKey(accountId: account.id, route: route)
        let testState = testStatuses[key]

        let isOnBinding = Binding(
            get: { binding.wrappedValue.routesEnabled.contains(route) },
            set: { isOn in
                var routes = binding.wrappedValue.routesEnabled
                routes.setRouteEnabled(route, enabled: isOn)
                binding.wrappedValue.routesEnabled = routes
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

            if let result = testState?.result, !result.message.isEmpty {
                Text(result.message)
                    .font(.caption2)
                    .foregroundStyle(result.ok ? Color.secondary : Color.red)
                    .padding(.leading, 18)
            }
        }
    }

    private func testRoute(account: Account, route: Route) {
        let key = RouteKey(accountId: account.id, route: route)
        testStatuses[key] = RouteTestState(isLoading: true, result: nil)
        Task {
            let result = await store.checkRoute(accountId: account.id, route: route)
            testStatuses[key] = RouteTestState(isLoading: false, result: result)

            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if testStatuses[key]?.isLoading == false {
                testStatuses[key] = nil
            }
        }
    }

    private func accountActionsSection(_ account: Account) -> some View {
        HStack {
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

    /// Reads and writes one provider's settings straight through the store,
    /// which saves config.json immediately.
    private func configBinding(for provider: Provider) -> Binding<ProviderConfig> {
        Binding(
            get: { store.config.config(for: provider) },
            set: { newValue in
                var next = store.config
                next.setConfig(newValue, for: provider)
                store.saveConfig(next)
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
    var onCreated: (AccountConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: Provider = .claude
    @State private var label: String = ""
    @State private var configDir: String = "~/.claude"
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
                errorMessage = nil
                switch prov {
                case .claude: configDir = "~/.claude"
                case .codex: configDir = "~/.codex"
                case .antigravity: break
                }
            }

            TextField("Account Label (e.g. Work, Personal)", text: $label)
                .textFieldStyle(.roundedBorder)

            if selectedProvider.supportsWebFallback {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configuration Directory")
                        .font(.caption).bold()
                    TextField("Config Dir (e.g. ~/.claude-work)", text: $configDir)
                        .textFieldStyle(.roundedBorder)
                    Text("The folder this login lives in (\(selectedProvider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME")). Readings from that folder are shown under this account.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Antigravity reports through the QuotaPeek statusline hook for agy; nothing else to set up.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if selectedProvider.supportsWebFallback {
            return configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private func createAccount() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = selectedProvider.supportsWebFallback ? configDir.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        switch store.createAccount(provider: selectedProvider, label: trimmedLabel, configDir: dir) {
        case .success(let account):
            onCreated(account)
            dismiss()
        case .failure(let error):
            errorMessage = error.description
        }
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs: DisplayPreferences
    @State private var saveError: String?
    @State private var isLaunchAgentInstalled: Bool = false
    @State private var isLaunchAtLoginEnabled: Bool = false
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { isLaunchAtLoginEnabled },
                    set: { enable in
                        let prev = isLaunchAtLoginEnabled
                        LaunchAgentManager.setEnabledAsync(enable) { success in
                            if success {
                                isLaunchAtLoginEnabled = enable
                            } else {
                                // Revert on failure (Task D9)
                                isLaunchAtLoginEnabled = prev
                                launchAtLoginError = "Failed to update launch at login setting via launchctl."
                            }
                        }
                    }
                ))
                .disabled(!isLaunchAgentInstalled)
                .help(isLaunchAgentInstalled ? "Start QuotaPeek automatically when logging in" : "App was not installed via install.sh")
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
                    set: { paused in update { $0.collectionPaused = paused } }
                ))
                .accessibilityLabel("Pause data collection")

                Text("Stops listening to the agents and makes no web requests until resumed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Mark data stale after: \(formatDuration(store.config.staleAfterSeconds))",
                    value: Binding(
                        get: { store.config.staleAfterSeconds },
                        set: { value in update { $0.staleAfterSeconds = max(60, value) } }
                    ),
                    in: 60...3600,
                    step: 60
                )
                .accessibilityLabel("Freshness policy threshold")

                Text("Readings older than this are shown as \"stale\". Minimum 60 seconds.")
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

                Toggle("Show Codex/Antigravity data in Claude Code's statusline", isOn: Binding(
                    get: { store.config.statuslineShowOtherAgents },
                    set: { show in update { $0.statuslineShowOtherAgents = show } }
                ))

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

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            isLaunchAgentInstalled = LaunchAgentManager.isPlistInstalled
            LaunchAgentManager.isLoadedAsync { isLoaded in
                isLaunchAtLoginEnabled = isLoaded
            }
        }
    }

    /// Applies one change to the configuration and saves it right away.
    private func update(_ change: (inout AppConfig) -> Void) {
        var next = store.config
        change(&next)
        saveError = store.saveConfig(next) ? nil : "Could not save settings; see Advanced → Recent errors."
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

}

// MARK: - Widget Tab

private struct WidgetSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs: DisplayPreferences

    var body: some View {
        Form {
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

            NativeWidgetSection(store: store, displayPrefs: displayPrefs)
        }
        .formStyle(.grouped)
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

            Picker("Layer", selection: configuration.layer) {
                ForEach(WidgetLayerLevel.allCases) { layer in
                    Text(layer.displayName).tag(layer)
                }
            }
            .pickerStyle(.menu)
            .help("Where this widget sits relative to other windows. Each widget can have its own layer.")

            WidgetScopeEditor(store: store, displayPrefs: displayPrefs, configuration: configuration)
        }
        .padding(.vertical, 4)
    }
}

/// macOS (WidgetKit) widget settings: which accounts and metrics it shows.
/// The style is chosen per widget in the macOS widget gallery.
private struct NativeWidgetSection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs: DisplayPreferences

    var body: some View {
        Section {
            WidgetScopeEditor(store: store, displayPrefs: displayPrefs, configuration: $displayPrefs.nativeWidget)
        } header: {
            Text("macOS Widget")
        } footer: {
            Text("Add it from the desktop or Notification Center: right-click the desktop → Edit Widgets… → QuotaPeek. Each style is its own widget. Clicking a widget opens QuotaPeek and refreshes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// "Included accounts" list with per-account metric choices, shared by the
/// floating desktop panels and the macOS widget.
private struct WidgetScopeEditor: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var displayPrefs: DisplayPreferences
    @Binding var configuration: WidgetConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Included accounts")
                .font(.subheadline)
            let enabledAccounts = store.accounts.filter { store.isAccountEnabled($0) }
            // Includes each Antigravity account's synthetic Claude/GPT sub-entry id
            // (when the breakdown is on) so materializing scope.includedAccountIds
            // from "all" (nil) to an explicit set - triggered by toggling any single
            // row below - doesn't silently drop entries it doesn't know about yet.
            let allScopeIds: Set<String> = Set(enabledAccounts.map(\.id)).union(
                displayPrefs.showAntigravityModelBreakdown
                    ? Set(enabledAccounts.filter { $0.provider == .antigravity }.map { "\($0.id):claude_gpt" })
                    : []
            )
            ForEach(enabledAccounts) { account in
                WidgetAccountScopeRow(
                    title: "\(account.provider.displayName) — \(account.label)",
                    entryId: account.id,
                    configuration: $configuration,
                    allScopeIds: allScopeIds
                ) {
                    if account.provider == .antigravity && displayPrefs.showAntigravityModelBreakdown {
                        WidgetAccountScopeRow(
                            title: "Claude/GPT",
                            entryId: "\(account.id):claude_gpt",
                            configuration: $configuration,
                            allScopeIds: allScopeIds
                        ) { EmptyView() }
                    }
                }
            }
            Text(enabledAccounts.isEmpty
                 ? "Enable accounts in the Accounts tab to select them here."
                 : "All checked includes all enabled accounts, including accounts added later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One account (or Antigravity Claude/GPT sub-entry) in a widget's scope list.
/// The include switch sits on the header row so it's usable without expanding;
/// the chevron reveals per-metric checkboxes at a fixed indent, so metric lists
/// from every expanded row line up in the same column.
private struct WidgetAccountScopeRow<Nested: View>: View {
    let title: String
    let entryId: String
    @Binding var configuration: WidgetConfiguration
    let allScopeIds: Set<String>
    let nested: () -> Nested

    @State private var isExpanded = false

    init(
        title: String,
        entryId: String,
        configuration: Binding<WidgetConfiguration>,
        allScopeIds: Set<String>,
        @ViewBuilder nested: @escaping () -> Nested
    ) {
        self.title = title
        self.entryId = entryId
        self._configuration = configuration
        self.allScopeIds = allScopeIds
        self.nested = nested
    }

    private static var chevronWidth: CGFloat { 14 }
    private static var contentIndent: CGFloat { chevronWidth + 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: Self.chevronWidth)
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(title) metrics")

                Toggle("Include \(title)", isOn: Binding(
                    get: { configuration.scope.includes(entryId) },
                    set: { isIncluded in
                        configuration.scope.setIncluded(
                            entryId,
                            isIncluded: isIncluded,
                            enabledAccountIds: allScopeIds
                        )
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(WidgetMetricKind.offerable) { metric in
                        Toggle(metric.displayName, isOn: Binding(
                            get: { configuration.visibleMetrics(forAccountId: entryId).contains(metric) },
                            set: { isVisible in
                                var metrics = configuration.visibleMetrics(forAccountId: entryId)
                                if isVisible {
                                    metrics.insert(metric)
                                } else {
                                    metrics.remove(metric)
                                }
                                configuration.accountMetrics[entryId] = metrics
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    nested()
                }
                .padding(.leading, Self.contentIndent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Health Tab (Per-Account Health)

private struct ProviderHealthTab: View {
    @ObservedObject var store: UsageStore

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
    }

    private func sourceName(_ account: Account) -> String {
        switch account.activeRoute {
        case .keychain: return "Web (CLI login)"
        case .injection: return account.provider == .codex ? "Codex session log" : "Statusline hook"
        case .none: return "No reading yet"
        }
    }

    private func accountHealthCard(for account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(account.provider.displayName) - \(account.label)", systemImage: account.provider.symbolName)
                    .font(.headline)

                Spacer()

                CapsuleBadge(text: account.state.displayName, color: account.state.color)
            }

            Divider()

            VStack(spacing: 6) {
                healthRow(title: "Source", value: sourceName(account), icon: "antenna.radiowaves.left.and.right")

                if let loc = account.credentialLocation?.configDir {
                    healthRow(title: "Config Directory", value: loc, icon: "folder.fill")
                }

                healthRow(
                    title: "Last Reading",
                    value: account.asOf.map(RelativeDateFormatting.format) ?? "None yet",
                    icon: "checkmark.circle",
                    tint: account.asOf != nil ? .green : .secondary
                )

                if let error = account.displayLastError {
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Advanced Tab

private struct AdvancedSettingsTab: View {
    @ObservedObject var store: UsageStore

    // Uninstall state (Task D11)
    @State private var showUninstallConfirmation = false
    @State private var uninstallResultAlert: String?
    @State private var isUninstallSuccessful = false

    private var appSupportPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaPeek", isDirectory: true)
            .path
    }

    private var logFilePath: String {
        ErrorLog.fileURL.path
    }

    var body: some View {
        Form {
            // Task D11: Uninstall button with confirmation dialog
            Section("Maintenance & Uninstall") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstall QuotaPeek")
                            .font(.body)
                        Text("Removes the launch agent, the statusline hooks and the installed files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uninstall", role: .destructive) {
                        showUninstallConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("Diagnostics & Files") {
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

            Section {
                HStack {
                    Text("Recent errors").font(.headline)
                    Spacer()
                    Button("Refresh") { store.loadErrors() }
                        .accessibilityLabel("Refresh error log")
                }

                if store.errorLines.isEmpty {
                    Text("No errors recorded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(Array(store.errorLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Uninstall QuotaPeek?", isPresented: $showUninstallConfirmation) {
            Button("Uninstall", role: .destructive) {
                runUninstallScript()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This runs the uninstaller: it removes the launch agent, the statusline hooks and the installed files.")
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

    /// Task D11: Executes fixed contract uninstaller at ~/Library/Application Support/QuotaPeek/bin/uninstall.sh
    private func runUninstallScript() {
        let scriptPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaPeek/bin/uninstall.sh")
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

        // The uninstall script's last step unloads com.quotapeek.app's own
        // LaunchAgent, which kills this app's running process as an expected
        // side effect. Blocking the main thread on waitUntilExit() would race
        // that self-termination and could hang/silently kill the UI before
        // the result alert ever shows. Run the process and wait for it off
        // the main thread instead, using a termination handler to hop back.
        process.terminationHandler = { finishedProcess in
            let status = finishedProcess.terminationStatus
            DispatchQueue.main.async {
                if status == 0 {
                    isUninstallSuccessful = true
                    uninstallResultAlert = "QuotaPeek uninstalled successfully. The application will now close."
                } else {
                    isUninstallSuccessful = false
                    uninstallResultAlert = "Uninstall failed with exit code \(status)."
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    isUninstallSuccessful = false
                    uninstallResultAlert = "Failed to run uninstall script: \(error.localizedDescription)"
                }
            }
        }
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
