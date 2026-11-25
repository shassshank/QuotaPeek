import QuotaPeekCore
import AppKit
import Combine
import SwiftUI

/// Display mode for the menu bar status item.
enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly = "icon_only"
    case coloredDots = "colored_dots"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .coloredDots: return "Provider dots"
        }
    }
}

// DesktopWidgetStyle, WidgetMetricKind and PercentageMetric live in QuotaPeekCore,
// shared with the native widget extension.

/// Window stacking level for a desktop widget, selectable per-widget.
enum WidgetLayerLevel: String, CaseIterable, Identifiable, Codable {
    /// Just above the desktop icons layer, behind normal app windows - the
    /// original/default desktop-widget behavior.
    case desktop = "desktop"
    /// A regular window level: mixes with other app windows in normal
    /// front-to-back ordering instead of always sitting behind them.
    case normal = "normal"
    /// Always on top of other windows, including full-screen apps in other Spaces.
    case floating = "floating"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .desktop: return "Desktop (behind app windows)"
        case .normal: return "Normal (with other windows)"
        case .floating: return "Always on top"
        }
    }
}

struct WidgetScope: Codable, Equatable {
    // nil includes all enabled accounts (including future accounts); an empty set includes none.
    var includedAccountIds: Set<String>?

    static let allAgents = WidgetScope(includedAccountIds: nil)

    init(includedAccountIds: Set<String>?) {
        self.includedAccountIds = includedAccountIds
    }

    func includes(_ accountId: String) -> Bool {
        includedAccountIds?.contains(accountId) ?? true
    }

    mutating func setIncluded(_ accountId: String, isIncluded: Bool, enabledAccountIds: Set<String>) {
        var selected = includedAccountIds ?? enabledAccountIds
        if isIncluded {
            selected.insert(accountId)
        } else {
            selected.remove(accountId)
        }
        includedAccountIds = !enabledAccountIds.isEmpty && enabledAccountIds.isSubset(of: selected)
            ? nil : selected
    }

    private enum CodingKeys: String, CodingKey {
        case includedAccountIds
        case accountId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.includedAccountIds) {
            includedAccountIds = try container.decodeIfPresent(Set<String>.self, forKey: .includedAccountIds)
        } else {
            // Older widgets encoded only accountId, omitting it entirely for all accounts.
            let legacyId = try container.decodeIfPresent(String.self, forKey: .accountId)
            includedAccountIds = legacyId.map { [$0] }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let includedAccountIds {
            try container.encode(includedAccountIds.sorted(), forKey: .includedAccountIds)
        } else {
            try container.encodeNil(forKey: .includedAccountIds)
        }
    }
}

struct WidgetConfiguration: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = "Desktop Widget"
    var isEnabled: Bool = false
    var style: DesktopWidgetStyle = .combinedLinear
    var scope: WidgetScope = .allAgents
    var layer: WidgetLayerLevel = .desktop
    // Legacy global selection remains the fallback for accounts without an override.
    var visibleMetrics: Set<WidgetMetricKind> = Set(WidgetMetricKind.offerable)
    var accountMetrics: [String: Set<WidgetMetricKind>] = [:]

    func visibleMetrics(forAccountId accountId: String) -> Set<WidgetMetricKind> {
        accountMetrics[accountId] ?? visibleMetrics
    }
}

extension WidgetConfiguration {
    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, style, scope, layer, visibleMetrics, accountMetrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        style = try container.decode(DesktopWidgetStyle.self, forKey: .style)
        scope = try container.decode(WidgetScope.self, forKey: .scope)
        // Older widgets predate per-widget layer levels; default to the
        // original desktop-behind-windows behavior they always had.
        layer = try container.decodeIfPresent(WidgetLayerLevel.self, forKey: .layer) ?? .desktop
        visibleMetrics = try container.decode(Set<WidgetMetricKind>.self, forKey: .visibleMetrics)
        // Older widgets have only the global visibleMetrics field.
        accountMetrics = try container.decodeIfPresent([String: Set<WidgetMetricKind>].self, forKey: .accountMetrics) ?? [:]
    }
}

private struct FailableWidgetConfiguration: Decodable {
    let value: WidgetConfiguration?

    init(from decoder: Decoder) throws {
        do {
            value = try WidgetConfiguration(from: decoder)
        } catch {
            value = nil
            NSLog("[DisplayPreferences] Dropping malformed widget configuration at %@: %@",
                  decoder.codingPath.map { $0.stringValue }.joined(separator: "."),
                  String(describing: error))
        }
    }
}

/// Stores local UI preferences in UserDefaults (no daemon round-trip required).
@MainActor
final class DisplayPreferences: ObservableObject {
    static let shared = DisplayPreferences()

    private enum Keys {
        static let menuBarMode = "display_menu_bar_mode"
        static let showAntigravityModelBreakdown = "display_show_antigravity_model_breakdown"
        static let percentageMetric = "display_percentage_metric"
        static let providerOrder = "display_provider_order"
        static let widgetConfigurations = "display_widget_configurations"
        static let nativeWidget = "display_native_widget"
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

    @Published var showAntigravityModelBreakdown: Bool {
        didSet {
            UserDefaults.standard.set(showAntigravityModelBreakdown, forKey: Keys.showAntigravityModelBreakdown)
        }
    }

    @Published var providerOrder: [Provider] {
        didSet {
            let rawList = providerOrder.map { $0.rawValue }
            UserDefaults.standard.set(rawList, forKey: Keys.providerOrder)
        }
    }

