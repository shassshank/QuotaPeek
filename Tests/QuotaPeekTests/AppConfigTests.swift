import QuotaPeekCore
import XCTest
@testable import QuotaPeek

final class AppConfigTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("config.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Exactly the shape the 1.x daemon wrote.
    private let daemonConfig = """
    {
      "accounts": [
        {"id": "acct_a", "provider": "claude", "label": "Work",
         "credentialLocation": {"kind": "config_dir", "configDir": "/Users/x/.claude"}},
        {"id": "acct_b", "provider": "codex", "label": "Work",
         "credentialLocation": {"kind": "config_dir", "configDir": "/Users/x/.codex"}},
        {"id": "acct_c", "provider": "antigravity", "label": "Me",
         "credentialLocation": {"kind": "daemon_token", "configDir": null}},
        {"id": "acct_d", "provider": "somethingnew", "label": "?",
         "credentialLocation": {"kind": "config_dir"}}
      ],
      "staleAfterSeconds": 900,
      "collectionPaused": true,
      "statusline_show_other_agents": false,
      "claude_polling_mode": "inference",
      "claude": {"routes_enabled": ["injection", "keychain"], "keychain_poll_interval_sec": 300,
                 "notify_threshold_percent": 80},
      "codex": {"routes_enabled": ["keychain"], "keychain_poll_interval_sec": 300},
      "antigravity": {"routes_enabled": ["keychain"], "keychain_poll_interval_sec": 300}
    }
    """

    func testDaemonConfigIsReadAndMigrated() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(daemonConfig.utf8))
        XCTAssertEqual(config.version, AppConfig.currentVersion)
        // The unknown provider is skipped; the rest keep their ids and labels.
        XCTAssertEqual(config.accounts.map(\.id), ["acct_a", "acct_b", "acct_c"])
        XCTAssertEqual(config.accounts[0].credentialLocation.configDir, "/Users/x/.claude")
        XCTAssertEqual(config.accounts[2].credentialLocation.kind, CredentialLocation.hookKind)
        XCTAssertEqual(config.staleAfterSeconds, 900)
        XCTAssertTrue(config.collectionPaused)
        XCTAssertFalse(config.statuslineShowOtherAgents)
        XCTAssertEqual(config.claude, ProviderConfig(routesEnabled: [.injection, .keychain], notifyThresholdPercent: 80))
        // Codex gains its session-log route; Antigravity loses the daemon's token route.
        XCTAssertEqual(config.codex.routesEnabled, [.injection, .keychain])
        XCTAssertEqual(config.antigravity.routesEnabled, [.injection])
    }

    func testProviderSwitchedOffStaysOff() throws {
        let json = #"{"codex": {"routes_enabled": []}, "antigravity": {"routes_enabled": []}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.codex.routesEnabled, [])
        XCTAssertEqual(config.antigravity.routesEnabled, [])
        // Missing sections and accounts fall back to defaults.
        XCTAssertEqual(config.claude, .defaults(for: .claude))
        XCTAssertEqual(config.accounts.map(\.id), Provider.allCases.map(AccountConfig.defaultID))
    }

    func testCurrentVersionIsNotMigratedAgain() throws {
        // A user who turned Codex logs off in 2.x must not get them back on load.
        let json = #"{"version": 2, "codex": {"routes_enabled": ["keychain"]}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.codex.routesEnabled, [.keychain])
    }

    func testStoreRoundTripsAndMigratesOnDisk() throws {
        try Data(daemonConfig.utf8).write(to: url)
        let store = AppConfigStore(url: url)
        let loaded = store.load()
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(onDisk?["version"] as? Int, AppConfig.currentVersion)
        XCTAssertNil(onDisk?["claude_polling_mode"])
        XCTAssertEqual(store.load(), loaded)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testFirstRunSeedsDetectedAgentsAndSaves() throws {
        let config = AppConfigStore(url: url).load()
        XCTAssertEqual(config.accounts, AppConfigStore.detectedAccounts())
        XCTAssertFalse(config.accounts.isEmpty)
        XCTAssertTrue(config.accounts.allSatisfy { $0.id == AccountConfig.defaultID(for: $0.provider) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnreadableConfigIsKeptAside() throws {
        try Data("{not json".utf8).write(to: url)
        let config = AppConfigStore(url: url).load()
        XCTAssertEqual(config, AppConfig())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
    }

    @MainActor
    func testAccountsAreCreatedRenamedAndRemoved() throws {
        let store = UsageStore(configStore: AppConfigStore(url: url))
        XCTAssertEqual(store.accounts.count, 3)

        guard case .success(let work) = store.createAccount(provider: .claude, label: "Work", configDir: "~/.claude-work") else {
            return XCTFail("create failed")
        }
        XCTAssertTrue(work.credentialLocation.configDir?.hasSuffix("/.claude-work") == true)
        if case .success = store.createAccount(provider: .claude, label: "Again", configDir: "~/.claude-work") {
            XCTFail("duplicate config dir accepted")
        }
        if case .success = store.createAccount(provider: .antigravity, label: "Second", configDir: nil) {
            XCTFail("second Antigravity account accepted")
        }
        _ = store.renameAccount(id: work.id, label: "Job")
        XCTAssertEqual(AppConfigStore(url: url).load().accounts.first { $0.id == work.id }?.label, "Job")

        _ = store.deleteAccount(id: work.id)
        XCTAssertFalse(store.accounts.contains { $0.id == work.id })
        XCTAssertFalse(AppConfigStore(url: url).load().accounts.contains { $0.id == work.id })
    }

    @MainActor
    func testPauseIgnoresReadings() throws {
        let store = UsageStore(configStore: AppConfigStore(url: url))
        _ = store.setCollectionPaused(true)
        store.applyLocalReading(LocalReading(provider: .claude, configDir: "/c", observedAtMs: 1, source: .hook,
                                             data: ProviderData(usedPercent5h: 5)))
        XCTAssertTrue(store.quotaStore.readings.isEmpty)
    }

    func testLegacyLeftoversAreOnlyDaemonFiles() throws {
        for name in ["config.json", "errors.log", "snapshot.json", "oauth-codex-acct_1.json", "auth-token"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        let names = Set(LegacyDaemon.leftoverFiles(in: dir).map(\.lastPathComponent))
        XCTAssertTrue(names.isSuperset(of: ["oauth-codex-acct_1.json", "auth-token", "samples.json", "quotapeekd"]))
        XCTAssertTrue(names.isDisjoint(with: ["config.json", "errors.log", "snapshot.json"]))
    }
}
