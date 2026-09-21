import AppKit
import Combine
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PopoverLayout {
        // Seeds the very first show before SwiftUI has measured real content, so the popover
        // never anchors against a stale/zero size. Actual height then tracks content via the
        // preferredContentSize observation below. Both main and PopoverView use 300 to avoid jitter.
        static let initialContentSize = NSSize(width: 300, height: 420)
    }

    private let instanceLock: SingleInstanceLock
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var preferredSizeObservation: NSKeyValueObservation?
    private let store = UsageStore()
    private let displayPrefs = DisplayPreferences.shared
    private var settingsWindow: NSWindow?
    private var desktopWidgetPanels: [UUID: DesktopWidgetPanel] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var lastRenderState: StatusItemRenderState?

    fileprivate init(instanceLock: SingleInstanceLock) {
        self.instanceLock = instanceLock
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Force NotificationManager's singleton to initialize now, not lazily on
        // first use (which today only happens after the first async reload
        // completes). Its init registers the UNUserNotificationCenter delegate,
        // so touching it here ensures a notification delivered or tapped at
        // launch - before that first reload finishes - isn't missed because the
        // delegate wasn't registered yet.
        _ = NotificationManager.shared

        Self.ensureDaemonLoaded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(handleStatusItemClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateStatusItem()

        store.$accounts
            .combineLatest(store.$isDaemonReachable, store.$config, store.$isCollectionPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        // Debounced: displayPrefs.objectWillChange fires on every mutation of a
        // bound preference, including once per keystroke while typing (e.g. a
        // desktop widget's name). Without coalescing, that would re-run a full
        // status-item re-render and desktop-widget reconciliation pass on every
        // character typed. The debounce collapses a burst of rapid changes into
        // a single pass shortly after they stop, while still applying the final
        // value.
        displayPrefs.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
                self?.updateDesktopWidgetVisibility()
            }
            .store(in: &cancellables)


        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = PopoverLayout.initialContentSize

        // Global keyboard shortcut monitor for Esc (to close popover) and Cmd+, (to open settings)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.keyCode == 53 { // Esc
                self.popover.performClose(nil)
                return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self.openSettings()
                return nil
            }
            return event
        }

        store.start()
        updateDesktopWidgetVisibility()
    }

    /// Reconciles the set of open desktop widget panels against `displayPrefs.widgetConfigurations`,
    /// without touching the menu bar status item or popover. Creates/shows a panel for every
    /// enabled configuration, closes panels for configurations that were disabled or removed.
    private func updateDesktopWidgetVisibility() {
        let configs = displayPrefs.widgetConfigurations
        let enabledConfigs = configs.filter { $0.isEnabled }
        let enabledIds = Set(enabledConfigs.map(\.id))
        let allKnownIds = Set(configs.map(\.id))

        // Close panels whose configuration was disabled or deleted entirely.
        // Also detach the hosted SwiftUI view (mirroring how the popover detaches
        // its content on close) so a hidden/disabled widget's view stops
        // observing the store and re-rendering on every poll tick while off
        // screen; `update(configuration:store:displayPrefs:)` re-attaches it if
        // the widget is re-enabled later.
        for (id, panel) in desktopWidgetPanels where !enabledIds.contains(id) {
            panel.orderOut(nil)
            panel.detachContent()
            if !allKnownIds.contains(id) {
                desktopWidgetPanels.removeValue(forKey: id)
            }
        }

        // Create/show panels for every enabled configuration.
        for (index, config) in enabledConfigs.enumerated() {
            if let existing = desktopWidgetPanels[config.id] {
                existing.update(configuration: config, store: store, displayPrefs: displayPrefs)
                existing.orderFrontRegardless()
            } else {
                let panel = DesktopWidgetPanel(store: store, displayPrefs: displayPrefs, configuration: config, placementIndex: index)
                desktopWidgetPanels[config.id] = panel
                panel.orderFrontRegardless()
            }
        }

        store.setWidgetVisible(!enabledConfigs.isEmpty)
    }

    private struct StatusItemRenderState: Equatable {
        enum ImageKind: Equatable {
            case warning
            case noData(accessibilityDesc: String)
            case gauge(accessibilityDesc: String)
            case dots([DisplayPreferences.DotColor])
        }

        var imageKind: ImageKind
        var title: String
        var imagePosition: NSControl.ImagePosition
        var accessibilityLabel: String
        var accessibilityValue: String
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let mode = displayPrefs.menuBarMode
        let metric = displayPrefs.percentageMetric
        let isWarning = store.isStaleOrFailing

        let enabledAccounts = displayPrefs.providerOrder.flatMap { provider in
            store.accounts.filter { $0.provider == provider && store.isAccountEnabled($0) }
        }

        let targetState: StatusItemRenderState

        if isWarning {
            let label = "QuotaPeek: Service warning"
            let value = "Service unreachable or provider error"

            switch mode {
            case .iconOnly:
                targetState = StatusItemRenderState(
                    imageKind: .warning,
                    title: "",
                    imagePosition: .imageLeft,
                    accessibilityLabel: label,
                    accessibilityValue: value
                )
            case .coloredDots:
                let dotColors = enabledAccounts.isEmpty
                    ? [.gray]
                    : enabledAccounts.map { displayPrefs.dotColor(for: $0, isDaemonReachable: store.isDaemonReachable) }
                targetState = StatusItemRenderState(
                    imageKind: .dots(dotColors),
                    title: "",
                    imagePosition: .imageLeft,
                    accessibilityLabel: label,
                    accessibilityValue: value
                )
            }
        } else if let maxUsage = store.highestUsagePercent {
            let displayVal = displayPrefs.displayPercent(forUsedPercent: maxUsage)
            let accessibilityDesc = "QuotaPeek: \(Int(displayVal))% \(metric.displayName.lowercased())"
            let label = "QuotaPeek"
            let value = accessibilityDesc

            switch mode {
            case .iconOnly:
                targetState = StatusItemRenderState(
                    imageKind: .gauge(accessibilityDesc: accessibilityDesc),
                    title: "",
                    imagePosition: .imageLeft,
                    accessibilityLabel: label,
                    accessibilityValue: value
                )
            case .coloredDots:
                let dotColors = enabledAccounts.isEmpty
                    ? [.gray]
                    : enabledAccounts.map { displayPrefs.dotColor(for: $0, isDaemonReachable: store.isDaemonReachable) }
                targetState = StatusItemRenderState(
                    imageKind: .dots(dotColors),
                    title: "",
                    imagePosition: .imageLeft,
                    accessibilityLabel: label,
                    accessibilityValue: value
                )
            }
        } else {
            let accessibilityDesc = "QuotaPeek: No recent data"
            let label = "QuotaPeek"
            let value = accessibilityDesc

            switch mode {
            case .iconOnly:
                targetState = StatusItemRenderState(
                    imageKind: .noData(accessibilityDesc: accessibilityDesc),
                    title: "",
                    imagePosition: .imageLeft,
                    accessibilityLabel: label,
                    accessibilityValue: value
                )
            case .coloredDots:
                let dotColors = enabledAccounts.isEmpty
                    ? [.gray]
                    : enabledAccounts.map { displayPrefs.dotColor(for: $0, isDaemonReachable: store.isDaemonReachable) }
                targetState = StatusItemRenderState(
                    imageKind: .dots(dotColors),
                    title: "",
                    imagePosition: .imageLeft,
                    accessibilityLabel: label,
                    accessibilityValue: value
                )
            }
        }

        if targetState == lastRenderState {
            return
        }
        lastRenderState = targetState

        button.setAccessibilityLabel(targetState.accessibilityLabel)
        button.setAccessibilityValue(targetState.accessibilityValue)

        if button.imagePosition != targetState.imagePosition {
            button.imagePosition = targetState.imagePosition
        }
        if button.title != targetState.title {
            button.title = targetState.title
        }

        switch targetState.imageKind {
        case .warning:
            button.image = warningImage()
        case .noData(let desc):
            button.image = logoImage(accessibilityDesc: desc)
        case .gauge(let desc):
            button.image = logoImage(accessibilityDesc: desc)
        case .dots:
            button.image = displayPrefs.generateDotsImage(accounts: enabledAccounts, isDaemonReachable: store.isDaemonReachable)
        }
    }

    private static let cachedLogoImage: NSImage? = {
        // Bundled into Contents/Resources by Scripts/build-app-bundle.sh, next
        // to AppIcon.icns. Not available when running an unpackaged dev build
        // (e.g. `swift run`) - logoImage(accessibilityDesc:) handles that nil.
        guard let image = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    private func logoImage(accessibilityDesc: String) -> NSImage? {
        guard let image = Self.cachedLogoImage?.copy() as? NSImage else { return nil }
        image.accessibilityDescription = accessibilityDesc
        return image
    }

    private func warningImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        if let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "QuotaPeek: Service warning")?
            .withSymbolConfiguration(config) {
            image.isTemplate = false
            return image
        } else {
            let fallback = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "QuotaPeek: Service warning")
            fallback?.isTemplate = true
            return fallback
        }
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsMenuAction), keyEquivalent: ",")
            settingsItem.target = self
            menu.addItem(settingsItem)

            let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshMenuAction), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)

            let pauseItem = NSMenuItem(title: store.isCollectionPaused ? "Resume Collection" : "Pause Collection", action: #selector(togglePauseMenuAction), keyEquivalent: "")
            pauseItem.target = self
            menu.addItem(pauseItem)

            menu.addItem(.separator())

            let quitItem = NSMenuItem(title: "Quit", action: #selector(quitMenuAction), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.menu = nil
            }
        } else {
            togglePopover()
        }
    }

    @objc private func openSettingsMenuAction() {
        openSettings()
    }

    @objc private func refreshMenuAction() {
        Task { await store.refresh() }
    }

    @objc private func togglePauseMenuAction() {
        let target = !store.isCollectionPaused
        Task { _ = await store.setCollectionPaused(target) }
    }

    @objc private func quitMenuAction() {
        AppDelegate.quitAndStopDaemon()
    }

    /// Shells out to (re)load the daemon LaunchAgent at app launch.
    ///
    /// `quitAndStopDaemon()` below deliberately unloads the daemon without `-w`
    /// so Quit only stops it for the current session, not permanently - but
    /// launchd doesn't reload an unloaded-without-`-w` job on its own until the
    /// next login/boot. Without this, relaunching the app after using Quit (e.g.
    /// double-clicking it in Applications rather than logging out and back in)
    /// leaves the daemon gone: the UI comes back but every request to it fails
    /// with "Service unreachable" and no accounts ever populate.
    ///
    /// `launchctl load` on an already-loaded job just errors harmlessly (exit
    /// status non-zero, no effect on the running daemon), so this is safe to
    /// call unconditionally on every launch. Fire-and-forget off the main
    /// thread so a slow/hung launchctl can't delay the rest of startup.
    static func ensureDaemonLoaded() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.quotapeek.daemon.plist")
            .path
        guard FileManager.default.fileExists(atPath: plistPath) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", plistPath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Ignore - if this fails, the daemon was likely already
                // running and store.start()'s polling will confirm reachability.
            }
        }
    }

    /// Shells out to unload the LaunchAgent daemon plist and terminates app (Task C8)
    ///
    /// Deliberately `unload` without `-w`: `-w` persists a "Disabled" override
    /// for the job, which would stop it from auto-starting again at the next
    /// login too, not just for the rest of this session. Quitting should only
    /// stop the daemon for now — `install.sh --daemon-stop` is the explicit,
    /// persistent version of this if that's what's wanted instead.
    ///
    /// Runs the `launchctl unload` process and waits for it off the main thread
    /// (mirroring the uninstall-script fix in SettingsView.runUninstallScript) so
    /// Quit never blocks the UI. `NSApp.terminate(nil)` is only called once the
    /// unload attempt has finished (or failed to launch), hopped back to the main
    /// thread. There's no existing timeout mechanism elsewhere in this codebase to
    /// model a hard bound on `launchctl unload` after, so this keeps the wait
    /// unbounded but off the main thread; a hang here only delays app exit, it no
    /// longer freezes the UI.
    static func quitAndStopDaemon() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.quotapeek.daemon.plist")
            .path

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", plistPath]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Ignore - proceed to quit regardless of whether the unload succeeded.
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    /// Creates and attaches a fresh popover content view controller, wiring up the
    /// preferredContentSize KVO observation. Called before every popover show so the
    /// SwiftUI view tree only exists while the popover is visible.
    private func attachPopoverContent() {
        let rootView = PopoverView(
            store: store,
            displayPrefs: displayPrefs,
            openSettings: { [weak self] in self?.openSettings() },
            closePopover: { [weak self] in self?.popover.performClose(nil) }
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.preferredContentSize = PopoverLayout.initialContentSize

        popover.contentViewController = hostingController

        // Mirror SwiftUI's ideal size onto the popover so height tracks real content.
        preferredSizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let self, let newSize = change.newValue, newSize.width > 0, newSize.height > 0 else { return }
            Task { @MainActor [weak self] in
                self?.popover.contentSize = newSize
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            attachPopoverContent()
            // setPopoverVisible(true) already triggers an immediate reload via
            // applyPollingCadence(triggerImmediateReload:) - an extra explicit
            // reload() here would just duplicate that call.
            store.setPopoverVisible(true)
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
            window.title = "QuotaPeek Settings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.minSize = NSSize(width: 520, height: 560)
            window.setContentSize(NSSize(width: 560, height: 700))
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        store.setPopoverVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        store.setPopoverVisible(false)
        // Detach the SwiftUI view tree so it stops observing store and doing layout
        // work while the popover is hidden. It will be recreated on next show.
        preferredSizeObservation = nil
        popover.contentViewController = nil
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
            .appendingPathComponent("QuotaPeek", isDirectory: true)
        let temp = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("QuotaPeek-\(getuid())", isDirectory: true)

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
