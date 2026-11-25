import os
import SwiftUI
import WidgetKit

/// Debug logging for the widget extension:
/// `log show --predicate 'subsystem == "com.quotapeek" AND category == "widget"' --debug`.
enum WidgetLog {
    static let logger = Logger(subsystem: "com.quotapeek", category: "widget")
}

/// Logs the geometry and rendering mode the system actually renders with,
/// which differ by platform and placement (desktop vs Notification Center).
@available(macOS 14.0, *)
struct WidgetGeometryProbe: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetContentMargins) private var margins
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    var body: some View {
        GeometryReader { geo in
            Color.clear.onAppear {
                WidgetLog.logger.debug("render family=\(String(describing: family), privacy: .public) content=\(Int(geo.size.width), privacy: .public)x\(Int(geo.size.height), privacy: .public) margins=\(margins.top, privacy: .public)/\(margins.leading, privacy: .public)/\(margins.bottom, privacy: .public)/\(margins.trailing, privacy: .public) mode=\(String(describing: renderingMode), privacy: .public) background=\(showsBackground, privacy: .public)")
            }
        }
    }
}
