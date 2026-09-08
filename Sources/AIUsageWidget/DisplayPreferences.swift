import AppKit
import Combine
import SwiftUI

/// Display mode for the menu bar status item.
enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly = "icon_only"
    case percentageText = "percentage_text"
    case coloredDots = "colored_dots"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .percentageText: return "Percentage text"
        case .coloredDots: return "Provider dots"
        }
    }
}

/// Layout style for the floating desktop widget.
enum DesktopWidgetStyle: String, CaseIterable, Identifiable {
    case combinedLinear = "combined_linear"
    case combinedCircular = "combined_circular"
    case perAgentLinear = "per_agent_linear"
    case perAgentCircular = "per_agent_circular"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .combinedLinear: return "Combined (linear bars)"
        case .combinedCircular: return "Combined (circular rings)"
        case .perAgentLinear: return "Per-agent (linear bars)"
        case .perAgentCircular: return "Per-agent (circular rings)"
        }
    }
}

/// Whether percentages represent used quota or remaining quota.
enum PercentageMetric: String, CaseIterable, Identifiable {
    case used = "used"
    case remaining = "remaining"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .used: return "Used"
        case .remaining: return "Remaining"
        }
    }
}

/// Stores local UI preferences in UserDefaults (no daemon round-trip required).
@MainActor
final class DisplayPreferences: ObservableObject {
    static let shared = DisplayPreferences()

    private enum Keys {
        static let menuBarMode = "display_menu_bar_mode"
        static let percentageMetric = "display_percentage_metric"
        static let providerOrder = "display_provider_order"
        static let isDesktopWidgetEnabled = "display_desktop_widget_enabled"
        static let desktopWidgetStyle = "display_desktop_widget_style"
    }

    @Published var menuBarMode: MenuBarDisplayMode {
        didSet {
            UserDefaults.standard.set(menuBarMode.rawValue, forKey: Keys.menuBarMode)
        }
    }

    @Published var percentageMetric: PercentageMetric {
        didSet {
            UserDefaults.standard.set(percentageMetric.rawValue, forKey: Keys.percentageMetric)
        }
    }

    @Published var providerOrder: [Provider] {
        didSet {
            let rawList = providerOrder.map { $0.rawValue }
            UserDefaults.standard.set(rawList, forKey: Keys.providerOrder)
        }
    }

