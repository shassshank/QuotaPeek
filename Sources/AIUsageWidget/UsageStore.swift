import Foundation
import Combine

/// Reads the shared usage.json file that the per-provider collector scripts write to.
/// The app never talks to any provider directly — it only polls this local cache.
final class UsageStore: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    @Published var lastReadError: String?

    static let cacheDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("AIUsageWidget", isDirectory: true)
    }()

    static let cacheFile = cacheDirectory.appendingPathComponent("usage.json")

    private var timer: Timer?

    func start(pollInterval: TimeInterval = 15) {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        do {
            let data = try Data(contentsOf: Self.cacheFile)
            let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
            DispatchQueue.main.async {
                self.snapshot = decoded
                self.lastReadError = nil
            }
        } catch {
            DispatchQueue.main.async {
                self.lastReadError = "No usage data yet"
            }
        }
    }
}
