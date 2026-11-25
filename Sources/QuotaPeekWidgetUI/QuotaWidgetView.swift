import QuotaPeekCore
import SwiftUI
import WidgetKit

/// Root view for every QuotaPeek widget: handles app-not-running / empty
/// states, then renders the chosen style for the widget's size. Clicking
/// anywhere opens QuotaPeek (which refreshes).
public struct QuotaWidgetView: View {
    let entry: QuotaEntry
    let style: DesktopWidgetStyle
    let family: WidgetFamily

    public init(entry: QuotaEntry, style: DesktopWidgetStyle, family: WidgetFamily) {
        self.entry = entry
        self.style = style
        self.family = family
    }

    public static let openURL = URL(string: "quotapeek://open")!

    public var body: some View {
        content
            .widgetURL(Self.openURL)
            .quotaWidgetBackground()
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .notRunning:
            MessageView(symbol: "gauge.with.dots.needle.0percent", title: "QuotaPeek isn't running",
                        detail: "Click to open it.")
        case .unreadable(let why):
            MessageView(symbol: "exclamationmark.triangle", title: "Can't read usage", detail: why)
        case .ready(let content) where content.rows.isEmpty:
            MessageView(symbol: "tray", title: "No accounts selected",
                        detail: "Choose accounts in QuotaPeek Settings → Widgets.")
        case .ready(let content):
            StyleView(content: content, style: style, family: family, now: entry.date)
        }
    }
}

