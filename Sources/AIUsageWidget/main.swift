import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PopoverLayout {
        // Seeds the very first show before SwiftUI has measured real content, so the popover
        // never anchors against a stale/zero size. Actual height then tracks content via the
        // preferredContentSize observation below.
        static let initialContentSize = NSSize(width: 280, height: 420)
    }

    private let instanceLock: SingleInstanceLock
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var preferredSizeObservation: NSKeyValueObservation?
    private let store = UsageStore()
    private var settingsWindow: NSWindow?

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

        let hostingController = NSHostingController(rootView: PopoverView(store: store, openSettings: { [weak self] in self?.openSettings() }))
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.preferredContentSize = PopoverLayout.initialContentSize

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hostingController
        popover.contentSize = PopoverLayout.initialContentSize

        // NSHostingController keeps preferredContentSize in sync with SwiftUI's own ideal size
        // (sizingOptions above); mirror it onto the popover so height tracks real content instead
        // of staying pinned to the initial seed size.
        preferredSizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let self, let newSize = change.newValue, newSize.width > 0, newSize.height > 0 else { return }
            self.popover.contentSize = newSize
        }

        store.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Task { await store.reload() }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func openSettings() {
        if popover.isShown {
            popover.performClose(nil)
        }
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AI Usage Widget Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(instanceLock: instanceLock)
    app.delegate = delegate
    app.run()
}
