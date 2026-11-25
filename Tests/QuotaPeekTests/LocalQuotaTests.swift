import XCTest
@testable import QuotaPeek

final class LocalQuotaParserTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testClaudeDatagram() throws {
        let msg = #"{"v":1,"provider":"claude","config_dir":"","observed_at_ms":1700000000123,"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1700003600},"seven_day":{"used_percent":"40.5","resets_at":"2023-11-21T00:00:00Z"}}}"#
        let r = try XCTUnwrap(LocalQuotaParser.datagram(json(msg), nowMs: 0))
        XCTAssertEqual(r.provider, .claude)
        XCTAssertEqual(r.source, .hook)
        XCTAssertEqual(r.observedAtMs, 1700000000123)
        XCTAssertEqual(r.configDir, LocalQuotaParser.canonicalConfigDir("~/.claude", provider: .claude))
        XCTAssertEqual(r.data.usedPercent5h, 30)
        XCTAssertEqual(r.data.resetsAt5h, 1700003600)
        XCTAssertEqual(r.data.usedPercentWeekly, 40.5)
        XCTAssertEqual(r.data.resetsAtWeekly, 1700524800)
    }

    func testDatagramRejectsUnknownVersionProviderAndEmptyData() {
        XCTAssertNil(LocalQuotaParser.datagram(json(#"{"v":2,"provider":"claude","rate_limits":{"five_hour":{"used_percentage":1}}}"#), nowMs: 0))
        XCTAssertNil(LocalQuotaParser.datagram(json(#"{"v":1,"provider":"gemini"}"#), nowMs: 0))
        XCTAssertNil(LocalQuotaParser.datagram(json(#"{"v":1,"provider":"claude","rate_limits":{}}"#), nowMs: 0))
        XCTAssertNil(LocalQuotaParser.datagram(json(#"{"v":1,"provider":"codex"}"#), nowMs: 0))
        XCTAssertNil(LocalQuotaParser.datagram(json("not json"), nowMs: 0))
    }

    func testPercentRejectsOutOfRangeBooleansAndNonFinite() {
        XCTAssertNil(LocalQuotaParser.percent(101))
        XCTAssertNil(LocalQuotaParser.percent(-1))
        XCTAssertNil(LocalQuotaParser.percent(true))
        XCTAssertNil(LocalQuotaParser.percent("nan"))
        XCTAssertEqual(LocalQuotaParser.percent("12.5"), 12.5)
    }

    func testAntigravityQuotaSplitsThirdPartyAndUsesRelativeReset() throws {
        let msg = #"{"v":1,"provider":"antigravity","observed_at_ms":1700000000000,"quota":{"Gemini 5h":{"remaining_fraction":0.75,"reset_in_seconds":600},"Claude/GPT weekly":{"remaining_fraction":0.1,"reset_time":"2023-11-21T00:00:00Z"},"bogus":{"remaining_fraction":2}}}"#
        let r = try XCTUnwrap(LocalQuotaParser.datagram(json(msg), nowMs: 0))
        XCTAssertEqual(r.configDir, "")
        XCTAssertEqual(r.data.usedPercent5h, 25)
        XCTAssertEqual(r.data.resetsAt5h, 1700000600)
        XCTAssertEqual(r.data.usedPercentWeeklyThirdParty, 90)
        // No first-party weekly bucket: falls back to the third-party one.
        XCTAssertEqual(r.data.usedPercentWeekly, 90)
        XCTAssertEqual(r.data.resetsAtWeekly, 1700524800)
    }

    func testCodexRolloutLine() throws {
        let line = #"{"timestamp":"2026-11-23T22:40:01.500Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":83.0,"window_minutes":300,"resets_at":1795497316},"secondary":{"used_percent":19.0,"window_minutes":10080,"resets_at":1796064365}}}}"#
        let (data, observed) = try XCTUnwrap(LocalQuotaParser.codexRolloutLine(json(line)))
        XCTAssertEqual(data.usedPercent5h, 83)
        XCTAssertEqual(data.resetsAt5h, 1795497316)
        XCTAssertEqual(data.usedPercentWeekly, 19)
        XCTAssertEqual(data.resetsAtWeekly, 1796064365)
        XCTAssertEqual(observed, 1795473601500)
    }

    func testCodexRolloutIgnoresOtherLimitIDs() {
        let line = #"{"payload":{"rate_limits":{"limit_id":"other","primary":{"used_percent":5,"window_minutes":300}}}}"#
        XCTAssertNil(LocalQuotaParser.codexRolloutLine(json(line)))
    }

    func testCanonicalConfigDir() {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        XCTAssertEqual(LocalQuotaParser.canonicalConfigDir(nil, provider: .codex), "\(home)/.codex")
        XCTAssertEqual(LocalQuotaParser.canonicalConfigDir("~/.claude/", provider: .claude), "\(home)/.claude")
        XCTAssertEqual(LocalQuotaParser.canonicalConfigDir(nil, provider: .antigravity), "")
    }
}

@MainActor
final class QuotaStoreTests: XCTestCase {
    private func reading(_ pct: Double, at ms: Int64) -> LocalReading {
        LocalReading(provider: .claude, configDir: "/c", observedAtMs: ms, source: .hook,
                     data: ProviderData(usedPercent5h: pct))
    }

    func testNewestWinsAndLateOlderReadingIsIgnored() {
        let store = QuotaStore()
        XCTAssertEqual(store.apply(reading(10, at: 2000)), .changed)
        XCTAssertEqual(store.apply(reading(5, at: 1000)), .ignored)
        XCTAssertEqual(store.reading(provider: .claude, configDir: "/c")?.data.usedPercent5h, 10)
        XCTAssertEqual(store.apply(reading(10, at: 3000)), .timestampOnly)
        XCTAssertEqual(store.apply(reading(11, at: 3000)), .ignored)
        XCTAssertEqual(store.apply(reading(12, at: 4000)), .changed)
    }

    func testOverlayPrefersNewerSourceAndMarksStaleness() {
        var account = Account(id: "a", provider: .claude, label: "L", routesEnabled: [.keychain],
                              activeRoute: .keychain, data: ProviderData(usedPercent5h: 1), asOf: 100,
                              restoredFromDisk: true, state: .stale)
        let newer = reading(50, at: 200_000)
        let merged = UsageStore.overlay(account, with: newer, nowSec: 210, staleAfter: 600)
        XCTAssertEqual(merged.data?.usedPercent5h, 50)
        XCTAssertEqual(merged.asOf, 200)
        XCTAssertEqual(merged.state, .fresh)
        XCTAssertEqual(merged.activeRoute, .injection)
        XCTAssertFalse(merged.restoredFromDisk)

        XCTAssertEqual(UsageStore.overlay(account, with: newer, nowSec: 1000, staleAfter: 600).state, .stale)

        account.asOf = 300
        XCTAssertEqual(UsageStore.overlay(account, with: newer, nowSec: 310, staleAfter: 600), account)
    }
}

final class CodexLogReaderTests: XCTestCase {
    func testLatestRateLimitsSkipsPartialTrailingLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let day = dir.appendingPathComponent("sessions/2026/11/23")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = day.appendingPathComponent("rollout-x.jsonl")
        let lines = [
            #"{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":10,"window_minutes":300}}}}"#,
            #"{"payload":{"type":"message"}}"#,
            #"{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":20,"window_minutes":300}}}}"#,
            #"{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_perc"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let newest = try XCTUnwrap(CodexLogReader.newestRollout(in: dir.appendingPathComponent("sessions")))
        XCTAssertEqual(URL(fileURLWithPath: newest.path).resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        let (data, _) = try XCTUnwrap(CodexLogReader.latestRateLimits(inFile: newest.path))
        XCTAssertEqual(data.usedPercent5h, 20)
    }
}

final class DatagramListenerTests: XCTestCase {
    func testReceivesDatagramsAndCleansUpSocket() throws {
        let path = "/tmp/qp-test-\(getpid()).sock"
        let got = expectation(description: "datagram")
        var received: Data?
        let listener = DatagramListener(path: path) { data in
            received = data
            got.fulfill()
        }
        try listener.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let payload = Array("hello".utf8)
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(sent, payload.count)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(received, Data("hello".utf8))

        listener.stop()
        let gone = expectation(description: "socket removed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gone.fulfill() }
        wait(for: [gone], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
