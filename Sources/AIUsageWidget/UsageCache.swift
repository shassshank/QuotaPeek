import Foundation

/// Shared read-merge-write helper for the usage.json cache file. Multiple sources write into it
/// (this app's in-process Claude/Antigravity collectors, plus the external codex poller script),
/// so every writer must merge rather than overwrite the whole file.
enum UsageCache {
    private static let lock = NSLock()

    static func merge(provider: String, usage: ProviderUsage) {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = (try? Data(contentsOf: UsageStore.cacheFile))
            .flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
            ?? UsageSnapshot()

        switch provider {
        case "claude": snapshot.claude = usage
        case "codex": snapshot.codex = usage
        case "antigravity": snapshot.antigravity = usage
        default: return
        }

        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        try? FileManager.default.createDirectory(at: UsageStore.cacheDirectory, withIntermediateDirectories: true)
        let tmp = UsageStore.cacheFile.appendingPathExtension("tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(UsageStore.cacheFile, withItemAt: tmp)
    }
}
