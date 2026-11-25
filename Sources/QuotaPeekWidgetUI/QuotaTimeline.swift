import Foundation
import QuotaPeekCore
import WidgetKit

/// What one widget entry shows.
public struct QuotaWidgetContent: Equatable, Sendable {
    public var rows: [DisplayedAccount]
    public var metric: PercentageMetric
    public var selection: QuotaSnapshot.NativeWidget

    public init(rows: [DisplayedAccount], metric: PercentageMetric, selection: QuotaSnapshot.NativeWidget) {
        self.rows = rows
        self.metric = metric
        self.selection = selection
    }

    public func metrics(for row: DisplayedAccount) -> Set<WidgetMetricKind> {
        // The Claude/GPT pool row follows its own id first, then its account's.
        selection.accountMetrics[row.id].map(Set.init) ?? selection.metrics(for: row.id)
    }
}

public enum QuotaWidgetState: Equatable, Sendable {
    case ready(QuotaWidgetContent)
    case notRunning
    case unreadable(String)
}

public struct QuotaEntry: TimelineEntry, Equatable, Sendable {
    public var date: Date
    public var state: QuotaWidgetState

    public init(date: Date, state: QuotaWidgetState) {
        self.date = date
        self.state = state
    }
}

/// Pure timeline construction, kept separate from WidgetKit glue so it can be tested.
public enum QuotaTimelineBuilder {
    /// Countdowns are rendered as text ("2h 5m"), so entries are spaced this
    /// far apart to keep them current. Pre-scheduled entries cost no reload
    /// budget; Apple asks for entries at least ~5 minutes apart.
    public static let tickInterval: TimeInterval = 5 * 60
    /// How far ahead entries are generated.
    public static let horizon: TimeInterval = 60 * 60
    /// The widget asks for a fresh timeline this often even without a push
    /// from the app, so a missed reload only delays numbers.
    public static let refreshAfter: TimeInterval = 15 * 60

    public static func state(from result: QuotaSnapshot.ReadResult) -> QuotaWidgetState {
        switch result {
        case .snapshot(let snapshot):
            return .ready(QuotaWidgetContent(rows: QuotaPresentation.nativeWidgetAccounts(snapshot),
                                             metric: snapshot.display.percentageMetric,
                                             selection: snapshot.nativeWidget))
        case .appNotRunning:
            return .notRunning
        case .unreadable(let why):
            return .unreadable(why)
        }
    }

    /// Entries every `tickInterval` plus one at each reset within `horizon`;
    /// at and after a reset that window shows 0% (a new window starts empty).
    public static func entries(for state: QuotaWidgetState, now: Date = Date()) -> [QuotaEntry] {
        guard case .ready(let content) = state else { return [QuotaEntry(date: now, state: state)] }
        var dates: Set<Date> = [now]
        var tick = now.addingTimeInterval(tickInterval)
        while tick <= now.addingTimeInterval(horizon) {
            dates.insert(tick)
            tick = tick.addingTimeInterval(tickInterval)
        }
        for row in content.rows {
            for reset in row.data?.upcomingResets(after: now) ?? [] {
                let date = Date(timeIntervalSince1970: TimeInterval(reset))
                if date > now, date <= now.addingTimeInterval(horizon) { dates.insert(date) }
            }
        }
        return dates.sorted().map { date in
            var shifted = content
            shifted.rows = content.rows.map { row in
                var r = row
                r.data = row.data?.afterResets(through: date)
                return r
            }
            return QuotaEntry(date: date, state: .ready(shifted))
        }
    }

    public static func timeline(for state: QuotaWidgetState, now: Date = Date()) -> Timeline<QuotaEntry> {
        Timeline(entries: entries(for: state, now: now), policy: .after(now.addingTimeInterval(refreshAfter)))
    }
}

/// Feeds every QuotaPeek widget kind from `snapshot.json`.
public struct QuotaTimelineProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), state: .ready(.sample))
    }

    public func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        // The gallery preview shows sample numbers when there is nothing real yet.
        let state = QuotaTimelineBuilder.state(from: QuotaSnapshot.read())
        if context.isPreview, case .ready(let content) = state, content.rows.isEmpty == false {
            completion(QuotaEntry(date: Date(), state: state))
        } else if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(QuotaEntry(date: Date(), state: state))
        }
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        completion(QuotaTimelineBuilder.timeline(for: QuotaTimelineBuilder.state(from: QuotaSnapshot.read())))
    }
}

extension QuotaWidgetContent {
    /// Representative numbers for placeholders, the gallery and rendered previews.
    public static var sample: QuotaWidgetContent {
        let now = Int(Date().timeIntervalSince1970)
        func row(_ id: String, _ p: Provider, name: String? = nil, symbol: String? = nil,
                 _ h5: Double?, _ wk: Double?, state: AccountTrustState = .fresh) -> DisplayedAccount {
            DisplayedAccount(id: id, provider: p, displayName: name ?? p.displayName, symbolName: symbol ?? p.symbolName,
                             label: "Personal", state: state,
                             data: ProviderData(usedPercent5h: h5, resetsAt5h: now + 2 * 3600 + 900,
                                                usedPercentWeekly: wk, resetsAtWeekly: now + 3 * 86400 + 5 * 3600),
                             asOf: Int64(now - 40))
        }
        return QuotaWidgetContent(rows: [
            row("claude", .claude, 58, 44),
            row("codex", .codex, 12, 36),
            row("antigravity", .antigravity, 0, 7),
            row("antigravity:claude_gpt", .antigravity, name: "Claude/GPT", symbol: "sparkles", 91, 63),
        ], metric: .used, selection: QuotaSnapshot.NativeWidget())
    }
}
