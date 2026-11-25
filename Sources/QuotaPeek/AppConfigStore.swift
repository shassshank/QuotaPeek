import Foundation
import QuotaPeekCore

/// Loads and saves `config.json` in the support folder. The file is small and
/// only written when the user changes a setting, so plain synchronous I/O on
/// the main actor is fine.
struct AppConfigStore {
    let url: URL

    init(url: URL = AppPaths.supportDirectory.appendingPathComponent("config.json")) {
        self.url = url
    }

    /// The saved configuration, or the defaults on first run. An unreadable
    /// file is kept aside as `config.json.unreadable` rather than overwritten.
    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url) else {
            let config = AppConfig(accounts: Self.detectedAccounts())
            try? save(config)
            return config
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
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

    /// First run: one "Default" account per agent whose config folder exists
    /// (no credentials are read). If none is found, all three, so the user
    /// sees what QuotaPeek can show.
    static func detectedAccounts() -> [AccountConfig] {
        let fm = FileManager.default
        let found = Provider.allCases.filter { provider in
            let path: String
            switch provider {
            case .claude, .codex: path = LocalQuotaParser.canonicalConfigDir(nil, provider: provider)
            case .antigravity: path = NSHomeDirectory() + "/.gemini/antigravity-cli"
            }
            return fm.fileExists(atPath: path)
        }
        return (found.isEmpty ? Provider.allCases : found).map(AccountConfig.makeDefault)
    }
}
