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
enum DesktopWidgetStyle: String, CaseIterable, Identifiable, Codable {
    case combinedLinear = "combined_linear"
    case combinedCircular = "combined_circular"
    case perAgentLinear = "per_agent_linear"
    case perAgentCircular = "per_agent_circular"
    case concentricRings = "concentric_rings"
    case singleAgentFocus = "single_agent_focus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .combinedLinear: return "Combined (linear bars)"
        case .combinedCircular: return "Combined (circular rings)"
        case .perAgentLinear: return "Per-agent (linear bars)"
        case .perAgentCircular: return "Per-agent (circular rings)"
        case .concentricRings: return "Concentric rings (5h / weekly)"
        case .singleAgentFocus: return "Single agent focus"
        }
    }
}

enum WidgetMetricKind: String, CaseIterable, Identifiable, Codable {
    case fiveHour = "5h"
    case weekly = "weekly"
    case context = "context"
    case claudeGptWeekly = "claude_gpt_weekly"

    static let offerable: [WidgetMetricKind] = [.fiveHour, .weekly]

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .weekly: return "Weekly window"
        case .context: return "Context window"
        case .claudeGptWeekly: return "Claude/GPT quota"
        }
    }
}

struct WidgetScope: Codable, Equatable {
    // nil includes all enabled accounts (including future accounts); an empty set includes none.
    var includedAccountIds: Set<String>?

    static let allAgents = WidgetScope(includedAccountIds: nil)
    static func singleAgent(_ accountId: String) -> WidgetScope {
        WidgetScope(includedAccountIds: [accountId])
    }

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
    // Legacy global selection remains the fallback for accounts without an override.
    var visibleMetrics: Set<WidgetMetricKind> = Set(WidgetMetricKind.offerable)
    var accountMetrics: [String: Set<WidgetMetricKind>] = [:]

    func visibleMetrics(forAccountId accountId: String) -> Set<WidgetMetricKind> {
        accountMetrics[accountId] ?? visibleMetrics
    }
}

extension WidgetConfiguration {
    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, style, scope, visibleMetrics, accountMetrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        style = try container.decode(DesktopWidgetStyle.self, forKey: .style)
        scope = try container.decode(WidgetScope.self, forKey: .scope)
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
        static let showAntigravityModelBreakdown = "display_show_antigravity_model_breakdown"
        static let percentageMetric = "display_percentage_metric"
        static let providerOrder = "display_provider_order"
        static let widgetConfigurations = "display_widget_configurations"
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
            if let data = try? JSONEncoder().encode(widgetConfigurations) {
                UserDefaults.standard.set(data, forKey: Keys.widgetConfigurations)
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
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
                            let usageValues = [data.usedPercent5h, data.usedPercentWeekly].compactMap { $0 }
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
