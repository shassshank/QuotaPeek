import AppKit
import CoreGraphics
import SwiftUI

/// A non-activating panel that hosts one `WidgetPanelView` instance as an always-visible
/// desktop widget. Independent from the menu bar status item / popover — any number of
/// these can be shown at once, one per `WidgetConfiguration`.
///
/// Sits just above the desktop-icons layer (like a real macOS desktop widget), not
/// `.floating`: it stays behind normal app windows instead of covering them.
/// `.stationary` keeps it pinned to wherever it was placed instead of chasing the user
/// across Space switches/Exposé the way a floating panel would.
@MainActor
final class DesktopWidgetPanel: NSPanel {
    private static let initialSize = NSSize(width: 260, height: 200)

    let configurationId: UUID

    init(store: UsageStore, displayPrefs: DisplayPreferences, configuration: WidgetConfiguration, placementIndex: Int) {
        self.configurationId = configuration.id
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

        let rootView = WidgetPanelView(store: store, displayPrefs: displayPrefs, configuration: configuration)
        let hostingView = NSHostingView(rootView: rootView)
        contentView = hostingView

        let autosaveName = "DesktopWidgetPanel-\(configuration.id.uuidString)"
        let hadSavedFrame = setFrameUsingName(autosaveName)
        setFrameAutosaveName(autosaveName)

        // If there's no saved frame yet, stagger new widgets down/left from the top-right
        // of the main screen so they don't stack exactly on top of each other.
        if !hadSavedFrame, let screen = NSScreen.main {
            let stride: CGFloat = 24
            let offset = CGFloat(placementIndex) * (Self.initialSize.height + stride)
            let x = screen.visibleFrame.maxX - Self.initialSize.width - stride
            let y = screen.visibleFrame.maxY - Self.initialSize.height - stride - offset
            setFrameOrigin(NSPoint(x: x, y: max(y, screen.visibleFrame.minY)))
        }
    }

    /// Re-renders this panel's content for an updated configuration (style/scope/visible
    /// metrics may have changed) without recreating the window itself.
    func update(configuration: WidgetConfiguration, store: UsageStore, displayPrefs: DisplayPreferences) {
        let rootView = WidgetPanelView(store: store, displayPrefs: displayPrefs, configuration: configuration)
        (contentView as? NSHostingView<WidgetPanelView>)?.rootView = rootView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
