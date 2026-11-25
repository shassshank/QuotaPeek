import QuotaPeekCore
import XCTest
@testable import QuotaPeek

final class WebQuotaFetcherTests: XCTestCase {
    func testParseClaudeUsage() throws {
        let body = #"{"five_hour":{"utilization":31.0,"resets_at":"2026-11-25T12:00:00.123+00:00"},"seven_day":{"utilization":40,"resets_at":"2026-11-28T09:00:00Z"},"seven_day_opus":null}"#
        let data = try XCTUnwrap(WebQuotaFetcher.parseClaudeUsage(Data(body.utf8)))
        XCTAssertEqual(data.usedPercent5h, 31)
        XCTAssertEqual(data.resetsAt5h, 1795608000)
        XCTAssertEqual(data.usedPercentWeekly, 40)
        XCTAssertNil(WebQuotaFetcher.parseClaudeUsage(Data(#"{"error":"x"}"#.utf8)))
    }

    func testParseCodexUsage() throws {
        let body = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":2,"reset_at":1795610875},"secondary_window":{"used_percent":36,"reset_at":1796064364}}}"#
        let data = try XCTUnwrap(WebQuotaFetcher.parseCodexUsage(Data(body.utf8)))
        XCTAssertEqual(data.usedPercent5h, 2)
        XCTAssertEqual(data.resetsAt5h, 1795610875)
        XCTAssertEqual(data.usedPercentWeekly, 36)
        XCTAssertNil(WebQuotaFetcher.parseCodexUsage(Data(#"{"rate_limit":null}"#.utf8)))
    }

    func testClaudeKeychainServiceNaming() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(WebQuotaFetcher.claudeKeychainService(configDir: nil), "Claude Code-credentials")
        XCTAssertEqual(WebQuotaFetcher.claudeKeychainService(configDir: "\(home)/.claude"), "Claude Code-credentials")
        // sha256("/tmp/work-claude") starts with 4d3d1c9b... - same rule as Claude Code / the old daemon.
        let other = WebQuotaFetcher.claudeKeychainService(configDir: "/tmp/work-claude")
        XCTAssertTrue(other.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(other.count, "Claude Code-credentials-".count + 8)
    }

    func testJWTClaims() {
        // header.payload.signature with payload {"exp":1700000000,"sub":"x"}
        let jwt = "eyJhbGciOiJub25lIn0.eyJleHAiOjE3MDAwMDAwMDAsInN1YiI6IngifQ.sig"
        XCTAssertEqual(WebQuotaFetcher.jwtClaims(jwt)?["exp"] as? Int, 1700000000)
        XCTAssertNil(WebQuotaFetcher.jwtClaims("nope"))
    }

    func testExpiredTokensStopBeforeAnyNetworkCall() async {
        var fetcher = WebQuotaFetcher()
        // Claude: expiresAt in the past (ms).
        fetcher.readKeychain = { service, _ in
            service.hasPrefix("Claude")
                ? Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000}}"#.utf8)
                : Data(#"{"tokens":{"access_token":"eyJhbGciOiJub25lIn0.eyJleHAiOjE3MDAwMDAwMDAsInN1YiI6IngifQ.sig"}}"#.utf8)
        }
        do {
            _ = try await fetcher.fetch(provider: .claude, configDir: nil)
            XCTFail("expected tokenExpired")
        } catch {
            XCTAssertEqual(error as? WebQuotaFetcher.FetchError, .tokenExpired("claude"))
        }
        do {
            _ = try await fetcher.fetch(provider: .codex, configDir: nil)
            XCTFail("expected tokenExpired")
        } catch {
            XCTAssertEqual(error as? WebQuotaFetcher.FetchError, .tokenExpired("codex"))
        }
    }

    func testMissingCredentials() async {
        var fetcher = WebQuotaFetcher()
        fetcher.readKeychain = { _, _ in nil }
        do {
            _ = try await fetcher.fetch(provider: .claude, configDir: "/nonexistent/claude")
            XCTFail("expected noCredentials")
        } catch let error as WebQuotaFetcher.FetchError {
            if case .noCredentials = error {} else { XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
    }
}

/// Opt-in: one real read-only request per provider using this Mac's stored
/// CLI logins (`QP_LIVE=1 swift test --filter LiveWeb`).
final class LiveWebTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QP_LIVE"] == "1", "set QP_LIVE=1 to run")
    }

    func testCodexKeychainAccountMatchesCodexCLI() async {
        let home = LocalQuotaParser.canonicalConfigDir(nil, provider: .codex)
        let account = WebQuotaFetcher.codexKeychainAccount(codexHome: home)
        // Existence only (no -w): the secret is never printed.
        let found = await SecurityCLI.run(["find-generic-password", "-s", "Codex Auth", "-a", account], timeout: 5)
        print("codex keychain item for \(account): \(found == nil ? "missing" : "present")")
    }

    func testLiveFetch() async {
        let fetcher = WebQuotaFetcher()
        for provider in [Provider.claude, .codex] {
            do {
                let d = try await fetcher.fetch(provider: provider, configDir: nil)
                print("live \(provider.rawValue): 5h \(d.usedPercent5h ?? -1)% wk \(d.usedPercentWeekly ?? -1)%")
            } catch {
                print("live \(provider.rawValue): \(error)")
            }
        }
    }
}
