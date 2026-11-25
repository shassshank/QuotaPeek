import Foundation

/// Loads and saves `config.json` in the support folder. The file is small and
/// only written when the user changes a setting, so plain synchronous I/O on
/// the main actor is fine.
struct AppConfigStore {
    let url: URL

    init(url: URL = AppPaths.supportDirectory.appendingPathComponent("config.json")) {
        self.url = url
    }

    /// The saved configuration, or the defaults on first run. A config left
    /// by the old daemon is migrated and written back in the current format.
    /// An unreadable file is kept aside as `config.json.unreadable` rather
    /// than overwritten.
    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url) else {
            let config = AppConfig()
            try? save(config)
            return config
        }
        do {
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            if Self.fileVersion(of: data) != AppConfig.currentVersion {
                ErrorLog.notice("config: migrated to version \(AppConfig.currentVersion)")
                try? save(config)
            }
            return config
        } catch {
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            ErrorLog.error("config: unreadable (\(error.localizedDescription)); kept as \(aside.lastPathComponent), using defaults")
            let config = AppConfig()
            try? save(config)
            return config
        }
    }

    func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func fileVersion(of data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int
    }
}
