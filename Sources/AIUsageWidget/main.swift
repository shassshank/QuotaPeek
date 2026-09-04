import AppKit
import Darwin
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PopoverLayout {
        static let contentSize = NSSize(width: 280, height: 420)
    }

    private let instanceLock: SingleInstanceLock
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = UsageStore()
    private let claudeCollector = ClaudeUsageCollector()
    private let antigravityCollector = AntigravityUsageCollector()
    private var claudeTimer: Timer?
    private var antigravityTimer: Timer?

    /// Every provider's own API has its own quota just for us checking usage, so this stays
    /// well spaced out (default 5 min) rather than syncing on the same cadence as the local
    /// cache-file poll.
    private let claudePollInterval: TimeInterval = 300
    private let antigravityPollInterval: TimeInterval = 300

    fileprivate init(instanceLock: SingleInstanceLock) {
        self.instanceLock = instanceLock
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "AI Usage")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hostingController = NSHostingController(rootView: PopoverView(store: store))
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.preferredContentSize = PopoverLayout.contentSize

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hostingController
        popover.contentSize = PopoverLayout.contentSize

        store.start()
        startClaudePolling()
        startAntigravityPolling()
    }

    private func startClaudePolling() {
        refreshClaudeUsage()
        claudeTimer = Timer.scheduledTimer(withTimeInterval: claudePollInterval, repeats: true) { [weak self] _ in
            self?.refreshClaudeUsage()
        }
    }

    private func refreshClaudeUsage() {
        Task {
            await claudeCollector.refreshCache()
            store.reload()
        }
    }

    private func startAntigravityPolling() {
        refreshAntigravityUsage()
        antigravityTimer = Timer.scheduledTimer(withTimeInterval: antigravityPollInterval, repeats: true) { [weak self] _ in
            self?.refreshAntigravityUsage()
        }
    }

    private func refreshAntigravityUsage() {
        Task {
            await antigravityCollector.refreshCache()
            store.reload()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.reload()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

}

private final class SingleInstanceLock {
    private enum LockAttempt {
        case acquired(SingleInstanceLock)
        case held
        case unavailable
    }

    private var fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire() -> SingleInstanceLock? {
        for directory in lockDirectories() {
            switch acquire(in: directory) {
            case .acquired(let lock):
                return lock
            case .held:
                return nil
            case .unavailable:
                continue
            }
        }

        return nil
    }

    private static func acquire(in directory: URL) -> LockAttempt {
        let lockURL = directory.appendingPathComponent("app.lock")

        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .unavailable
        }

        let fd = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return .unavailable }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return .held
        }

        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }

        return .acquired(SingleInstanceLock(fileDescriptor: fd))
    }

    private static func lockDirectories() -> [URL] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AIUsageWidget", isDirectory: true)
        let temp = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("AIUsageWidget-\(getuid())", isDirectory: true)

        return [appSupport, temp]
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

guard let instanceLock = SingleInstanceLock.acquire() else {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(instanceLock: instanceLock)
app.delegate = delegate
app.run()
