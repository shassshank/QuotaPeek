import AppKit
import Darwin
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isAnotherInstanceRunning() else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "AI Usage")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store))

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

    private func isAnotherInstanceRunning() -> Bool {
        let currentPID = getpid()
        let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent

        return NSWorkspace.shared.runningApplications.contains { application in
            guard application.processIdentifier != currentPID else { return false }
            return application.executableURL?.lastPathComponent == executableName
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
