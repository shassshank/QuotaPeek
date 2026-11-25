import Foundation

/// One quota reading observed on this Mac: pushed by a statusline hook, read
/// from a Codex session log, or fetched from the web by the app itself.
struct LocalReading: Equatable {
    enum Source: String { case hook, codexLog = "codex-log", web }

    var provider: Provider
    /// Canonical config directory for Claude/Codex; empty for Antigravity,
    /// whose CLI has no profile concept the hook could report.
    var configDir: String
    /// Unix milliseconds at which the numbers were observed.
    var observedAtMs: Int64
    var source: Source
    var data: ProviderData

    var key: String { LocalReading.key(provider: provider, configDir: configDir) }

    static func key(provider: Provider, configDir: String) -> String {
        "\(provider.rawValue):\(configDir)"
    }
}

/// Latest reading per (provider, config dir). Newest `observedAtMs` wins, so a
/// late-arriving older reading can never overwrite a newer one. Main-actor
/// only: every source hops to the main queue before applying.
@MainActor
final class QuotaStore {
    private(set) var readings: [String: LocalReading] = [:]

    enum ApplyResult: Equatable {
        /// Not newer than the stored reading; nothing changed.
        case ignored
        /// Newer, same numbers: only the timestamp advanced.
        case timestampOnly
        /// Newer with different numbers (or the first reading for this key).
        case changed
    }

    /// Stores `reading` only if it is newer than what is held for its key.
    @discardableResult
    func apply(_ reading: LocalReading) -> ApplyResult {
        guard let existing = readings[reading.key] else {
            readings[reading.key] = reading
            return .changed
        }
        guard reading.observedAtMs > existing.observedAtMs else { return .ignored }
        readings[reading.key] = reading
        return existing.data == reading.data ? .timestampOnly : .changed
    }

    func reading(provider: Provider, configDir: String) -> LocalReading? {
        readings[LocalReading.key(provider: provider, configDir: configDir)]
    }
}

// MARK: - Parsing

enum LocalQuotaParser {
    /// Datagram schema v1, sent by the statusline hooks:
    /// `{"v":1,"provider":"claude","config_dir":"…","observed_at_ms":…,"rate_limits":{…}}`
    /// `{"v":1,"provider":"antigravity","observed_at_ms":…,"quota":{…}}`
    /// Hooks forward the raw sub-objects so all parsing lives here.
    static func datagram(_ bytes: Data, nowMs: Int64) -> LocalReading? {
        guard let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              (obj["v"] as? Int) == 1,
              let providerRaw = obj["provider"] as? String,
              let provider = Provider(rawValue: providerRaw) else { return nil }
        let observedAtMs = number(obj["observed_at_ms"]).flatMap(int64) ?? nowMs
        let data: ProviderData?
        switch provider {
        case .claude: data = claude(obj)
        case .antigravity: data = antigravity(obj, observedAtSec: Int(observedAtMs / 1000))
        case .codex: data = nil // Codex has no hook; it is read from session logs.
        }
        guard let data else { return nil }
        let configDir = provider == .antigravity ? "" : canonicalConfigDir(obj["config_dir"] as? String, provider: provider)
        return LocalReading(provider: provider, configDir: configDir, observedAtMs: observedAtMs, source: .hook, data: data)
    }

    /// Claude Code statusline payload: `rate_limits.five_hour` / `seven_day`,
    /// each with `used_percentage` (or `used_percent`) and `resets_at`.
    static func claude(_ payload: [String: Any]) -> ProviderData? {
        var data = ProviderData()
        if let limits = payload["rate_limits"] as? [String: Any] {
            if let w = limits["five_hour"] as? [String: Any] {
                data.usedPercent5h = percent(w["used_percentage"]) ?? percent(w["used_percent"])
                data.resetsAt5h = resetTime(w["resets_at"])
            }
            if let w = limits["seven_day"] as? [String: Any] {
                data.usedPercentWeekly = percent(w["used_percentage"]) ?? percent(w["used_percent"])
                data.resetsAtWeekly = resetTime(w["resets_at"])
            }
        }
        return data.usedPercent5h == nil && data.usedPercentWeekly == nil ? nil : data
    }

