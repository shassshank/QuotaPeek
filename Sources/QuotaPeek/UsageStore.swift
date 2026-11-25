import Foundation
import Combine

/// Holds the latest state fetched from the Go daemon. This replaces the old file-watching cache
/// reader entirely - the daemon is the single source of truth and the only thing this app talks to.
@MainActor
final class UsageStore: ObservableObject {
    @Published var accounts: [Account] = []
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

    // MARK: - Local sources (daemon-free path)
    //
    // Readings pushed by the statusline hooks (Unix datagrams) and read from
    // Codex session logs are overlaid on the daemon's accounts: for each
    // account the newer of the two wins. While both paths run side by side,
    // disagreements are written to errors.log as "compare" notices.
    let quotaStore = QuotaStore()
    private var daemonAccounts: [Account] = []
    private var datagramListener: DatagramListener?
    private var codexReaders: [String: CodexLogReader] = [:]
    private let snapshotWriter = SnapshotWriter()
    private var lastTimestampOnlyRecompute: [String: Date] = [:]
    private var lastComparison: [String: String] = [:]
    /// A timestamp-only reading (same numbers, newer time) refreshes the UI at
    /// most this often per source, so a hook firing every few seconds does
    /// not re-render anything.
    private let timestampOnlyRefreshInterval: TimeInterval = 60

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
        startLocalSources()
        Task {
            await loadConfig()
            await reload()
        }
        scheduleTimer(interval: slowPollInterval)
    }

    private func startLocalSources() {
        guard datagramListener == nil else { return }
        let listener = DatagramListener(path: AppPaths.socketPath) { [weak self] bytes in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            guard let reading = LocalQuotaParser.datagram(bytes, nowMs: nowMs) else {
                ErrorLog.warning("hook datagram ignored: unparseable (\(bytes.count) bytes)")
                return
            }
            Task { @MainActor in self?.applyLocalReading(reading) }
        }
        do {
            try listener.start()
            datagramListener = listener
        } catch {
            ErrorLog.error("hook socket unavailable: \(error)")
        }
        ensureCodexReaders()
    }

    /// Stops local sources and removes the hooks' snapshot so they stop
    /// showing numbers from a QuotaPeek that is no longer running.
    func stopLocalSources() {
        datagramListener?.stop()
        datagramListener = nil
        codexReaders.values.forEach { $0.stop() }
        codexReaders.removeAll()
        snapshotWriter.remove()
    }

    /// One log reader per Codex home: the CLI default plus any configured account's.
    private func ensureCodexReaders() {
        var dirs: Set<String> = [LocalQuotaParser.canonicalConfigDir(nil, provider: .codex)]
        for account in daemonAccounts where account.provider == .codex {
            if let dir = account.credentialLocation?.configDir {
                dirs.insert(LocalQuotaParser.canonicalConfigDir(dir, provider: .codex))
            }
        }
        for dir in dirs where codexReaders[dir] == nil {
            let reader = CodexLogReader(configDir: dir) { [weak self] reading in
                Task { @MainActor in self?.applyLocalReading(reading) }
            }
            codexReaders[dir] = reader
            reader.start()
        }
    }

    func applyLocalReading(_ reading: LocalReading) {
        let previous = quotaStore.readings[reading.key]
        switch quotaStore.apply(reading) {
        case .ignored:
            return
        case .timestampOnly:
            // Same numbers, newer time: only the "updated" time would move,
            // so throttle - unless the previous reading had gone stale, in
            // which case the account must flip back to fresh right away.
            let staleAfterMs = Int64(config?.staleAfterSeconds ?? 600) * 1000
            let previousWasFresh = previous.map { reading.observedAtMs - $0.observedAtMs <= staleAfterMs } ?? false
            if previousWasFresh, let last = lastTimestampOnlyRecompute[reading.key],
               Date().timeIntervalSince(last) < timestampOnlyRefreshInterval {
                return
            }
        case .changed:
            break
        }
        lastTimestampOnlyRecompute[reading.key] = Date()
        recomputeAccounts()
    }

    /// Rebuilds `accounts` from the daemon's view plus local readings and
    /// republishes only if something visible changed.
    private func recomputeAccounts() {
        let nowSec = Int64(Date().timeIntervalSince1970)
        let staleAfter = Int64(config?.staleAfterSeconds ?? 600)
        let antigravityCount = daemonAccounts.filter { $0.provider == .antigravity }.count
        let merged = daemonAccounts.map { account -> Account in
            guard let reading = localReading(for: account, antigravityCount: antigravityCount) else { return account }
            compare(account, with: reading)
            return Self.overlay(account, with: reading, nowSec: nowSec, staleAfter: staleAfter)
        }
        if accounts != merged {
            accounts = merged
            NotificationManager.shared.evaluate(accounts: accounts, config: config)
        }
        snapshotWriter.update(accounts: accounts, showOtherAgents: config?.statuslineShowOtherAgents ?? true)
    }

    private func localReading(for account: Account, antigravityCount: Int) -> LocalReading? {
        switch account.provider {
        case .antigravity:
            // The agy hook cannot say which login is active, so only a single
            // Antigravity account can be matched (same rule as the daemon).
            return antigravityCount == 1 ? quotaStore.reading(provider: .antigravity, configDir: "") : nil
        case .claude, .codex:
            let dir = LocalQuotaParser.canonicalConfigDir(account.credentialLocation?.configDir, provider: account.provider)
            return quotaStore.reading(provider: account.provider, configDir: dir)
        }
    }

    /// The newer of the daemon's sample and the local reading wins. The
    /// daemon's `asOf` has one-second resolution, so a local reading within
    /// that same second is treated as newer: it comes straight from the agent.
    static func overlay(_ account: Account, with reading: LocalReading, nowSec: Int64, staleAfter: Int64) -> Account {
        let readingSec = reading.observedAtMs / 1000
        guard reading.observedAtMs >= (account.asOf ?? 0) * 1000 else { return account }
        var out = account
        out.data = reading.data
        out.asOf = readingSec
        out.activeRoute = reading.source == .web ? .keychain : .injection
        out.restoredFromDisk = false
        out.state = nowSec - readingSec > staleAfter ? .stale : .fresh
        return out
    }

    /// Side-by-side validation: note when the daemon and the local path
    /// disagree by 2+ points on samples taken within 15 minutes of each other.
    private func compare(_ account: Account, with reading: LocalReading) {
        guard let daemonData = account.data, let asOf = account.asOf,
              abs(reading.observedAtMs / 1000 - asOf) <= 15 * 60 else { return }
        func differs(_ a: Double?, _ b: Double?) -> Bool {
            guard let a, let b else { return false }
            return abs(a - b) >= 2
        }
        let d = reading.data
        guard differs(daemonData.usedPercent5h, d.usedPercent5h) || differs(daemonData.usedPercentWeekly, d.usedPercentWeekly) else {
            lastComparison[account.id] = nil
            return
        }
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        let signature = "daemon 5h \(fmt(daemonData.usedPercent5h)) wk \(fmt(daemonData.usedPercentWeekly)) vs \(reading.source.rawValue) 5h \(fmt(d.usedPercent5h)) wk \(fmt(d.usedPercentWeekly))"
        guard lastComparison[account.id] != signature else { return }
        lastComparison[account.id] = signature
        ErrorLog.notice("compare \(account.provider.rawValue)/\(account.label): \(signature)")
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
            applyFetchResult(await client.status())
        case .refresh(let accountId):
            isRefreshing = true
            applyFetchResult(await client.refresh(accountId: accountId))
            isRefreshing = false
        }
    }

    @discardableResult
    private func applyFetchResult(_ result: Result<StatusResponse, DaemonError>) -> Bool {
        switch result {
        case .success(let response):
            lastDaemonError = nil
            if !isDaemonReachable {
                isDaemonReachable = true
            }
            daemonAccounts = response.accounts
            ensureCodexReaders()
            recomputeAccounts()
            return true
        case .failure(let error):
            lastDaemonError = error
            if isDaemonReachable {
                isDaemonReachable = false
            }
            return false
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
            applyConfig(cfg)
        }
    }

    private func applyConfig(_ cfg: DaemonConfig) {
        config = cfg
        if let paused = cfg.collectionPaused {
            isCollectionPaused = paused
        }
        NotificationManager.shared.evaluate(accounts: accounts, config: cfg)
        snapshotWriter.update(accounts: accounts, showOtherAgents: cfg.statuslineShowOtherAgents ?? true)
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
                applyConfig(cfg)
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

    // MARK: - Trust-State & Status Queries

    func isAccountEnabled(_ account: Account) -> Bool {
        !account.routesEnabled.isEmpty
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