    @Published var widgetConfigurations: [WidgetConfiguration] {
        didSet {
            persistWidgetConfigurationsDebounced()
        }
    }

    /// Accounts and metrics shown by the native (WidgetKit) widget. Reuses the
    /// desktop panel's configuration type for its scope and metric choices;
    /// style, layer and name don't apply (style is picked per widget in the
    /// macOS widget gallery).
    @Published var nativeWidget: WidgetConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(nativeWidget) {
                UserDefaults.standard.set(data, forKey: Keys.nativeWidget)
            }
        }
    }

    /// Native-widget selection in the snapshot's form.
    var nativeWidgetSnapshot: QuotaSnapshot.NativeWidget {
        QuotaSnapshot.NativeWidget(
            includedAccountIds: nativeWidget.scope.includedAccountIds.map { $0.sorted() },
            visibleMetrics: WidgetMetricKind.allCases.filter { nativeWidget.visibleMetrics.contains($0) },
            accountMetrics: nativeWidget.accountMetrics.mapValues { set in WidgetMetricKind.allCases.filter { set.contains($0) } }
        )
    }

    /// Coalesces the UserDefaults write for `widgetConfigurations` so rapid-fire
    /// changes (e.g. every keystroke while typing a widget name in a bound
    /// TextField) don't each do a synchronous JSON encode + disk write. Only the
    /// most recent snapshot within the debounce window is ever persisted, so the
    /// final typed value still ends up saved.
    private var widgetConfigurationsSaveWorkItem: DispatchWorkItem?

    private func persistWidgetConfigurationsDebounced() {
        widgetConfigurationsSaveWorkItem?.cancel()
        let snapshot = widgetConfigurations
        let workItem = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Keys.widgetConfigurations)
        }
        widgetConfigurationsSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private init() {
        let defaults = UserDefaults.standard
        self.nativeWidget = defaults.data(forKey: Keys.nativeWidget)
            .flatMap { try? JSONDecoder().decode(WidgetConfiguration.self, from: $0) }
            ?? WidgetConfiguration(name: "Native Widget", isEnabled: true)
        self.showAntigravityModelBreakdown = defaults.object(forKey: Keys.showAntigravityModelBreakdown) == nil
            ? true : defaults.bool(forKey: Keys.showAntigravityModelBreakdown)
        if let data = defaults.data(forKey: Keys.widgetConfigurations),
           let configurations = try? JSONDecoder().decode([FailableWidgetConfiguration].self, from: data) {
            self.widgetConfigurations = configurations.compactMap(\.value)
        } else if defaults.object(forKey: Keys.isDesktopWidgetEnabled) != nil
                    || defaults.object(forKey: Keys.desktopWidgetStyle) != nil {
            let style = defaults.string(forKey: Keys.desktopWidgetStyle)
                .flatMap { DesktopWidgetStyle(rawValue: $0) } ?? .combinedLinear
            let configurations = [WidgetConfiguration(
                isEnabled: defaults.bool(forKey: Keys.isDesktopWidgetEnabled),
                style: style
            )]
            self.widgetConfigurations = configurations
            // Property observers do not run during initialization.
            if let data = try? JSONEncoder().encode(configurations) {
                defaults.set(data, forKey: Keys.widgetConfigurations)
                defaults.removeObject(forKey: Keys.isDesktopWidgetEnabled)
                defaults.removeObject(forKey: Keys.desktopWidgetStyle)
            }
        } else {
            self.widgetConfigurations = []
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

    func addWidgetConfiguration() {
        widgetConfigurations.append(WidgetConfiguration(isEnabled: true))
    }

    func removeWidgetConfiguration(id: UUID) {
        widgetConfigurations.removeAll { $0.id == id }
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
        UsageFormatting.displayPercent(forUsedPercent: used, metric: percentageMetric)
    }

    enum DotColor: Equatable {
        case gray
        case orange
        case purple
        case green
        case yellow
        case red

        var nsColor: NSColor {
            switch self {
            case .gray: return .systemGray
            case .orange: return .systemOrange
            case .purple: return .systemPurple
            case .green: return .systemGreen
            case .yellow: return .systemYellow
            case .red: return .systemRed
            }
        }
    }

    func dotColor(for account: Account) -> DotColor {
        switch account.state {
        case .error:
            return .orange
        case .unknown:
            return .gray
        case .stale:
            return .orange
        case .restored:
            return .purple
        case .fresh:
            if let data = account.data {
                let usageValues = [data.usedPercent5h, data.usedPercentWeekly].compactMap { $0 }
                if let maxVal = usageValues.max() {
                    let displayed = displayPercent(forUsedPercent: maxVal)
                    switch percentageMetric {
                    case .used:
                        if displayed < 60 {
                            return .green
                        } else if displayed < 85 {
                            return .yellow
                        } else {
                            return .red
                        }
                    case .remaining:
                        if displayed > 40 {
                            return .green
                        } else if displayed > 15 {
                            return .yellow
                        } else {
                            return .red
                        }
                    }
                } else {
                    return .gray
                }
            } else {
                return .gray
            }
        }
    }

    /// Generates a crisp multi-dot NSImage representing per-account status in the menu bar.
    /// Strictly branches on account `state` per Task B6: stale/disconnected/error accounts never render as healthy green dots.
    func generateDotsImage(accounts: [Account]) -> NSImage {
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

                let color = dotColor(for: account)
                color.nsColor.setFill()
                path.fill()
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
