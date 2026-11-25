import QuotaPeekCore
import QuotaPeekWidgetUI
import XCTest
@testable import QuotaPeek

final class QuotaPresentationTests: XCTestCase {
    private func account(_ id: String, _ p: Provider, data: ProviderData? = ProviderData(usedPercent5h: 1)) -> QuotaSnapshot.Account {
        QuotaSnapshot.Account(id: id, provider: p, label: "P", state: .fresh, data: data, asOf: 1)
    }

    func testOrdersByProviderOrderAndSplitsClaudeGptPool() {
        let accounts = [
            account("a1", .antigravity, data: ProviderData(usedPercent5h: 0, usedPercent5hThirdParty: 91, usedPercentWeeklyThirdParty: 63)),
            account("c1", .claude),
            account("x1", .codex),
        ]
        let display = QuotaSnapshot.Display(providerOrder: [.codex, .claude, .antigravity])
        let rows = QuotaPresentation.displayedAccounts(accounts, display: display)
        XCTAssertEqual(rows.map(\.id), ["x1", "c1", "a1", "a1:claude_gpt"])
        XCTAssertEqual(rows.last?.data?.usedPercent5h, 91)
        XCTAssertEqual(rows.last?.data?.usedPercentWeekly, 63)
        XCTAssertEqual(rows.last?.displayName, "Claude/GPT")
    }

    func testSelectionAndBreakdownToggle() {
        let accounts = [account("a1", .antigravity, data: ProviderData(usedPercent5hThirdParty: 5)), account("c1", .claude)]
        var display = QuotaSnapshot.Display()
        XCTAssertEqual(QuotaPresentation.displayedAccounts(accounts, display: display, includedIds: ["a1:claude_gpt"]).map(\.id),
                       ["a1:claude_gpt"])
        display.showAntigravityModelBreakdown = false
        XCTAssertEqual(QuotaPresentation.displayedAccounts(accounts, display: display).map(\.id), ["c1", "a1"])
    }
}

final class QuotaTimelineTests: XCTestCase {
    func testEntriesTickAndZeroWindowsAtReset() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = 1_000_000 + 20 * 60 + 30 // 20.5 minutes from now: not on a tick
        let row = DisplayedAccount(id: "c", provider: .claude, displayName: "Claude", symbolName: "s", label: "",
                                   state: .fresh, data: ProviderData(usedPercent5h: 80, resetsAt5h: reset,
                                                                     usedPercentWeekly: 40, resetsAtWeekly: 9_999_999),
                                   asOf: 1)
        let content = QuotaWidgetContent(rows: [row], metric: .used, selection: .init())
        let entries = QuotaTimelineBuilder.entries(for: .ready(content), now: now)

        // now + 12 five-minute ticks within the hour + the reset itself.
        XCTAssertEqual(entries.count, 14)
        XCTAssertEqual(entries.first?.date, now)
        XCTAssertTrue(entries.contains { Int($0.date.timeIntervalSince1970) == reset })
        func pct(at index: Int) -> Double? {
            guard case .ready(let c) = entries[index].state else { return nil }
            return c.rows[0].data?.usedPercent5h
        }
        let resetIndex = try XCTUnwrap(entries.firstIndex { Int($0.date.timeIntervalSince1970) == reset })
        XCTAssertEqual(pct(at: resetIndex - 1), 80)
        XCTAssertEqual(pct(at: resetIndex), 0)
        XCTAssertEqual(pct(at: entries.count - 1), 0)
        guard case .ready(let last) = entries.last!.state else { return XCTFail() }
        XCTAssertEqual(last.rows[0].data?.usedPercentWeekly, 40) // weekly reset is far away
    }

    func testNonReadyStatesProduceOneEntry() {
        XCTAssertEqual(QuotaTimelineBuilder.entries(for: .notRunning).count, 1)
        XCTAssertEqual(QuotaTimelineBuilder.state(from: .appNotRunning), .notRunning)
    }

    func testPerAccountMetricSelection() {
        let selection = QuotaSnapshot.NativeWidget(visibleMetrics: [.fiveHour, .weekly], accountMetrics: ["c": [.weekly]])
        let content = QuotaWidgetContent(rows: [], metric: .remaining, selection: selection)
        let row = DisplayedAccount(id: "c", provider: .claude, displayName: "", symbolName: "", label: "",
                                   state: .fresh, data: nil, asOf: nil)
        XCTAssertEqual(content.metrics(for: row), [.weekly])
    }
}

final class QuotaSnapshotTests: XCTestCase {
    func testRoundTripAndHookCompatibleKeys() throws {
        let snapshot = QuotaSnapshot(pid: 42, statuslineShowOtherAgents: false,
                                     display: .init(percentageMetric: .remaining),
                                     nativeWidget: .init(includedAccountIds: ["c1"]),
                                     accounts: [.init(id: "c1", provider: .claude, label: "P", state: .fresh,
                                                      data: ProviderData(usedPercent5h: 55), asOf: 7)])
        let data = try snapshot.encoded()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Keys the Python hooks read.
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["pid"] as? Int, 42)
        XCTAssertEqual(obj["statusline_show_other_agents"] as? Bool, false)
        let account = try XCTUnwrap((obj["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(account["provider"] as? String, "claude")
        XCTAssertEqual((account["data"] as? [String: Any])?["used_percent_5h"] as? Double, 55)

        XCTAssertEqual(try JSONDecoder().decode(QuotaSnapshot.self, from: data), snapshot)
    }

    func testOlderSnapshotWithoutNewFieldsStillReads() throws {
        let old = #"{"v":1,"pid":1,"statusline_show_other_agents":true,"accounts":[{"provider":"codex","state":"fresh","data":{"used_percent_5h":2}}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try old.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .snapshot(let s) = QuotaSnapshot.read(from: url) else { return XCTFail("not read") }
        XCTAssertEqual(s.accounts.first?.id, "codex")
        XCTAssertEqual(s.display, .init())
        XCTAssertEqual(s.nativeWidget, .init())
        XCTAssertEqual(QuotaSnapshot.read(from: url.appendingPathExtension("missing")), .appNotRunning)
    }
}

@MainActor
final class WidgetReloaderTests: XCTestCase {
    func testLeadingThenCoalescedTrailingReload() {
        var reloads = 0
        let reloader = WidgetReloader(minInterval: 0.2) { reloads += 1 }
        reloader.snapshotChanged()          // leading: immediate
        reloader.snapshotChanged()          // within interval: scheduled
        reloader.snapshotChanged()          // coalesced into the same trailing reload
        XCTAssertEqual(reloads, 1)
        let done = expectation(description: "trailing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(reloads, 2)
    }
}
