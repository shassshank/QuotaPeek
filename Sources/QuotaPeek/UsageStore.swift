import Foundation
import Combine

/// Holds the latest state fetched from the Go daemon. This replaces the old file-watching cache
/// reader entirely - the daemon is the single source of truth and the only thing this app talks to.
@MainActor
final class UsageStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var history: [String: [HistoryPoint]] = [:] // Keyed by accountId
    @Published var isDaemonReachable = true
    @Published var isRefreshing = false
    @Published var isCollectionPaused = false
    @Published var errors: [ErrorLogEntry] = []
    @Published var config: DaemonConfig?

    /// The specific error from the most recent failed daemon call, preserved
    /// alongside `isDaemonReachable` so callers can distinguish "daemon not
    /// running" (`.unreachable`) from "daemon is running but returned a
    /// malformed/incompatible response" (`.badResponse`/`.decodeFailed`) -
    /// those call for different user guidance even though both currently
    /// collapse into the same `isDaemonReachable == false` UI state.
    /// `nil` once a call succeeds again.
    @Published var lastDaemonError: DaemonError?

    /// True when the daemon is reachable and responding, but with a response
    /// this client couldn't parse or a non-2xx status - i.e. a real HTTP
    /// round-trip happened, unlike `.unreachable` (connection-level failure).
    var isDaemonIncompatible: Bool {
        switch lastDaemonError {
        case .badResponse, .decodeFailed:
            return true
        case .unreachable, .none:
            return false
        }
    }

    /// Backward compatibility helper for legacy code accessing providers dictionary
    var providers: [Provider: Account] {
        var map: [Provider: Account] = [:]
        for account in accounts {
            if map[account.provider] == nil {
                map[account.provider] = account
            }
        }
        return map
    }

    private let client = DaemonClient()
    private var timer: Timer?

    // Polling cadence tiers:
    // - fast: popover is actively open and user is looking at live numbers (5s)
    // - desktop widget: passive always-on-screen widget, popover closed (30s)
    // - slow: nothing visible, background keep-alive only (60s)
    private let fastPollInterval: TimeInterval = 5
    private let desktopWidgetPollInterval: TimeInterval = 30
    private let slowPollInterval: TimeInterval = 60
    private var isPopoverVisible = false
    private var isWidgetVisible = false

    // In-flight guard per Task C7. Shared between `reload()` (timer-driven) and
    // `refresh()` (manual "Refresh Now") so the two triggers can't fire concurrent
    // daemon requests - whichever gets there second is skipped for that tick.
    private var isFetchInFlight = false

    // Save serialization per Task D10
    private var activeSaveTask: Task<Bool, Never>?
    private var pendingConfigToSave: DaemonConfig?

    func start() {
        Task {
            await loadConfig()
            await reload()
        }
        scheduleTimer(interval: slowPollInterval)
    }

    /// Dynamically switches polling cadence when the popover opens/closes.
    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        applyPollingCadence(triggerImmediateReload: visible)
    }

    /// Tracks whether any desktop widget panel is on-screen. Uses the intermediate
    /// `desktopWidgetPollInterval` cadence when the popover itself is closed.
    func setWidgetVisible(_ visible: Bool) {
        guard isWidgetVisible != visible else { return }
        isWidgetVisible = visible
        applyPollingCadence(triggerImmediateReload: visible)
    }

    private func applyPollingCadence(triggerImmediateReload: Bool) {
        let interval: TimeInterval
        if isPopoverVisible {
            interval = fastPollInterval
        } else if isWidgetVisible {
            interval = desktopWidgetPollInterval
        } else {
            interval = slowPollInterval
        }
        scheduleTimer(interval: interval)
        if triggerImmediateReload {
            Task { await reload() }
        }
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.reload()
            }
        }
    }

    func reload() async {
        // In-flight guard: prevent overlapping reload calls from stacking up, and
        // coalesce against a concurrent manual refresh() (Task C7 + latent race fix).
        guard !isFetchInFlight else { return }
        isFetchInFlight = true
        defer { isFetchInFlight = false }

        switch await client.status() {
        case .success(let response):
            lastDaemonError = nil
            if !isDaemonReachable {
                isDaemonReachable = true
            }
            if accounts != response.accounts {
                accounts = response.accounts
            }
            NotificationManager.shared.evaluate(accounts: accounts, config: config)
        case .failure(let error):
            lastDaemonError = error
            if isDaemonReachable {
                isDaemonReachable = false
            }
        }
    }

    func refresh(accountId: String? = nil) async {
        // Shares the same in-flight guard as reload() so a manual "Refresh Now"
        // and a timer-driven reload() can never both be in flight at once.
        guard !isFetchInFlight else { return }
        isFetchInFlight = true
        isRefreshing = true
        defer {
            isFetchInFlight = false
            isRefreshing = false
        }

        switch await client.refresh(accountId: accountId) {
        case .success(let response):
            lastDaemonError = nil
            if !isDaemonReachable {
                isDaemonReachable = true
            }
            if accounts != response.accounts {
                accounts = response.accounts
            }
            NotificationManager.shared.evaluate(accounts: accounts, config: config)
            await loadAllHistory()
        case .failure(let error):
            lastDaemonError = error
            if isDaemonReachable {
                isDaemonReachable = false
            }
        }
    }

    // MARK: - Account Management (P5)

    func createAccount(_ request: CreateAccountRequest) async -> Result<Account, DaemonError> {
        let result = await client.createAccount(request)
        if case .success = result {
            await reload()
        }
        return result
    }

    func updateAccount(id: String, label: String) async -> Result<Account, DaemonError> {
        let result = await client.updateAccount(id: id, label: label)
        if case .success = result {
            await reload()
        }
        return result
    }

    func deleteAccount(id: String) async -> Result<SimpleSuccessResponse, DaemonError> {
        let result = await client.deleteAccount(id: id)
        if case .success = result {
            history.removeValue(forKey: id)
            await reload()
        }
        return result
    }

    func resetCredentials(accountId: String) async -> Result<ResetCredentialsResponse, DaemonError> {
        let result = await client.resetCredentials(accountId: accountId)
        await reload()
        return result
    }

    func testRoute(accountId: String, provider: Provider, route: Route) async -> Result<TestRouteResponse, DaemonError> {
        await client.testRoute(accountId: accountId, provider: provider, route: route)
    }

    // MARK: - Config & Autosave (Serialized)

    func loadConfig() async {
        if case .success(let cfg) = await client.config() {
            config = cfg
            if let paused = cfg.collectionPaused {
                isCollectionPaused = paused
            }
            NotificationManager.shared.evaluate(accounts: accounts, config: cfg)
        }
    }

    /// Serializes saves to avoid in-flight clobbering (Task D10).
    ///
    /// Iterative rather than recursive: if newer edits arrive while a save is in
    /// flight, the newest pending config just replaces `pendingConfigToSave` and
    /// the loop below picks it up on its next iteration, instead of this function
    /// calling itself again. This keeps the "latest wins, coalesce intermediate
    /// edits" behavior without any risk of deep call-stack growth from rapid
    /// successive edits.
    func saveConfig(_ newConfig: DaemonConfig) async -> Bool {
        pendingConfigToSave = newConfig
        if let active = activeSaveTask {
            _ = await active.value
        }

        var outcome = true
        while let configToSave = pendingConfigToSave {
            pendingConfigToSave = nil

            let task = Task<Bool, Never> { @MainActor in
                let result = await self.client.updateConfig(configToSave)
                switch result {
                case .success(let cfg):
                    self.lastDaemonError = nil
                    self.config = cfg
                    if let paused = cfg.collectionPaused {
                        self.isCollectionPaused = paused
                    }
                    NotificationManager.shared.evaluate(accounts: self.accounts, config: cfg)
                    await self.reload()
                    return true
                case .failure(let error):
                    self.lastDaemonError = error
                    return false
                }
            }
            activeSaveTask = task
            outcome = await task.value
            activeSaveTask = nil

            // Loop again if another change came in while this save was in flight -
            // `pendingConfigToSave` will be non-nil and we save the newest draft.
        }
        return outcome
    }

    /// Non-optimistic pause toggle: reverts on failure per Task D9
    func setCollectionPaused(_ paused: Bool) async -> Result<Bool, DaemonError> {
        let result: Result<DaemonConfig, DaemonError>
        if paused {
            result = await client.pauseCollection()
        } else {
            result = await client.resumeCollection()
        }

        switch result {
        case .success(let cfg):
            config = cfg
            let serverPaused = cfg.collectionPaused ?? paused
            isCollectionPaused = serverPaused
            NotificationManager.shared.evaluate(accounts: accounts, config: cfg)
            await reload()
            return .success(serverPaused)
        case .failure(let error):
            // Revert state - do not show optimistic success
            return .failure(error)
        }
    }

    func loadErrors() async {
        if case .success(let response) = await client.errors() {
            errors = response.errors
        }
    }

    // MARK: - History

    func loadHistory(for account: Account, route: Route? = nil) async {
        let targetRoute: Route
        if let route, route != .none {
            targetRoute = route
        } else if account.activeRoute != .none {
            targetRoute = account.activeRoute
        } else if let firstEnabled = account.routesEnabled.first {
            targetRoute = firstEnabled
        } else {
            return
        }
        let result = await client.history(accountId: account.id, route: targetRoute)
        if case .success(let resp) = result {
            history[account.id] = resp.points
        }
    }

    func loadAllHistory() async {
        for account in accounts where isAccountEnabled(account) {
            await loadHistory(for: account)
        }
    }

    // MARK: - Trust-State & Status Queries

    func isAccountEnabled(_ account: Account) -> Bool {
        !account.routesEnabled.isEmpty
    }

    func isProviderEnabled(_ provider: Provider) -> Bool {
        let providerAccounts = accounts.filter { $0.provider == provider }
        if !providerAccounts.isEmpty {
            return providerAccounts.contains { isAccountEnabled($0) }
        }
        if let config = config?.config(for: provider) {
            return !config.routesEnabled.isEmpty
        }
        return true
    }

    /// Single source of truth: branches on server-computed `state` field per P5
    func isAccountStale(_ account: Account) -> Bool {
        account.state == .stale || account.state == .restored
    }

    /// Highest usage percent across enabled accounts.
    /// Returns nil if no enabled accounts have valid numeric data (stops substituting 0.0!).
    var highestUsagePercent: Double? {
        var highest: Double?
        for account in accounts where isAccountEnabled(account) {
            // Under P5: when state == .unknown or .error, never display data as a number
            guard account.state != .unknown && account.state != .error else { continue }
            guard let data = account.data else { continue }
            let values = [data.usedPercent5h, data.usedPercentWeekly].compactMap { $0 }
            if let maxVal = values.max() {
                highest = max(highest ?? 0, maxVal)
            }
        }
        return highest
    }

    /// Returns true if daemon is unreachable, or any enabled account is in an error, stale, or restored state.
    var isStaleOrFailing: Bool {
        guard isDaemonReachable else { return true }
        let enabledAccounts = accounts.filter { isAccountEnabled($0) }
        guard !enabledAccounts.isEmpty else { return false }
        for account in enabledAccounts {
            if account.state == .error || account.state == .stale || account.state == .restored {
                return true
            }
        }
        return false
    }
}

