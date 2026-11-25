import Darwin
import Foundation

/// Versions before 2.0 ran a separate background daemon (`quotapeekd`). The
/// app does its job now, so on the first launch after an upgrade - including
/// a DMG upgrade that never runs install.sh - the daemon's LaunchAgent is
/// stopped and removed together with the files only it used. config.json is
/// kept: the app reads the same file.
enum LegacyDaemon {
    static let label = "com.quotapeek.daemon"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Daemon-only files in the support folder. The OAuth caches hold tokens,
    /// so they should not outlive the daemon.
    static func leftoverFiles(in support: URL) -> [URL] {
        var names = ["auth-token", "samples.json", "daemon.log", "daemon.log.1", "antigravity-oauth-cache.json",
                     "cli-workdir", "bin/quotapeekd"]
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        names += contents.filter { $0.hasPrefix("oauth-") && $0.hasSuffix(".json") }
        return names.map { support.appendingPathComponent($0) }
    }

    static func retireIfInstalled() {
        let fm = FileManager.default
        let support = AppPaths.supportDirectory
        let leftovers = leftoverFiles(in: support).filter { fm.fileExists(atPath: $0.path) }
        guard fm.fileExists(atPath: plistURL.path) || !leftovers.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Not loaded is fine: bootout just fails.
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? fm.removeItem(at: plistURL)
            for url in leftoverFiles(in: support) where fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
            ErrorLog.notice("retired the old background daemon and its files")
        }
    }
}
