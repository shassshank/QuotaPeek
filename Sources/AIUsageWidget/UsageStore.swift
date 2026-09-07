import Foundation
import Combine

/// Holds the latest state fetched from the Go daemon. This replaces the old file-watching cache
/// reader entirely - the daemon is the single source of truth and the only thing this app talks to.
@MainActor
final class UsageStore: ObservableObject {
    @Published var providers: [Provider: ProviderStatus] = [:]
    @Published var history: [Provider: [HistoryPoint]] = [:]
    @Published var isDaemonReachable = true
    @Published var isRefreshing = false
    @Published var isCollectionPaused = false
    @Published var errors: [ErrorLogEntry] = []
    @Published var config: DaemonConfig?

    private let client = DaemonClient()
    private var timer: Timer?

    func start(pollInterval: TimeInterval = 8) {
        Task {
            await loadConfig()
            await reload()
        }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.reload() }
        }
    }

    func reload() async {
        switch await client.status() {
        case .success(let response):
            isDaemonReachable = true
            for provider in response.providers {
                providers[provider.provider] = provider
            }
            NotificationManager.shared.evaluate(providers: providers, config: config)
            await loadAllHistory()
        case .failure:
            isDaemonReachable = false
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        switch await client.refresh() {
        case .success(let response):
            isDaemonReachable = true
            for provider in response.providers {
                providers[provider.provider] = provider
            }
            NotificationManager.shared.evaluate(providers: providers, config: config)
            await loadAllHistory()
        case .failure:
            isDaemonReachable = false
        }
    }

    func loadConfig() async {
        if case .success(let cfg) = await client.config() {
            config = cfg
            if let paused = cfg.collectionPaused {
                isCollectionPaused = paused
            }
            NotificationManager.shared.evaluate(providers: providers, config: cfg)
        }
    }

    func saveConfig(_ newConfig: DaemonConfig) async -> Bool {
        switch await client.updateConfig(newConfig) {
        case .success(let cfg):
            config = cfg
            if let paused = cfg.collectionPaused {
                isCollectionPaused = paused
            }
            NotificationManager.shared.evaluate(providers: providers, config: cfg)
            await reload()
            return true
        case .failure:
            return false
        }
    }

    func setCollectionPaused(_ paused: Bool) async -> Bool {
        isCollectionPaused = paused

        let result: Result<DaemonConfig, DaemonError>
        if paused {
            result = await client.pauseCollection()
        } else {
            result = await client.resumeCollection()
        }

        switch result {
        case .success(let cfg):
            config = cfg
            if let serverPaused = cfg.collectionPaused {
                isCollectionPaused = serverPaused
            }
            NotificationManager.shared.evaluate(providers: providers, config: cfg)
            await reload()
            return true
        case .failure:
            return false
        }
    }

    func resetCredentials(for provider: Provider) async -> Result<ResetCredentialsResponse, DaemonError> {
        let result = await client.resetCredentials(for: provider)
        await reload()
        return result
    }

    func loadErrors() async {
        if case .success(let response) = await client.errors() {
            errors = response.errors
        }
    }

    /// Fetches usage history points for a given provider and route.
    func loadHistory(for provider: Provider, route: Route? = nil) async {
        let targetRoute: Route
        if let route, route != .none {
            targetRoute = route
        } else if let active = providers[provider]?.activeRoute, active != .none {
            targetRoute = active
        } else if let firstEnabled = providers[provider]?.routesEnabled.first {
            targetRoute = firstEnabled
        } else {
            return
        }
        let result = await client.history(provider: provider, route: targetRoute)
        if case .success(let resp) = result {
            history[provider] = resp.points
        }
    }

    /// Fetches usage history points for all enabled providers.
    func loadAllHistory() async {
        for provider in Provider.allCases where isProviderEnabled(provider) {
            await loadHistory(for: provider)
        }
    }

    /// Returns true if a specific provider's data is stale according to configured threshold.
    func isProviderStale(_ provider: Provider) -> Bool {
        guard let status = providers[provider], let asOf = status.asOf else { return false }
        let pollInterval = config?.config(for: provider)?.keychainPollIntervalSec ?? 60
        let staleThreshold = TimeInterval(config?.staleAfterSeconds ?? max(2 * pollInterval, 600))
        return Date().timeIntervalSince1970 - Double(asOf) > staleThreshold
    }

    func testRoute(provider: Provider, route: Route) async -> Result<TestRouteResponse, DaemonError> {
        await client.testRoute(provider: provider, route: route)
    }

    func isProviderEnabled(_ provider: Provider) -> Bool {
        if let status = providers[provider] {
            return !status.routesEnabled.isEmpty
        }
        if let config = config?.config(for: provider) {
            return !config.routesEnabled.isEmpty
        }
        return true
    }

    /// Highest usage percent across enabled providers (checks 5h, weekly, and context window).
    var highestUsagePercent: Double? {
        var highest: Double?
        for provider in Provider.allCases where isProviderEnabled(provider) {
            guard let data = providers[provider]?.data else { continue }
            let values = [data.usedPercent5h, data.usedPercentWeekly, data.contextWindowUsedPercent].compactMap { $0 }
            if let maxVal = values.max() {
                highest = max(highest ?? 0, maxVal)
            }
        }
        return highest
    }

    /// Returns true if daemon is unreachable, or any enabled provider is failing or stale.
    var isStaleOrFailing: Bool {
        guard isDaemonReachable else { return true }
        for provider in Provider.allCases where isProviderEnabled(provider) {
            guard let status = providers[provider] else { continue }
            if status.displayLastError != nil || status.lastError != nil {
                return true
            }
            if isProviderStale(provider) {
                return true
            }
        }
        return false
    }
}
