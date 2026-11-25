import XCTest
@testable import QuotaPeek

/// Opt-in checks against this Mac's real agent data: `QP_LIVE=1 swift test --filter LiveSmoke`.
final class LiveSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QP_LIVE"] == "1", "set QP_LIVE=1 to run")
    }

    func testReadsRealCodexSessionLogs() throws {
        let home = LocalQuotaParser.canonicalConfigDir(nil, provider: .codex)
        let sessions = URL(fileURLWithPath: home).appendingPathComponent("sessions")
        let recent = CodexLogReader.recentRollouts(in: sessions, limit: CodexLogReader.startupCandidates)
        XCTAssertFalse(recent.isEmpty, "no rollout logs under \(sessions.path)")
        let readings = recent.compactMap { CodexLogReader.latestRateLimits(inFile: $0.path) }
        let newest = try XCTUnwrap(readings.max { ($0.1 ?? 0) < ($1.1 ?? 0) })
        print("codex newest: 5h \(newest.0.usedPercent5h ?? -1)% weekly \(newest.0.usedPercentWeekly ?? -1)% at \(Date(timeIntervalSince1970: Double(newest.1 ?? 0) / 1000))")
    }
}
