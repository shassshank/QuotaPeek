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
        level = Self.windowLevel(for: configuration.layer)
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

        // Brand new widget (never shown/moved before, hence no saved frame): pop up centered
        // on screen, per user preference. Once shown, macOS's frame autosave persists any
        // position the user drags it to under `autosaveName`, so a later disable/re-enable
        // cycle restores that saved position instead of re-centering (setFrameUsingName above
        // already handles that case by returning true and leaving the frame as restored).
        if !hadSavedFrame, let screen = NSScreen.main {
            center()
            // If several brand-new widgets are enabled at once, cascade them slightly so they
            // don't stack exactly on top of one another.
            if placementIndex > 0 {
                let cascadeStep: CGFloat = 32
                let offset = CGFloat(placementIndex) * cascadeStep
                var origin = frame.origin
                origin.x += offset
                origin.y -= offset
                setFrameOrigin(NSPoint(
                    x: min(origin.x, screen.visibleFrame.maxX - Self.initialSize.width),
                    y: max(origin.y, screen.visibleFrame.minY)
                ))
            }
        }
    }

    /// Re-renders this panel's content for an updated configuration (style/scope/visible
    /// metrics may have changed) without recreating the window itself. Also re-attaches
    /// a hosting view if `detachContent()` previously tore it down (e.g. the widget was
    /// disabled and is now being re-enabled).
    func update(configuration: WidgetConfiguration, store: UsageStore, displayPrefs: DisplayPreferences) {
        let rootView = WidgetPanelView(store: store, displayPrefs: displayPrefs, configuration: configuration)
        if let hostingView = contentView as? NSHostingView<WidgetPanelView> {
            hostingView.rootView = rootView
        } else {
            contentView = NSHostingView(rootView: rootView)
        }
        let targetLevel = Self.windowLevel(for: configuration.layer)
        if level != targetLevel {
            level = targetLevel
        }
    }

    private static func windowLevel(for layer: WidgetLayerLevel) -> NSWindow.Level {
        switch layer {
        case .desktop:
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .normal:
            return .normal
        case .floating:
            return .floating
        }
    }

    /// Detaches the hosted SwiftUI view tree so it stops observing `store`/`displayPrefs`
    /// and re-rendering on every poll tick while this panel is hidden (mirrors how the
    /// menu bar popover detaches its content on close). `update(configuration:store:displayPrefs:)`
    /// recreates the hosting view on next use.
    func detachContent() {
        contentView = nil
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