private struct StyleView: View {
    let content: QuotaWidgetContent
    let style: DesktopWidgetStyle
    let family: WidgetFamily
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            if family != .systemSmall {
                WidgetHeader(content: content, now: now)
            }
            switch style {
            case .combinedLinear: CombinedLinearStyle(content: content, family: family, now: now)
            case .combinedCircular: CombinedCircularStyle(content: content, family: family)
            case .perAgentLinear: PerAgentLinearStyle(content: content, family: family, now: now)
            case .perAgentCircular: PerAgentCircularStyle(content: content, family: family, now: now)
            case .concentricRings: ConcentricRingsStyle(content: content, family: family)
            case .singleAgentFocus: SingleAgentFocusStyle(content: content, family: family, now: now)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Style 1: Combined, linear bars

private struct CombinedLinearStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    private var capacity: Int {
        switch family {
        case .systemSmall: return 2
        case .systemMedium: return 4
        default: return 6
        }
    }

    private var columns: Int { family == .systemMedium ? 2 : 1 }

    var body: some View {
        let shown = Array(content.rows.prefix(capacity))
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns),
                      alignment: .leading, spacing: 6) {
                ForEach(shown) { row in card(row) }
            }
            Spacer(minLength: 0)
            OverflowNote(hidden: content.rows.count - shown.count)
        }
    }

    private func card(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        return VStack(alignment: .leading, spacing: 4) {
            IdentityRow(row: row, showLabel: family != .systemSmall)
            if values.isEmpty || row.state == .error || row.state == .unknown {
                RowPlaceholder(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
            } else {
                ForEach(values) { value in
                    MetricRow(value: value, metric: content.metric, now: now,
                              showCountdown: family != .systemSmall && columns == 1 || family == .systemLarge)
                }
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .opacity(row.state == .stale ? 0.75 : 1)
    }
}

// MARK: - Style 2: Combined, circular rings

private struct CombinedCircularStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily

    private var layout: (columns: Int, rows: Int, size: CGFloat) {
        switch family {
        case .systemSmall: return (2, 2, 46)
        case .systemMedium: return (4, 1, 58)
        default: return (3, 3, 62)
        }
    }

    var body: some View {
        let l = layout
        let shown = Array(content.rows.prefix(l.columns * l.rows))
        VStack(spacing: 4) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: l.columns), spacing: 8) {
                ForEach(shown) { row in cell(row, size: l.size) }
            }
            Spacer(minLength: 0)
            OverflowNote(hidden: content.rows.count - shown.count)
        }
        .frame(maxHeight: .infinity, alignment: family == .systemMedium ? .center : .top)
    }

    @ViewBuilder
    private func cell(_ row: DisplayedAccount, size: CGFloat) -> some View {
        let values = content.metricValues(for: row)
        VStack(spacing: 3) {
            if let primary = values.first, row.state != .error, row.state != .unknown {
                LabeledRing(value: primary, metric: content.metric, size: size, lineWidth: size > 50 ? 6 : 5)
                    .opacity(row.state == .stale ? 0.75 : 1)
            } else {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                    .frame(width: size, height: size)
                    .overlay(Image(systemName: row.state == .error ? "exclamationmark" : "minus").foregroundStyle(.secondary))
            }
            HStack(spacing: 2) {
                Image(systemName: row.symbolName).font(.system(size: 8, weight: .bold))
                Text(row.displayName).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            if family != .systemSmall, values.count > 1, let second = values.dropFirst().first {
                Text("\(second.shortLabel) \(second.percentText(content.metric))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Style 3: Per-agent, linear bars

private struct PerAgentLinearStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    /// Per-agent styles show the first selected account (pick which one in
    /// Settings); medium and large also list the rest compactly.
    var body: some View {
        if let row = content.rows.first {
            VStack(alignment: .leading, spacing: 8) {
                focusCard(row)
                if family == .systemLarge {
                    ForEach(content.rows.dropFirst().prefix(3)) { other in
                        CompactLine(row: other, content: content)
                    }
                    Spacer(minLength: 0)
                    OverflowNote(hidden: max(0, content.rows.count - 4))
                }
            }
        }
    }

    private func focusCard(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        return VStack(alignment: .leading, spacing: 6) {
            IdentityRow(row: row, nameFont: .system(size: 13, weight: .bold))
            if values.isEmpty || row.state == .error || row.state == .unknown {
                RowPlaceholder(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
            } else {
                HStack(alignment: .top, spacing: family == .systemSmall ? 0 : 16) {
                    ForEach(values.prefix(family == .systemSmall ? 1 : 2)) { value in
                        bigMetric(value)
                    }
                }
                if family == .systemSmall, let second = values.dropFirst().first {
                    MetricRow(value: second, metric: content.metric, now: now, showCountdown: false)
                }
            }
        }
        .padding(family == .systemSmall ? 0 : 8)
        .background(family == .systemSmall ? Color.clear : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func bigMetric(_ value: MetricValue) -> some View {
        let (pct, color) = value.display(content.metric)
        return VStack(alignment: .leading, spacing: 3) {
            Text(value.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value.percentText(content.metric))
                .font(.system(size: family == .systemSmall ? 30 : 26, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            LinearProgressBar(percent: pct, color: color, height: 5)
            if let reset = value.resetsAt {
                Text("resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One-line summary used under a focused account on large widgets.
private struct CompactLine: View {
    let row: DisplayedAccount
    let content: QuotaWidgetContent

    var body: some View {
        let values = content.metricValues(for: row)
        HStack(spacing: 6) {
            Image(systemName: row.symbolName).font(.system(size: 9, weight: .bold)).frame(width: 12)
            Text(row.displayName).font(.system(size: 10, weight: .medium)).lineLimit(1)
            Spacer()
            ForEach(values) { value in
                let (_, color) = value.display(content.metric)
                Text("\(value.shortLabel) \(value.percentText(content.metric))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            StateBadge(state: row.state)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Style 4: Per-agent, circular ring

private struct PerAgentCircularStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    var body: some View {
        if let row = content.rows.first {
            let values = content.metricValues(for: row)
            VStack(alignment: .leading, spacing: 8) {
                IdentityRow(row: row, nameFont: .system(size: 12, weight: .bold))
                if values.isEmpty || row.state == .error || row.state == .unknown {
                    RowPlaceholder(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                } else if family == .systemSmall {
                    HStack {
                        Spacer()
                        LabeledRing(value: values[0], metric: content.metric, size: 78, lineWidth: 8,
                                    caption: values.dropFirst().first.map { "\($0.shortLabel) \($0.percentText(content.metric))" })
                        Spacer()
                    }
                } else {
                    HStack(spacing: 14) {
                        LabeledRing(value: values[0], metric: content.metric, size: 84, lineWidth: 9)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(values) { value in
                                MetricRow(value: value, metric: content.metric, now: now)
                            }
                        }
                    }
                    if family == .systemLarge {
                        ForEach(content.rows.dropFirst().prefix(4)) { other in
                            CompactLine(row: other, content: content)
                        }
                        Spacer(minLength: 0)
                        OverflowNote(hidden: max(0, content.rows.count - 5))
                    }
                }
            }
            .opacity(row.state == .stale ? 0.75 : 1)
        }
    }
}

// MARK: - Style 5: Concentric rings (outer 5h, inner weekly)

private struct ConcentricRingsStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily

    private var layout: (columns: Int, count: Int, size: CGFloat) {
        switch family {
        case .systemSmall: return (1, 1, 92)
        case .systemMedium: return (3, 3, 74)
        default: return (2, 4, 96)
        }
    }

    var body: some View {
        let l = layout
        let shown = Array(content.rows.prefix(l.count))
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: l.columns), spacing: 10) {
                ForEach(shown) { row in cell(row, size: l.size) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                legend("Outer", "5h")
                legend("Inner", "Weekly")
                Spacer()
                OverflowNote(hidden: content.rows.count - shown.count)
            }
        }
    }

    private func legend(_ ring: String, _ window: String) -> some View {
        Text("\(ring): \(window)")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
    }

    private func cell(_ row: DisplayedAccount, size: CGFloat) -> some View {
        let values = content.metricValues(for: row)
        let outer = values.first { $0.kind == .fiveHour }
        let inner = values.first { $0.kind == .weekly }
        let line = max(5, size * 0.09)
        return VStack(spacing: 4) {
            ZStack {
                if let outer {
                    let (pct, color) = outer.display(content.metric)
                    CircularRingProgress(percent: pct, color: color, lineWidth: line, size: size)
                }
                if let inner {
                    let (pct, color) = inner.display(content.metric)
                    CircularRingProgress(percent: pct, color: color, lineWidth: line,
                                         size: outer == nil ? size : size - line * 2.6)
                }
                VStack(spacing: 0) {
                    if let outer {
                        Text(outer.percentText(content.metric))
                            .font(.system(size: size * 0.17, weight: .bold, design: .rounded))
                    }
                    if let inner {
                        Text(inner.percentText(content.metric))
                            .font(.system(size: size * 0.12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: size * 0.55)
            }
            .frame(width: size, height: size)
            .opacity(row.state == .stale ? 0.75 : 1)
            HStack(spacing: 2) {
                Image(systemName: row.symbolName).font(.system(size: 8, weight: .bold))
                Text(row.displayName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                StateBadge(state: row.state)
            }
        }
    }
}

// MARK: - Style 6: Single agent focus

private struct SingleAgentFocusStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    var body: some View {
        if let row = content.rows.first {
            let values = content.metricValues(for: row)
            // The dominant metric is whichever is closest to running out.
            let dominant = values.max { $0.used < $1.used }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: row.symbolName).font(.system(size: 13, weight: .bold))
                    Text(row.displayName).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Spacer()
                    StateBadge(state: row.state)
                }
                Spacer(minLength: 0)
                if let dominant, row.state != .error, row.state != .unknown {
                    let (pct, color) = dominant.display(content.metric)
                    Text(dominant.percentText(content.metric))
                        .font(.system(size: family == .systemSmall ? 46 : 56, weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(dominant.title + (dominant.resetsAt.map { " · resets \(UsageFormatting.formatCountdown($0, inPrefix: true, now: now))" } ?? ""))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    LinearProgressBar(percent: pct, color: color, height: 6)
                    if family != .systemSmall {
                        ForEach(values.filter { $0.kind != dominant.kind }) { other in
                            MetricRow(value: other, metric: content.metric, now: now)
                        }
                    }
                } else {
                    RowPlaceholder(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                }
                Spacer(minLength: 0)
            }
            .opacity(row.state == .stale ? 0.75 : 1)
        }
    }
}

// MARK: - Background

extension View {
    /// Standard widget background; `containerBackground` exists from macOS 14.
    @ViewBuilder
    func quotaWidgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(for: .widget) { Color.clear }
        } else {
            padding()
        }
    }
}
