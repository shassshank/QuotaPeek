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

    // MARK: - Fetch coalescing (reload/refresh)
    //
    // `reload()` (timer-driven) and `refresh()` (manual "Refresh Now", and the
    // post-mutation reloads after account create/update/delete/reset-credentials)
    // must never both have a daemon request in flight at once, but a caller's
    // request must also never be silently dropped. This is a "coalesce trailing"
    // single-flight queue: at most one fetch runs at a time; any calls that arrive
    // while one is running just replace `pendingFetchKind` (latest request wins)
    // and get their own continuation queued in `fetchWaiters`. The single driver
    // loop (spawned by whichever call finds `isFetchInFlight == false`) keeps
    // picking up the newest pending kind and running it until none remain, and
    // resumes exactly the waiters that were queued for the round that just ran -
    // so every caller's `await` returns only once a fetch matching (or superseding
    // via latest-wins) its own request has actually completed.
    //
    // All of this state is only ever touched on the MainActor, and there is no
    // `await` between reading and mutating it within a single synchronous
    // stretch of code, so no additional locking is required.
    private enum FetchKind {
        case reload
        case refresh(accountId: String?)
    }
    private var isFetchInFlight = false
    private var pendingFetchKind: FetchKind?
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Config save coalescing
    //
    // Same "coalesce trailing" shape as the fetch queue above: at most one
    // `PUT /config` in flight at a time. A `saveConfig` call that arrives while
    // one is in flight replaces `pendingConfigToSave` (latest wins) and queues a
    // continuation; the single driver loop resumes each round's waiters with the
    // outcome of the save that actually ran for that round, so a caller only ever
    // sees "true" if its own config (or a newer one that superseded it) was
    // genuinely the last thing persisted - never a false success for a write that
    // never landed.
    private var isSaveInFlight = false
    private var pendingConfigToSave: DaemonConfig?
    private var saveWaiters: [CheckedContinuation<Bool, Never>] = []

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
        await requestFetch(.reload)
    }

    func refresh(accountId: String? = nil) async {
        await requestFetch(.refresh(accountId: accountId))
    }

    /// Entry point for both `reload()` and `refresh()`. Queues `kind` as the
    /// newest pending request and, if no driver loop is currently running,
    /// starts one. Always awaits a continuation that is resumed once a fetch
    /// covering this call's request has actually completed - so a caller is
    /// never told "done" without a matching daemon round-trip having happened.
    private func requestFetch(_ kind: FetchKind) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingFetchKind = kind
            fetchWaiters.append(continuation)
            if !isFetchInFlight {
                isFetchInFlight = true
                Task { await self.runFetchLoop() }
            }
        }
    }

    /// The single driver loop. Only one of these ever runs at a time (gated by
    /// `isFetchInFlight`): it repeatedly takes whatever is the newest pending
    /// fetch kind, runs it, and resumes exactly the waiters that were queued as
    /// of the start of that round - so a request that arrives mid-fetch is
    /// coalesced into the *next* round rather than dropped, and its caller's
    /// `await` only resolves once that next round is done.
    private func runFetchLoop() async {
        while let currentKind = pendingFetchKind {
            pendingFetchKind = nil
            let waiters = fetchWaiters
            fetchWaiters = []

            await performFetch(currentKind)

            for waiter in waiters {
                waiter.resume()
            }
        }
        isFetchInFlight = false
    }

    private func performFetch(_ kind: FetchKind) async {
        switch kind {
        case .reload:
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
        case .refresh(let accountId):
            isRefreshing = true
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
            isRefreshing = false
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

    /// Single-flight + "coalesce trailing" save: at most one `PUT /config` is
    /// ever in flight. A call that arrives while one is already running just
    /// replaces `pendingConfigToSave` with its (newer) payload and queues a
    /// continuation in `saveWaiters`; the single driver loop below picks up the
    /// newest pending config on its next iteration and resumes exactly the
    /// waiters queued for that round with that round's real outcome.
    ///
    /// This means a caller's `await saveConfig(...)` only ever returns `true`
    /// if its own config, or a newer one that superseded it before its round
    /// started, was actually the thing that got persisted - never a false
    /// "success" for a write that was silently dropped, and never two
    /// overlapping PUT requests in flight at once. All state here
    /// (`isSaveInFlight`, `pendingConfigToSave`, `saveWaiters`) is only ever
    /// touched synchronously on the MainActor between suspension points, so no
    /// extra locking is needed.
    func saveConfig(_ newConfig: DaemonConfig) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingConfigToSave = newConfig
            saveWaiters.append(continuation)
            if !isSaveInFlight {
                isSaveInFlight = true
                Task { await self.runSaveLoop() }
            }
        }
    }

    /// The single driver loop for `saveConfig`. Only one instance ever runs at
    /// a time (gated by `isSaveInFlight`).
    private func runSaveLoop() async {
        while let configToSave = pendingConfigToSave {
            pendingConfigToSave = nil
            let waiters = saveWaiters
            saveWaiters = []

            let success: Bool
            switch await client.updateConfig(configToSave) {
            case .success(let cfg):
                lastDaemonError = nil
                config = cfg
                if let paused = cfg.collectionPaused {
                    isCollectionPaused = paused
                }
                NotificationManager.shared.evaluate(accounts: accounts, config: cfg)
                await reload()
                success = true
            case .failure(let error):
                lastDaemonError = error
                success = false
            }

            for waiter in waiters {
                waiter.resume(returning: success)
            }

            // Loop again if another change came in while this save was in flight -
            // `pendingConfigToSave` will be non-nil and we save the newest draft.
        }
        isSaveInFlight = false
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