    @Published var isDesktopWidgetEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDesktopWidgetEnabled, forKey: Keys.isDesktopWidgetEnabled)
        }
    }

    @Published var desktopWidgetStyle: DesktopWidgetStyle {
        didSet {
            UserDefaults.standard.set(desktopWidgetStyle.rawValue, forKey: Keys.desktopWidgetStyle)
        }
    }

    private init() {
        self.isDesktopWidgetEnabled = UserDefaults.standard.bool(forKey: Keys.isDesktopWidgetEnabled)

        if let styleRaw = UserDefaults.standard.string(forKey: Keys.desktopWidgetStyle),
           let style = DesktopWidgetStyle(rawValue: styleRaw) {
            self.desktopWidgetStyle = style
        } else {
            self.desktopWidgetStyle = .combinedLinear
        }

        if let modeRaw = UserDefaults.standard.string(forKey: Keys.menuBarMode),
           let mode = MenuBarDisplayMode(rawValue: modeRaw) {
            self.menuBarMode = mode
        } else {
            self.menuBarMode = .iconOnly
        }

        if let metricRaw = UserDefaults.standard.string(forKey: Keys.percentageMetric),
           let metric = PercentageMetric(rawValue: metricRaw) {
            self.percentageMetric = metric
        } else {
            self.percentageMetric = .used
        }

        if let list = UserDefaults.standard.stringArray(forKey: Keys.providerOrder) {
            var ordered = list.compactMap { Provider(rawValue: $0) }
            for p in Provider.allCases where !ordered.contains(p) {
                ordered.append(p)
            }
            self.providerOrder = ordered
        } else {
            self.providerOrder = Provider.allCases
        }
    }

    /// Moves a provider up one step in the display order.
    func moveUp(provider: Provider) {
        guard let index = providerOrder.firstIndex(of: provider), index > 0 else { return }
        providerOrder.swapAt(index, index - 1)
    }

    /// Moves a provider down one step in the display order.
    func moveDown(provider: Provider) {
        guard let index = providerOrder.firstIndex(of: provider), index < providerOrder.count - 1 else { return }
        providerOrder.swapAt(index, index + 1)
    }

    /// Returns the adjusted percentage value according to the current metric preference.
    func displayPercent(forUsedPercent used: Double) -> Double {
        switch percentageMetric {
        case .used:
            return min(max(used, 0), 100)
        case .remaining:
            return min(max(100.0 - used, 0), 100)
        }
    }

    /// Generates a crisp multi-dot NSImage representing per-account status in the menu bar.
    /// Strictly branches on account `state` per Task B6: stale/disconnected/error accounts never render as healthy green dots.
    func generateDotsImage(accounts: [Account], isDaemonReachable: Bool) -> NSImage {
        let dotDiameter: CGFloat = 8.0
        let dotSpacing: CGFloat = 4.0
        let totalCount = max(accounts.count, 1)
        let totalWidth = CGFloat(totalCount) * dotDiameter + CGFloat(totalCount - 1) * dotSpacing
        let totalHeight: CGFloat = 16.0

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        image.lockFocus()

        if accounts.isEmpty {
            let x: CGFloat = 0
            let y = (totalHeight - dotDiameter) / 2.0
            let rect = NSRect(x: x, y: y, width: dotDiameter, height: dotDiameter)
            let path = NSBezierPath(ovalIn: rect)
            NSColor.systemGray.setFill()
            path.fill()
        } else {
            for (index, account) in accounts.enumerated() {
                let x = CGFloat(index) * (dotDiameter + dotSpacing)
                let y = (totalHeight - dotDiameter) / 2.0
                let rect = NSRect(x: x, y: y, width: dotDiameter, height: dotDiameter)
                let path = NSBezierPath(ovalIn: rect)

                let dotColor: NSColor
                if !isDaemonReachable {
                    dotColor = .systemGray
                } else {
                    switch account.state {
                    case .error:
                        dotColor = .systemOrange
                    case .unknown:
                        dotColor = .systemGray
                    case .stale:
                        dotColor = .systemOrange
                    case .restored:
                        dotColor = .systemPurple
                    case .fresh:
                        if let data = account.data {
                            let usageValues = [data.usedPercent5h, data.usedPercentWeekly, data.contextWindowUsedPercent].compactMap { $0 }
                            if let maxVal = usageValues.max() {
                                let displayed = displayPercent(forUsedPercent: maxVal)
                                switch percentageMetric {
                                case .used:
                                    if displayed < 60 {
                                        dotColor = .systemGreen
                                    } else if displayed < 85 {
                                        dotColor = .systemYellow
                                    } else {
                                        dotColor = .systemRed
                                    }
                                case .remaining:
                                    if displayed > 40 {
                                        dotColor = .systemGreen
                                    } else if displayed > 15 {
                                        dotColor = .systemYellow
                                    } else {
                                        dotColor = .systemRed
                                    }
                                }
                            } else {
                                dotColor = .systemGray
                            }
                        } else {
                            dotColor = .systemGray
                        }
                    }
                }

                dotColor.setFill()
                path.fill()
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Backward compatibility overload for provider-keyed calls
    func generateDotsImage(providers: [(provider: Provider, status: ProviderStatus?)], isStaleOrFailing: Bool) -> NSImage {
        let accounts = providers.compactMap { $0.status }
        return generateDotsImage(accounts: accounts, isDaemonReachable: !isStaleOrFailing)
    }
}
