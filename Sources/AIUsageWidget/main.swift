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
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    fileprivate init(instanceLock: SingleInstanceLock) {
        self.instanceLock = instanceLock
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        updateStatusItem()

        store.$providers
            .combineLatest(store.$isDaemonReachable, store.$config, store.$isCollectionPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        displayPrefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)

        let rootView = PopoverView(
            store: store,
            displayPrefs: displayPrefs,
            openSettings: { [weak self] in self?.openSettings() },
            closePopover: { [weak self] in self?.popover.performClose(nil) }
        )
        let hostingController = NSHostingController(rootView: rootView)
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
            Task { @MainActor [weak self] in
                self?.popover.contentSize = newSize
            }
        }

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
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let mode = displayPrefs.menuBarMode
        let metric = displayPrefs.percentageMetric
        let isWarning = store.isStaleOrFailing

        if isWarning {
            button.setAccessibilityLabel("AI Usage: Service warning")
            button.setAccessibilityValue("Service unreachable or provider error")

            switch mode {
            case .iconOnly:
                button.image = warningImage()
                button.title = ""
            case .percentageText:
                button.image = warningImage()
                button.imagePosition = .imageLeading
                button.title = " !"
            case .coloredDots:
                let providers = displayPrefs.providerOrder
                    .filter { store.isProviderEnabled($0) }
                    .map { ($0, store.providers[$0]) }
                button.image = displayPrefs.generateDotsImage(providers: providers, isStaleOrFailing: true)
                button.title = ""
            }
            return
        }

        let maxUsage = store.highestUsagePercent ?? 0.0
        let displayVal = displayPrefs.displayPercent(forUsedPercent: maxUsage)

        let accessibilityDesc = "AI Usage: \(Int(displayVal))% \(metric.displayName.lowercased())"
        button.setAccessibilityLabel("AI Usage")
        button.setAccessibilityValue(accessibilityDesc)

        switch mode {
        case .iconOnly:
            let image = gaugeImage(forPercent: displayVal, accessibilityDesc: accessibilityDesc)
            button.image = image
            button.title = ""
        case .percentageText:
            let image = gaugeImage(forPercent: displayVal, accessibilityDesc: accessibilityDesc)
            button.image = image
            button.imagePosition = .imageLeading
            button.title = " \(Int(displayVal))%"
        case .coloredDots:
            let providers = displayPrefs.providerOrder
                .filter { store.isProviderEnabled($0) }
                .map { ($0, store.providers[$0]) }
            button.image = displayPrefs.generateDotsImage(providers: providers, isStaleOrFailing: false)
            button.title = ""
        }
    }

    private func warningImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        if let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "AI Usage: Service warning")?
            .withSymbolConfiguration(config) {
            image.isTemplate = false
            return image
        } else {
            let fallback = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "AI Usage: Service warning")
            fallback?.isTemplate = true
            return fallback
        }
    }

    private func gaugeImage(forPercent percent: Double, accessibilityDesc: String) -> NSImage? {
        let symbolName: String
        switch percent {
        case ..<16.5:
            symbolName = "gauge.with.dots.needle.0percent"
        case 16.5..<41.5:
            symbolName = "gauge.with.dots.needle.33percent"
        case 41.5..<58.5:
            symbolName = "gauge.with.dots.needle.50percent"
        case 58.5..<83.5:
            symbolName = "gauge.with.dots.needle.67percent"
        default:
            symbolName = "gauge.with.dots.needle.100percent"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDesc)
        image?.isTemplate = true
        return image
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
