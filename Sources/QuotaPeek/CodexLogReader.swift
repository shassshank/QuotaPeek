import CoreServices
import Foundation

/// Reads Codex quota from the CLI's own session logs, so no network call or
/// token is needed while Codex is in use. Codex appends a `token_count` event
/// with `rate_limits` to `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// after each turn; this watches that tree with FSEvents (coalesced, no
/// polling) and reports the newest reading.
final class CodexLogReader {
    /// How much of the newest log to scan from the end.
    static let tailBytes = 256 * 1024
    /// Day directories considered; a session started yesterday may still be the
    /// one being appended to.
    static let recentDayDirectories = 3

    private let configDir: String
    private let onReading: (LocalReading) -> Void
    private let queue = DispatchQueue(label: "com.quotapeek.codexlog", qos: .utility)
    private var stream: FSEventStreamRef?
    private var lastFile: (path: String, size: UInt64, mtime: Date)?

    var sessionsDirectory: URL { URL(fileURLWithPath: configDir).appendingPathComponent("sessions", isDirectory: true) }

    /// `configDir` is the canonical Codex home (e.g. `~/.codex`).
    init(configDir: String, onReading: @escaping (LocalReading) -> Void) {
        self.configDir = configDir
        self.onReading = onReading
    }

    deinit { stop() }

    func start() {
        queue.async { self.scan() }
        guard stream == nil else { return }
        let dir = sessionsDirectory.path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CodexLogReader>.fromOpaque(info).takeUnretainedValue().scan()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [dir] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
            ErrorLog.warning("codex log: could not watch \(dir)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Runs on `queue`. Skips work when the newest log has not changed.
    private func scan() {
        guard let newest = Self.newestRollout(in: sessionsDirectory) else { return }
        if let last = lastFile, last.path == newest.path, last.size == newest.size, last.mtime == newest.mtime { return }
        lastFile = newest
        guard let (data, observedMs) = Self.latestRateLimits(inFile: newest.path) else { return }
        let fallbackMs = Int64(newest.mtime.timeIntervalSince1970 * 1000)
        onReading(LocalReading(provider: .codex, configDir: configDir, observedAtMs: observedMs ?? fallbackMs,
                               source: .codexLog, data: data))
    }

    /// Newest `rollout-*.jsonl` by modification time across the most recent
    /// day directories, without walking the whole history.
    static func newestRollout(in sessions: URL) -> (path: String, size: UInt64, mtime: Date)? {
        let fm = FileManager.default
        func numericChildren(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { Int($0.lastPathComponent) != nil }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var days: [URL] = []
        outer: for year in numericChildren(sessions) {
            for month in numericChildren(year) {
                for day in numericChildren(month) {
                    days.append(day)
                    if days.count >= recentDayDirectories { break outer }
                }
            }
        }
        var best: (path: String, size: UInt64, mtime: Date)?
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for day in days {
            for file in (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: keys)) ?? []
            where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      let mtime = values.contentModificationDate else { continue }
                if best == nil || mtime > best!.mtime {
                    best = (file.path, UInt64(values.fileSize ?? 0), mtime)
                }
            }
        }
        return best
    }

    /// Scans the file's tail backwards for the last parseable rate-limit event.
    /// A partially written final line simply fails to parse and is skipped.
    static func latestRateLimits(inFile path: String) -> (ProviderData, Int64?)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let tail = try? handle.readToEnd() else { return nil }
        let marker = Data("\"rate_limits\"".utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            if let parsed = LocalQuotaParser.codexRolloutLine(Data(line)) { return parsed }
        }
        return nil
    }
}
