import AppKit
import CoreGraphics
import SwiftUI

/// A non-activating panel that hosts `WidgetPanelView` as an always-visible desktop
/// widget. Independent from the menu bar status item / popover — both can be shown at
/// the same time.
///
/// Sits at the desktop-icon window level (like a real macOS desktop widget), not
/// `.floating`: it stays behind normal app windows instead of covering them, and
/// `.stationary` keeps it pinned to wherever it was placed instead of chasing the user
/// across Space switches/Exposé the way a floating panel would.
@MainActor
final class DesktopWidgetPanel: NSPanel {
    private static let autosaveName = "DesktopWidgetPanel"
    private static let initialSize = NSSize(width: 260, height: 200)

    init(store: UsageStore, displayPrefs: DisplayPreferences) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let rootView = WidgetPanelView(store: store, displayPrefs: displayPrefs)
        let hostingView = NSHostingView(rootView: rootView)
        contentView = hostingView

        setFrameUsingName(Self.autosaveName)
        setFrameAutosaveName(Self.autosaveName)

        // If there's no saved frame yet, place it near the top-right of the main screen.
        if frame.origin == .zero, let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - Self.initialSize.width - 24
            let y = screen.visibleFrame.maxY - Self.initialSize.height - 24
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
