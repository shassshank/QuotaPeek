import Foundation
import Combine

/// Holds the latest state fetched from the Go daemon. This replaces the old file-watching cache
/// reader entirely - the daemon is the single source of truth and the only thing this app talks to.
@MainActor
final class UsageStore: ObservableObject {
    @Published var providers: [Provider: ProviderStatus] = [:]
    @Published var isDaemonReachable = true
    @Published var isRefreshing = false
    @Published var errors: [ErrorLogEntry] = []
    @Published var config: DaemonConfig?

    private let client = DaemonClient()
    private var timer: Timer?

    func start(pollInterval: TimeInterval = 8) {
        Task { await reload() }
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
        case .failure:
            isDaemonReachable = false
        }
    }

    func loadConfig() async {
        if case .success(let cfg) = await client.config() {
            config = cfg
        }
    }

    func saveConfig(_ newConfig: DaemonConfig) async -> Bool {
        switch await client.updateConfig(newConfig) {
        case .success(let cfg):
            config = cfg
            await reload()
            return true
        case .failure:
            return false
        }
    }

    func loadErrors() async {
        if case .success(let response) = await client.errors() {
            errors = response.errors
        }
    }

    func testRoute(provider: Provider, route: Route) async -> Result<TestRouteResponse, DaemonError> {
        await client.testRoute(provider: provider, route: route)
    }
}
