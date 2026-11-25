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

    /// A store on a temp file starting from a known configuration, so tests
    /// don't depend on which agents this Mac has installed.
    @MainActor
    private func makeStore(_ config: AppConfig = AppConfig()) throws -> UsageStore {
        try AppConfigStore(url: url).save(config)
        return UsageStore(configStore: AppConfigStore(url: url))
    }

    func testRoundTripsThroughDisk() throws {
        var config = AppConfig(staleAfterSeconds: 900, collectionPaused: true, statuslineShowOtherAgents: false)
        config.codex = ProviderConfig(routesEnabled: [.keychain], notifyThresholdPercent: 80)
        let store = AppConfigStore(url: url)
        try store.save(config)
        XCTAssertEqual(store.load(), config)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testMissingFieldsTakeDefaultsAndUnknownEntriesAreSkipped() throws {
        let json = """
        {"accounts": [
            {"id": "a", "provider": "claude", "label": "Work", "credentialLocation": {"kind": "config_dir", "configDir": "/x"}},
            {"id": "b", "provider": "somethingnew", "label": "?", "credentialLocation": {"kind": "config_dir"}}
         ],
         "codex": {"routesEnabled": ["injection", "carrier-pigeon"]}}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.accounts.map(\.id), ["a"])
        XCTAssertEqual(config.codex.routesEnabled, [.injection])
        XCTAssertEqual(config.claude, .defaults(for: .claude))
        XCTAssertEqual(config.antigravity, .defaults(for: .antigravity))
        XCTAssertEqual(config.staleAfterSeconds, 600)
        XCTAssertTrue(config.statuslineShowOtherAgents)
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
        let store = try makeStore()
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
        let store = try makeStore()
        _ = store.setCollectionPaused(true)
        store.applyLocalReading(LocalReading(provider: .claude, configDir: "/c", observedAtMs: 1, source: .hook,
                                             data: ProviderData(usedPercent5h: 5)))
        XCTAssertTrue(store.quotaStore.readings.isEmpty)
    }
}
