import CoreServices
import Foundation

/// Reads Codex quota from the CLI's own session logs, so no network call or
/// token is needed while Codex is in use. Codex appends a `token_count` event
/// with `rate_limits` to `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// after each turn. The tree is watched with file-level FSEvents (coalesced,
/// no polling), so any rollout that changes - including a resumed session
/// filed under an old date - is read. Readings carry their event time and the
/// store keeps the newest, so the order files are read in never matters.
final class CodexLogReader {
    /// How much of a log to scan from the end.
    static let tailBytes = 256 * 1024
    /// Most recently modified logs checked at startup: the newest-modified
    /// file may be a fresh session with no quota event yet.
    static let startupCandidates = 5

    private let configDir: String
    private let onReading: (LocalReading) -> Void
    private let queue = DispatchQueue(label: "com.quotapeek.codexlog", qos: .utility)
    private var stream: FSEventStreamRef?
    private var contextBox: Unmanaged<CodexLogReader>?
    /// Per-file (size, mtime) already parsed, so unchanged files are skipped.
    /// Only touched on `queue`.
    private var parsed: [String: (size: UInt64, mtime: Date)] = [:]

    var sessionsDirectory: URL { URL(fileURLWithPath: configDir).appendingPathComponent("sessions", isDirectory: true) }

    /// `configDir` is the canonical Codex home (e.g. `~/.codex`).
    init(configDir: String, onReading: @escaping (LocalReading) -> Void) {
        self.configDir = configDir
        self.onReading = onReading
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        let dir = sessionsDirectory.path
        queue.async { self.scanRecent() }
        guard FileManager.default.fileExists(atPath: dir) else {
            ErrorLog.info("codex log: \(dir) does not exist yet; reading on next launch")
            return
        }
        // The stream holds a retained reference, released in stop(), so the
        // callback can never outlive the reader.
        let box = Unmanaged.passRetained(self)
        contextBox = box
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let reader = Unmanaged<CodexLogReader>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            reader.scan(paths: Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [dir] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0, flags) else {
            box.release()
            contextBox = nil
            ErrorLog.warning("codex log: could not watch \(dir)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        contextBox?.release()
        contextBox = nil
    }

    /// Startup: the few most recently modified logs anywhere in the tree.
    private func scanRecent() {
        for file in Self.recentRollouts(in: sessionsDirectory, limit: Self.startupCandidates) {
            read(file)
        }
    }

    /// FSEvents: only the rollout files that changed.
    private func scan(paths: [String]) {
        for path in Set(paths) where path.hasSuffix(".jsonl") && path.contains("/rollout-") {
            let url = URL(fileURLWithPath: path)
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            guard let values = try? url.resourceValues(forKeys: keys), let mtime = values.contentModificationDate else { continue }
            read((path, UInt64(values.fileSize ?? 0), mtime))
        }
    }

    private func read(_ file: (path: String, size: UInt64, mtime: Date)) {
        if let seen = parsed[file.path], seen.size == file.size, seen.mtime == file.mtime { return }
        parsed[file.path] = (file.size, file.mtime)
        if parsed.count > 64 { parsed.removeAll(keepingCapacity: true) }
        guard let (data, observedMs) = Self.latestRateLimits(inFile: file.path) else { return }
        let fallbackMs = Int64(file.mtime.timeIntervalSince1970 * 1000)
        onReading(LocalReading(provider: .codex, configDir: configDir, observedAtMs: observedMs ?? fallbackMs,
                               source: .codexLog, data: data))
    }

    /// The `limit` most recently modified rollout logs in the whole tree.
    static func recentRollouts(in sessions: URL, limit: Int) -> [(path: String, size: UInt64, mtime: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var files: [(path: String, size: UInt64, mtime: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let mtime = values.contentModificationDate else { continue }
            files.append((url.path, UInt64(values.fileSize ?? 0), mtime))
        }
        return Array(files.sorted { $0.mtime > $1.mtime }.prefix(limit))
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
