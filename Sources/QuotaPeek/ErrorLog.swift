import QuotaPeekCore
import Foundation
import os

/// Diagnostics trail. Everything goes to the unified log (subsystem
/// `com.quotapeek`, view with `log show --predicate 'subsystem == "com.quotapeek"'`).
/// Notices, warnings and errors are also appended to a small capped `errors.log` in
/// Application Support so there is a durable trail to read or attach to a bug
/// report. Nothing is kept in memory; secrets are redacted before writing.
enum ErrorLog {
    enum Level: String { case info, notice, warning, error }

    static let maxFileBytes = 256 * 1024

    private static let logger = Logger(subsystem: "com.quotapeek", category: "app")
    private static let queue = DispatchQueue(label: "com.quotapeek.errorlog", qos: .utility)

    static var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("errors.log") }

    /// Tests exercise error paths on purpose; keep them out of the user's errors.log.
    private static let isRunningTests = NSClassFromString("XCTestCase") != nil

    static func info(_ message: String) { log(.info, message) }
    static func notice(_ message: String) { log(.notice, message) }
    static func warning(_ message: String) { log(.warning, message) }
    static func error(_ message: String) { log(.error, message) }

    static func log(_ level: Level, _ message: String) {
        let text = redact(message)
        switch level {
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        guard level != .info, !isRunningTests else { return }
        let line = "\(timestampFormatter.string(from: Date())) \(level.rawValue.uppercased()) \(text)\n"
        queue.async { append(line, to: fileURL) }
    }

    /// Last `limit` lines of the durable log (current file only), newest last.
    static func recentLines(limit: Int = 200) -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit).map(String.init))
    }

    static func append(_ line: String, to url: URL, maxBytes: Int = maxFileBytes) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size >= maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    private static let redactions: [(NSRegularExpression, String)] = [
        (#"sk-ant-[A-Za-z0-9_\-]+"#, "sk-ant-<redacted>"),
        (#"(?i)bearer\s+[A-Za-z0-9._\-]+"#, "Bearer <redacted>"),
        (#"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#, "<jwt>"),
        (#"(?i)("?(access|refresh|id)_?token"?\s*[:=]\s*"?)[^"\s,}]+"#, "$1<redacted>"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    static func redact(_ text: String) -> String {
        var out = text
        for (regex, template) in redactions {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

enum AppPaths {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaPeek", isDirectory: true)
    }

    /// Unix socket the statusline hooks send readings to. `sun_path` holds at
    /// most 103 bytes, so very long home paths fall back to /tmp; the hooks
    /// apply the same rule.
    static var socketPath: String {
        let preferred = supportDirectory.appendingPathComponent("qp.sock").path
        if preferred.utf8.count <= 103 { return preferred }
        return "/tmp/quotapeek-\(getuid()).sock"
    }
}