    /// Antigravity statusline payload: `quota` maps a label to
    /// `{remaining_fraction, reset_time | reset_in_seconds}`. Labels naming
    /// Claude/GPT/3P belong to the shared third-party pool; when several labels
    /// land in one window the highest usage wins.
    static func antigravity(_ payload: [String: Any], observedAtSec: Int) -> ProviderData? {
        guard let quota = payload["quota"] as? [String: Any] else { return nil }
        var data = ProviderData()
        for key in quota.keys.sorted() {
            guard let entry = quota[key] as? [String: Any],
                  let remaining = number(entry["remaining_fraction"]), (0...1).contains(remaining) else { continue }
            let used = ((1 - remaining) * 1000).rounded() / 10
            var reset = resetTime(entry["reset_time"])
            if let seconds = number(entry["reset_in_seconds"]).flatMap(int),
               case let (sum, overflow) = observedAtSec.addingReportingOverflow(seconds), !overflow {
                reset = sum
            }
            let label = key.lowercased()
            let thirdParty = label.contains("claude") || label.contains("gpt") || label.contains("3p")
            let isWeekly = label.contains("week") || label.contains("7d")
            let is5h = label.contains("5h") || label.contains("5 hour")
            func take(_ pct: inout Double?, _ at: inout Int?) {
                if pct == nil || used > pct! { pct = used; at = reset }
            }
            switch (isWeekly, is5h, thirdParty) {
            case (true, _, true): take(&data.usedPercentWeeklyThirdParty, &data.resetsAtWeeklyThirdParty)
            case (true, _, false): take(&data.usedPercentWeekly, &data.resetsAtWeekly)
            case (false, true, true): take(&data.usedPercent5hThirdParty, &data.resetsAt5hThirdParty)
            case (false, true, false): take(&data.usedPercent5h, &data.resetsAt5h)
            default: continue
            }
        }
        if data.usedPercentWeekly == nil, let pct = data.usedPercentWeeklyThirdParty {
            data.usedPercentWeekly = pct
            data.resetsAtWeekly = data.resetsAtWeeklyThirdParty
        }
        if data.usedPercent5h == nil, let pct = data.usedPercent5hThirdParty {
            data.usedPercent5h = pct
            data.resetsAt5h = data.resetsAt5hThirdParty
        }
        return data.usedPercent5h == nil && data.usedPercentWeekly == nil ? nil : data
    }

    /// One line of a Codex rollout log (`~/.codex/sessions/**/rollout-*.jsonl`).
    /// `token_count` events carry `payload.rate_limits.{primary,secondary}` with
    /// `used_percent`, `window_minutes` and `resets_at`. Returns the data and
    /// the event time in Unix ms.
    static func codexRolloutLine(_ line: Data) -> (ProviderData, Int64?)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        if let limitID = limits["limit_id"] as? String, limitID != "codex" { return nil }
        var data = ProviderData()
        for name in ["primary", "secondary"] {
            guard let w = limits[name] as? [String: Any], let pct = percent(w["used_percent"]) else { continue }
            let minutes = number(w["window_minutes"]) ?? (name == "primary" ? 300 : 10080)
            let reset = resetTime(w["resets_at"])
            if minutes <= 6 * 60 {
                data.usedPercent5h = pct
                data.resetsAt5h = reset
            } else if minutes >= 6 * 24 * 60 {
                data.usedPercentWeekly = pct
                data.resetsAtWeekly = reset
            }
        }
        guard data.usedPercent5h != nil || data.usedPercentWeekly != nil else { return nil }
        let observed = (obj["timestamp"] as? String).flatMap(parseISO8601).map { Int64($0.timeIntervalSince1970 * 1000) }
        return (data, observed)
    }

    // MARK: Helpers

    /// Canonical form used to match a hook's config dir against an account's:
    /// empty means the CLI default, `~` is expanded, symlinks resolved,
    /// trailing slashes dropped and Unicode normalized (NFC).
    static func canonicalConfigDir(_ raw: String?, provider: Provider) -> String {
        var path = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            switch provider {
            case .claude: path = "~/.claude"
            case .codex: path = "~/.codex"
            case .antigravity: return ""
            }
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        var out = url.path
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out.precomposedStringWithCanonicalMapping
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            // JSONSerialization boxes booleans as NSNumber too; never treat them as numbers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
            return d
        default:
            return nil
        }
    }

    static func percent(_ value: Any?) -> Double? {
        guard let d = number(value), (0...100).contains(d) else { return nil }
        return d
    }

    /// Unix seconds from a number, numeric string or ISO-8601 string.
    static func resetTime(_ value: Any?) -> Int? {
        if let d = number(value) { return int(d) }
        if let s = value as? String, let date = parseISO8601(s) { return int(date.timeIntervalSince1970) }
        return nil
    }

    /// Integer conversions that return nil instead of trapping on values a
    /// malformed or hostile payload could carry (1e30, ±inf already excluded).
    static func int(_ d: Double) -> Int? {
        guard d.isFinite, d > -9.0e15, d < 9.0e15 else { return nil }
        return Int(d)
    }

    static func int64(_ d: Double) -> Int64? {
        guard d.isFinite, d > -9.0e15, d < 9.0e15 else { return nil }
        return Int64(d)
    }

    static func parseISO8601(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
