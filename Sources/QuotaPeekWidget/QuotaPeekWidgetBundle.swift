import QuotaPeekCore
import QuotaPeekWidgetUI
import SwiftUI
import WidgetKit

// The extension only declares widgets; timeline logic and views live in
// QuotaPeekWidgetUI. Each desktop-panel style is its own widget in the
// gallery, so different instances can use different styles. Which accounts
// and metrics they show is chosen in QuotaPeek's Settings.

// The extension binary is stamped as requiring macOS 14 (see
// build-app-bundle.sh), so everything here may use macOS 14 WidgetKit API.
@main
@available(macOS 14.0, *)
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
@available(macOS 14.0, *)
private func quotaConfiguration(_ style: DesktopWidgetStyle, description: String) -> some WidgetConfiguration {
    // Pass plain Strings: an interpolated literal becomes a *formatted*
    // LocalizedStringKey, which WidgetKit rejects at runtime with "Formatted
    // text for `configurationDisplayName` is not supported" (crashing the
    // extension, so the widget never appears in the gallery).
    let displayName: String = "QuotaPeek · " + style.galleryName
    let kind: String = "com.quotapeek.app.widget." + style.rawValue
    return StaticConfiguration(kind: kind, provider: QuotaTimelineProvider()) { entry in
        QuotaWidgetFamilyReader(entry: entry, style: style)
    }
    .configurationDisplayName(displayName)
    .description(description)
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    // Keep our background on the unfocused desktop. If it's removable,
    // macOS swaps it for light glass and tints content white, and the
    // white text disappears (only the gauge shapes remained).
    .containerBackgroundRemovable(false)
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

@available(macOS 14.0, *)
struct CombinedLinearWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.combinedLinear, description: "Every selected agent with 5-hour and weekly bars.")
    }
}

@available(macOS 14.0, *)
struct CombinedCircularWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.combinedCircular, description: "A ring per agent.")
    }
}

@available(macOS 14.0, *)
struct PerAgentLinearWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.perAgentLinear, description: "One agent with large numbers and bars.")
    }
}

@available(macOS 14.0, *)
struct PerAgentCircularWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.perAgentCircular, description: "One agent on a large ring.")
    }
}

@available(macOS 14.0, *)
struct ConcentricRingsWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.concentricRings, description: "5-hour (outer) and weekly (inner) rings per agent.")
    }
}

@available(macOS 14.0, *)
struct SingleAgentFocusWidget: Widget {
    var body: some WidgetConfiguration {
        quotaConfiguration(.singleAgentFocus, description: "The one number that matters most for an agent.")
    }
}
