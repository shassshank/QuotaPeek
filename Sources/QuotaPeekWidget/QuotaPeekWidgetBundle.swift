import QuotaPeekCore
import QuotaPeekWidgetUI
import SwiftUI
import WidgetKit

// The extension only declares widgets; timeline logic and views live in
// QuotaPeekWidgetUI. Each desktop-panel style is its own widget in the
// gallery, so different instances can use different styles. Which accounts
// and metrics they show is chosen in QuotaPeek's Settings.

@main
struct QuotaPeekWidgetBundle: WidgetBundle {
    var body: some Widget {
        CombinedLinearWidget()
        CombinedCircularWidget()
        PerAgentLinearWidget()
        PerAgentCircularWidget()
        ConcentricRingsWidget()
        SingleAgentFocusWidget()
    }
}

/// Shared configuration for every style.
private func quotaConfiguration(_ style: DesktopWidgetStyle, description: String) -> some WidgetConfiguration {
    StaticConfiguration(kind: "com.quotapeek.app.widget.\(style.rawValue)", provider: QuotaTimelineProvider()) { entry in
        QuotaWidgetFamilyReader(entry: entry, style: style)
    }
    .configurationDisplayName("QuotaPeek · \(style.galleryName)")
    .description(description)
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
}

/// Reads the rendering family from the environment.
private struct QuotaWidgetFamilyReader: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry
    let style: DesktopWidgetStyle

    var body: some View {
        QuotaWidgetView(entry: entry, style: style, family: family)
    }
}

private extension DesktopWidgetStyle {
    var galleryName: String {
        switch self {
        case .combinedLinear: return "Bars"
        case .combinedCircular: return "Rings"
        case .perAgentLinear: return "Agent bars"
        case .perAgentCircular: return "Agent ring"
        case .concentricRings: return "Concentric"
        case .singleAgentFocus: return "Focus"
        }
    }
}

struct CombinedLinearWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.combinedLinear, description: "Every selected agent with 5-hour and weekly bars.")
    }
}

struct CombinedCircularWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.combinedCircular, description: "A ring per agent.")
    }
}

struct PerAgentLinearWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.perAgentLinear, description: "One agent with large numbers and bars.")
    }
}

struct PerAgentCircularWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.perAgentCircular, description: "One agent on a large ring.")
    }
}

struct ConcentricRingsWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.concentricRings, description: "5-hour (outer) and weekly (inner) rings per agent.")
    }
}

struct SingleAgentFocusWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.singleAgentFocus, description: "The one number that matters most for an agent.")
    }
}
