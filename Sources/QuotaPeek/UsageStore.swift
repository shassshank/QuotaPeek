import QuotaPeekCore
import AppKit
import Combine
import Foundation

/// Owns the accounts and their latest numbers. Readings arrive from the
/// agents themselves (statusline hooks over a Unix socket, Codex session
/// logs); the web is asked only when an account's local data has gone stale
/// and someone is looking, or when the user asks for a refresh. Nothing runs
/// in the background apart from one cheap timer that ages readings.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var config: AppConfig
    @Published private(set) var isRefreshing = false
    /// Newest first, from `errors.log`; loaded on demand by Settings.
    @Published private(set) var errorLines: [String] = []

    var isCollectionPaused: Bool { config.collectionPaused }

    private let configStore: AppConfigStore
    let quotaStore = QuotaStore()
    private var datagramListener: DatagramListener?
    private var codexReaders: [String: CodexLogReader] = [:]
    private let snapshotWriter = SnapshotWriter()
    private var tickTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastTimestampOnlyRecompute: [String: Date] = [:]
    /// A timestamp-only reading (same numbers, newer time) refreshes the UI at
    /// most this often per source, so a hook firing every few seconds does
    /// not re-render anything.
    private let timestampOnlyRefreshInterval: TimeInterval = 60
    /// Re-evaluates freshness (fresh → stale) and the web fallback.
    private let tickInterval: TimeInterval = 60

    // MARK: Web fallback
    //
    // Automatic: only when someone is looking (popover or desktop panel
    // visible, or just after wake), an account's local data is older than
    // `webFallbackStaleAfter`, and at most once per `webFallbackMinInterval`.
    // Manual refresh skips the staleness rule but not `manualRefreshMinInterval`.
    private let webFetcher = WebQuotaFetcher()
    private let webFallbackStaleAfter: TimeInterval = 15 * 60
    private let webFallbackMinInterval: TimeInterval = 10 * 60
    private let manualRefreshMinInterval: TimeInterval = 30
    private var lastWebAttempt: [String: Date] = [:]
    private var webFetchInFlight: Set<String> = []
    /// Why the last web attempt for an account failed; cleared on success.
    private var webIssue: [String: String] = [:]
    private var justWoke = false
    private var isPopoverVisible = false
    private var isWidgetVisible = false
    /// Collectors run only between start() and stop().
    private var isStarted = false

    init(configStore: AppConfigStore = AppConfigStore()) {
        self.configStore = configStore
        self.config = configStore.load()
        recomputeAccounts()
    }

    func start() {
        isStarted = true
        if !config.collectionPaused { startCollectors() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.justWoke = true
                self?.tick()
            }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tickTimer?.tolerance = 10
        NotificationManager.shared.evaluate(accounts: accounts, config: config)
        publishSnapshot()
    }

    /// Stops everything and removes the hooks' snapshot so they stop showing
    /// numbers from a QuotaPeek that is no longer running.
    func stop() {
        isStarted = false
        tickTimer?.invalidate()
        tickTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        stopCollectors()
        snapshotWriter.remove()
    }

    private func tick() {
        for reader in codexReaders.values { reader.rescan() }
        recomputeAccounts()
        runWebFallbackIfNeeded()
    }

    // MARK: - Collectors

    private func startCollectors() {
        if datagramListener == nil {
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
        }
        syncCodexReaders()
    }

    private func stopCollectors() {
        datagramListener?.stop()
        datagramListener = nil
        codexReaders.values.forEach { $0.stop() }
        codexReaders.removeAll()
    }

    /// One log reader per Codex home in use (configured accounts only).
    private func syncCodexReaders() {
        let wanted: Set<String> = config.codex.routesEnabled.contains(.injection) ? Set(
            config.accounts.filter { $0.provider == .codex }
                .map { LocalQuotaParser.canonicalConfigDir($0.credentialLocation.configDir, provider: .codex) }
        ) : []
        for (dir, reader) in codexReaders where !wanted.contains(dir) {
            reader.stop()
            codexReaders[dir] = nil
        }
        for dir in wanted where codexReaders[dir] == nil {
            let reader = CodexLogReader(configDir: dir) { [weak self] reading in
                Task { @MainActor in self?.applyLocalReading(reading) }
            }
            codexReaders[dir] = reader
            reader.start()
        }
    }

    func applyLocalReading(_ reading: LocalReading) {
        guard !config.collectionPaused else { return }
        if reading.source != .web, !config.config(for: reading.provider).routesEnabled.contains(.injection) { return }
        let previous = quotaStore.readings[reading.key]
        switch quotaStore.apply(reading) {
        case .ignored:
            return
        case .timestampOnly:
            // Same numbers, newer time: only the "updated" time would move,
            // so throttle - unless the previous reading had gone stale, in
            // which case the account must flip back to fresh right away.
            let staleAfterMs = Int64(config.staleAfterSeconds) * 1000
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

    // MARK: - Accounts

    /// Rebuilds `accounts` from the configuration and the latest readings,
    /// publishing only if something visible changed. Notifications and the
    /// snapshot file only while started.
    private func recomputeAccounts(now: Date = Date()) {
        let merged = Self.buildAccounts(config: config, readings: { self.localReading(for: $0) },
                                        webIssue: webIssue, now: now)
        if accounts != merged {
            accounts = merged
            if isStarted { NotificationManager.shared.evaluate(accounts: accounts, config: config) }
        }
        publishSnapshot()
    }

    static func buildAccounts(config: AppConfig, readings: (AccountConfig) -> LocalReading?,
                              webIssue: [String: String], now: Date) -> [Account] {
        let nowSec = Int64(now.timeIntervalSince1970)
        return config.accounts.map { cfg in
            var account = Account(id: cfg.id, provider: cfg.provider, label: cfg.label,
                                  credentialLocation: cfg.credentialLocation,
                                  routesEnabled: config.config(for: cfg.provider).routesEnabled)
            let issue = webIssue[cfg.id]
            guard let reading = readings(cfg) else {
                account.state = issue == nil ? .unknown : .error
                account.lastError = issue
                return account
            }
            let readingSec = reading.observedAtMs / 1000
            account.data = reading.data
            account.asOf = readingSec
            account.activeRoute = reading.source == .web ? .keychain : .injection
            let isStale = nowSec - readingSec > Int64(config.staleAfterSeconds)
            account.state = isStale ? .stale : .fresh
            // A stale account shows why the web couldn't bring it up to date.
            account.lastError = isStale ? issue : nil
            return account
        }
    }

    private func localReading(for account: AccountConfig) -> LocalReading? {
        switch account.provider {
        case .antigravity:
            // The agy hook cannot say which login is active, so only a single
            // Antigravity account can be matched.
            let count = config.accounts.filter { $0.provider == .antigravity }.count
            return count == 1 ? quotaStore.reading(provider: .antigravity, configDir: "") : nil
        case .claude, .codex:
            let dir = LocalQuotaParser.canonicalConfigDir(account.credentialLocation.configDir, provider: account.provider)
            return quotaStore.reading(provider: account.provider, configDir: dir)
        }
    }

    enum AccountError: Error, CustomStringConvertible {
        case duplicate(String)
        case notFound
        case saveFailed(String)

        var description: String {
            switch self {
            case .duplicate(let why): return why
            case .notFound: return "Account not found."
            case .saveFailed(let why): return "Could not save settings: \(why)"
            }
        }
    }

    func createAccount(provider: Provider, label: String, configDir: String?) -> Result<AccountConfig, AccountError> {
        let location: CredentialLocation
        if provider == .antigravity {
            guard !config.accounts.contains(where: { $0.provider == .antigravity }) else {
                return .failure(.duplicate("Antigravity reports through a single statusline hook, so only one Antigravity account can be tracked."))
            }
            location = CredentialLocation(kind: CredentialLocation.hookKind)
        } else {
            let dir = LocalQuotaParser.canonicalConfigDir(configDir, provider: provider)
            let taken = config.accounts.contains {
                $0.provider == provider && LocalQuotaParser.canonicalConfigDir($0.credentialLocation.configDir, provider: provider) == dir
            }
            guard !taken else { return .failure(.duplicate("An account already uses \(dir).")) }
            location = CredentialLocation(kind: CredentialLocation.configDirKind, configDir: dir)
        }
        let account = AccountConfig(id: AccountConfig.newID(), provider: provider, label: label, credentialLocation: location)
        var next = config
        next.accounts.append(account)
        return save(next).map { account }
    }

    func renameAccount(id: String, label: String) -> Result<Void, AccountError> {
        guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return .failure(.notFound) }
        var next = config
        next.accounts[index].label = label
        return save(next)
    }

    func deleteAccount(id: String) -> Result<Void, AccountError> {
        var next = config
        next.accounts.removeAll { $0.id == id }
        webIssue[id] = nil
        lastWebAttempt[id] = nil
        return save(next)
    }

    // MARK: - Configuration

    @discardableResult
    func saveConfig(_ newConfig: AppConfig) -> Bool {
        if case .success = save(newConfig) { return true }
        return false
    }

    func setCollectionPaused(_ paused: Bool) -> Result<Void, AccountError> {
        var next = config
        next.collectionPaused = paused
        return save(next)
    }

    private func save(_ newConfig: AppConfig) -> Result<Void, AccountError> {
        guard newConfig != config else { return .success(()) }
        do {
            try configStore.save(newConfig)
        } catch {
            ErrorLog.error("config save failed: \(error.localizedDescription)")
            return .failure(.saveFailed(error.localizedDescription))
        }
        let wasPaused = config.collectionPaused
        config = newConfig
        if newConfig.collectionPaused != wasPaused {
            ErrorLog.info("collection \(newConfig.collectionPaused ? "paused" : "resumed")")
        }
        if newConfig.collectionPaused {
            stopCollectors()
        } else if isStarted {
            startCollectors() // also picks up added or removed Codex homes
        }
        recomputeAccounts()
        if isStarted { NotificationManager.shared.evaluate(accounts: accounts, config: config) }
        return .success(())
    }

    func loadErrors() {
        errorLines = ErrorLog.recentLines(limit: 100).reversed()
    }

    // MARK: - Visibility and refresh

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        if visible { tick() }
    }

    /// Whether any desktop panel is on screen.
    func setWidgetVisible(_ visible: Bool) {
        guard isWidgetVisible != visible else { return }
        isWidgetVisible = visible
        if visible { tick() }
    }

    /// Manual refresh: re-reads Codex logs and asks the web for every account
    /// (or just `accountId`) that allows it, whether or not its local data is
    /// stale. Returns once those requests have finished.
    func refresh(accountId: String? = nil) async {
        guard !config.collectionPaused else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for reader in codexReaders.values { reader.rescan() }
        let now = Date()
        let targets = webEligibleAccounts().filter {
            (accountId == nil || $0.id == accountId)
                && now.timeIntervalSince(lastWebAttempt[$0.id] ?? .distantPast) > manualRefreshMinInterval
        }
        await withTaskGroup(of: Void.self) { group in
            for account in targets { group.addTask { await self.fetchFromWeb(account) } }
        }
        recomputeAccounts()
    }

    /// Fetches from the web for accounts whose local data has gone stale,
    /// subject to the visibility and rate rules above.
    func runWebFallbackIfNeeded(now: Date = Date()) {
        guard !config.collectionPaused, isPopoverVisible || isWidgetVisible || justWoke else { return }
        justWoke = false
        for account in webEligibleAccounts() {
            let ageSec = localReading(for: account).map { now.timeIntervalSince1970 - Double($0.observedAtMs) / 1000 } ?? .infinity
            guard ageSec > webFallbackStaleAfter,
                  now.timeIntervalSince(lastWebAttempt[account.id] ?? .distantPast) > webFallbackMinInterval else { continue }
            Task { await fetchFromWeb(account) }
        }
    }

    private func webEligibleAccounts() -> [AccountConfig] {
        config.accounts.filter {
            $0.provider.supportsWebFallback && config.config(for: $0.provider).routesEnabled.contains(.keychain)
                && !webFetchInFlight.contains($0.id)
        }
    }

    private func fetchFromWeb(_ account: AccountConfig) async {
        guard !webFetchInFlight.contains(account.id) else { return }
        lastWebAttempt[account.id] = Date()
        webFetchInFlight.insert(account.id)
        defer { webFetchInFlight.remove(account.id) }
        let configDir = account.credentialLocation.configDir
        let label = "\(account.provider.rawValue)/\(account.label)"
        do {
            let data = try await webFetcher.fetch(provider: account.provider, configDir: configDir)
            webIssue[account.id] = nil
            ErrorLog.info("web fallback \(label): ok")
            applyLocalReading(LocalReading(
                provider: account.provider,
                configDir: LocalQuotaParser.canonicalConfigDir(configDir, provider: account.provider),
                observedAtMs: Int64(Date().timeIntervalSince1970 * 1000), source: .web, data: data))
        } catch {
            let message = (error as? WebQuotaFetcher.FetchError)?.description ?? error.localizedDescription
            if webIssue[account.id] != message { ErrorLog.warning("web fallback \(label): \(message)") }
            webIssue[account.id] = message
        }
        recomputeAccounts()
    }

    /// Settings' "Test" button: does this route work for this account right now?
    func checkRoute(accountId: String, route: Route) async -> RouteCheckResult {
        guard let account = config.accounts.first(where: { $0.id == accountId }) else {
            return RouteCheckResult(ok: false, message: "Account not found.")
        }
        switch route {
        case .keychain:
            guard account.provider.supportsWebFallback else {
                return RouteCheckResult(ok: false, message: "No web fallback for \(account.provider.displayName).")
            }
            do {
                let data = try await webFetcher.fetch(provider: account.provider, configDir: account.credentialLocation.configDir)
                let pct = [data.usedPercent5h, data.usedPercentWeekly].compactMap { $0 }.map { String(format: "%.0f%%", $0) }
                return RouteCheckResult(ok: true, message: "Web usage read: \(pct.joined(separator: " / ")).")
            } catch {
                let message = (error as? WebQuotaFetcher.FetchError)?.description ?? error.localizedDescription
                return RouteCheckResult(ok: false, message: message)
            }
        case .injection, .none:
            guard let reading = localReading(for: account), reading.source != .web else {
                let how: String
                switch account.provider {
                case .claude: how = "Use Claude Code once with the QuotaPeek statusline installed."
                case .codex: how = "Run Codex once; its session log carries the quota."
                case .antigravity: how = "Use agy once with the QuotaPeek statusline installed."
                }
                return RouteCheckResult(ok: false, message: "No reading from the agent yet. \(how)")
            }
            let age = RelativeDateFormatting.format(reading.observedAtMs / 1000)
            return RouteCheckResult(ok: true, message: "Last reading from the agent: \(age).")
        }
    }

    // MARK: - Snapshot

    /// Display preferences readers of the snapshot (the native widget) must
    /// honour; kept in sync by the app delegate.
    var snapshotDisplay = QuotaSnapshot.Display() {
        didSet { if snapshotDisplay != oldValue { publishSnapshot() } }
    }

    /// The native widget's account/metric selection; kept in sync by the app delegate.
    var snapshotNativeWidget = QuotaSnapshot.NativeWidget() {
        didSet { if snapshotNativeWidget != oldValue { publishSnapshot() } }
    }

    private func publishSnapshot() {
        guard isStarted else { return }
        snapshotWriter.update(accounts: accounts, showOtherAgents: config.statuslineShowOtherAgents,
                              display: snapshotDisplay, nativeWidget: snapshotNativeWidget)
    }

    // MARK: - Queries

    func isAccountEnabled(_ account: Account) -> Bool {
        !account.routesEnabled.isEmpty
    }

    /// Highest usage percent across enabled accounts with numbers, or nil.
    var highestUsagePercent: Double? {
        var highest: Double?
        for account in accounts where isAccountEnabled(account) {
            guard account.state != .unknown && account.state != .error, let data = account.data else { continue }
            if let maxVal = [data.usedPercent5h, data.usedPercentWeekly].compactMap({ $0 }).max() {
                highest = max(highest ?? 0, maxVal)
            }
        }
        return highest
    }

    /// True if any enabled account could not be read at all. Stale alone is
    /// normal (the agent just hasn't been used lately) and shows per account.
    var hasFailingAccount: Bool {
        accounts.contains { isAccountEnabled($0) && $0.state == .error }
    }
}
