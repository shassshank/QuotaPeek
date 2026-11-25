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
            .background {
                if #available(macOS 14.0, *) { WidgetGeometryProbe() }
            }
            .widgetURL(Self.openURL)
            .quotaWidgetBackground()
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .notRunning:
            MessageView(symbol: "gauge.with.dots.needle.0percent",
                        title: "QuotaPeek isn't running",
                        detail: "Click to open it.")
        case .unreadable(let why):
            MessageView(symbol: "exclamationmark.triangle",
                        title: "Can't read usage",
                        detail: why)
        case .ready(let content) where content.rows.isEmpty:
            MessageView(symbol: "tray",
                        title: "No accounts selected",
                        detail: "Choose accounts in Settings → Widgets.")
        case .ready(let content):
            StyleView(content: content, style: style, family: family, now: entry.date)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct StyleView: View {
    let content: QuotaWidgetContent
    let style: DesktopWidgetStyle
    let family: WidgetFamily
    let now: Date

    var body: some View {
        switch style {
        case .combinedLinear:
            CombinedLinearStyle(content: content, family: family, now: now)
        case .combinedCircular:
            CombinedCircularStyle(content: content, family: family, now: now)
        case .perAgentLinear:
            PerAgentLinearStyle(content: content, family: family, now: now)
        case .perAgentCircular:
            PerAgentCircularStyle(content: content, family: family, now: now)
        case .concentricRings:
            ConcentricRingsStyle(content: content, family: family, now: now)
        case .singleAgentFocus:
            SingleAgentFocusStyle(content: content, family: family, now: now)
        }
    }
}

// MARK: - Style 1: Combined Linear ("Bars" — Stocks / Screen Time list)

private struct CombinedLinearStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    var body: some View {
        switch family {
        case .systemSmall:
            smallBody
        case .systemMedium:
            mediumBody
        default:
            largeBody
        }
    }

    private var smallBody: some View {
        let shown = Array(content.rows.prefix(2))
        let hidden = max(0, content.rows.count - shown.count)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    HairlineDivider().padding(.vertical, 5)
                }
                smallAccountBlock(row)
            }
            Spacer(minLength: 0)
            WidgetFooterBar(
                leading: content.staleSyncNote(now: now) ?? (content.metric == .remaining ? "Quota left" : "Quota used"),
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
    }

    private func smallAccountBlock(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        return VStack(alignment: .leading, spacing: 3) {
            AccountIdentityHeader(row: row, fontSize: 12, showLabel: false, compactState: true)
            if values.isEmpty || row.state == .error || row.state == .unknown {
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
            } else {
                ForEach(values) { value in
                    LinearMetricLine(value: value, metric: content.metric, now: now,
                                     barHeight: 4, showCountdown: false, labelWidth: 18)
                }
            }
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }

    private var mediumBody: some View {
        let capacity = 4
        let shown = Array(content.rows.prefix(capacity))
        let hidden = max(0, content.rows.count - shown.count)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    HairlineDivider().padding(.vertical, 4)
                }
                mediumRow(row)
            }
            Spacer(minLength: 0)
            WidgetFooterBar(
                leading: content.staleSyncNote(now: now) ?? (content.metric == .remaining ? "Quota left" : "Quota used"),
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
    }

    private func mediumRow(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: row.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(row.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                StateIndicator(state: row.state, compact: true)
            }
            .frame(width: 94, alignment: .leading)

            if values.isEmpty || row.state == .error || row.state == .unknown {
                Spacer(minLength: 0)
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
            } else if values.count == 1, let only = values.first {
                LinearMetricLine(value: only, metric: content.metric, now: now,
                                 barHeight: 5, showCountdown: true, labelWidth: 18)
            } else {
                HStack(spacing: 8) {
                    ForEach(values.prefix(2)) { value in
                        LinearMetricLine(value: value, metric: content.metric, now: now,
                                         barHeight: 5, showCountdown: false, labelWidth: 18,
                                         spacing: 4, percentMinWidth: 30)
                    }
                }
            }
        }
        .frame(height: 19)
        .opacity(row.state == .stale ? 0.85 : 1)
    }

    private var largeBody: some View {
        let capacity = 6
        let shown = Array(content.rows.prefix(capacity))
        let hidden = max(0, content.rows.count - shown.count)
        let compact = shown.count > 4
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    HairlineDivider().padding(.vertical, compact ? 4 : 9)
                }
                largeAccountBlock(row, compact: compact)
            }
            Spacer(minLength: 0)
            WidgetFooterBar(
                leading: content.staleSyncNote(now: now) ?? (content.metric == .remaining ? "Quota left" : "Quota used"),
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
    }

    private func largeAccountBlock(_ row: DisplayedAccount, compact: Bool) -> some View {
        let values = content.metricValues(for: row)
        return VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            AccountIdentityHeader(row: row, fontSize: compact ? 12 : 13, showLabel: true, compactState: false)
            if values.isEmpty || row.state == .error || row.state == .unknown {
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
            } else {
                ForEach(values) { value in
                    LinearMetricLine(value: value, metric: content.metric, now: now,
                                     barHeight: compact ? 4 : 6, showCountdown: true, labelWidth: 20)
                }
            }
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }
}

// MARK: - Style 2: Combined Circular ("Rings" — Apple Batteries style)

private struct CombinedCircularStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    var body: some View {
        switch family {
        case .systemSmall:
            smallBody
        case .systemMedium:
            mediumBody
        default:
            largeBody
        }
    }

    @ViewBuilder
    private var smallBody: some View {
        if content.rows.count == 1, let only = content.rows.first {
            ringCell(only, ringSize: 74, lineWidth: 8, symbolSize: 22, pctSize: 18, nameSize: 12, showSecondary: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let shown = Array(content.rows.prefix(4))
            VStack(spacing: 4) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(shown) { row in
                        ringCell(row, ringSize: 32, lineWidth: 4, symbolSize: 12, pctSize: 11, nameSize: 11, showSecondary: false)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var mediumBody: some View {
        let shown = Array(content.rows.prefix(4))
        let hidden = max(0, content.rows.count - shown.count)
        return VStack(spacing: 0) {
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                ForEach(shown) { row in
                    ringCell(row, ringSize: 52, lineWidth: 5.5, symbolSize: 17, pctSize: 15, nameSize: 11, showSecondary: true)
                        .frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 6)
            WidgetFooterBar(
                leading: content.staleSyncNote(now: now) ?? "5h \(content.metricWord)",
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
    }

    private var largeBody: some View {
        let useGrid3 = content.rows.count > 4
        let capacity = useGrid3 ? 9 : 4
        let shown = Array(content.rows.prefix(capacity))
        let hidden = max(0, content.rows.count - shown.count)
        let columns = useGrid3 ? 3 : 2
        return VStack(spacing: 0) {
            Spacer(minLength: 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: useGrid3 ? 8 : 16), count: columns),
                      spacing: useGrid3 ? 12 : 16) {
                ForEach(shown) { row in
                    if useGrid3 {
                        ringCell(row, ringSize: 54, lineWidth: 5.5, symbolSize: 18, pctSize: 14, nameSize: 11, showSecondary: false)
                    } else {
                        ringCell(row, ringSize: 80, lineWidth: 8, symbolSize: 23, pctSize: 20, nameSize: 13, showSecondary: true)
                    }
                }
            }
            Spacer(minLength: 8)
            WidgetFooterBar(
                leading: content.staleSyncNote(now: now) ?? "Ring: 5h \(content.metricWord)",
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
    }

    private func ringCell(_ row: DisplayedAccount, ringSize: CGFloat, lineWidth: CGFloat,
                          symbolSize: CGFloat, pctSize: CGFloat, nameSize: CGFloat, showSecondary: Bool) -> some View {
        let values = content.metricValues(for: row)
        let primary = values.first
        let secondary = values.dropFirst().first
        let isValid = primary != nil && row.state != .error && row.state != .unknown

        return VStack(spacing: ringSize > 40 ? 4 : 2) {
            ZStack {
                if let primary, isValid {
                    let (pct, color) = primary.display(content.metric)
                    WidgetRingGauge(percent: pct, color: color, size: ringSize, lineWidth: lineWidth)
                } else {
                    Circle()
                        .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
                        .frame(width: ringSize, height: ringSize)
                }

                Image(systemName: row.symbolName)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(isValid ? .primary : .secondary)
            }
            .overlay(alignment: .topTrailing) {
                if row.state != .fresh {
                    StatusDot(color: row.state.color, size: ringSize > 40 ? 8 : 6)
                }
            }

            if let primary, isValid {
                Text(primary.percentString(content.metric))
                    .font(.system(size: pctSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text(row.state == .error ? "Error" : "—")
                    .font(.system(size: pctSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(row.displayName)
                .font(.system(size: nameSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if showSecondary, let secondary, isValid {
                Text("\(secondary.shortLabel) \(secondary.percentString(content.metric))")
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }
}

// MARK: - Style 3: Per-Agent Linear ("Agent bars" — Weather-like numeral + bars)

private struct PerAgentLinearStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    var body: some View {
        if let row = content.rows.first {
            switch family {
            case .systemSmall:
                smallBody(row)
            case .systemMedium:
                mediumBody(row)
            default:
                largeBody(row)
            }
        }
    }

    private func smallBody(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        return VStack(alignment: .leading, spacing: 4) {
            AccountIdentityHeader(row: row, fontSize: 13, showLabel: false, compactState: true, now: now)
            if values.isEmpty || row.state == .error || row.state == .unknown {
                Spacer(minLength: 0)
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                Spacer(minLength: 0)
            } else if let primary = values.first {
                let (pct, color) = primary.display(content.metric)
                Spacer(minLength: 0)
                Text(primary.qualifiedLabel(content.metric))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(primary.percentString(content.metric))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .widgetAccentableIfAvailable()
                WidgetBarTrack(percent: pct, color: color, height: 6)
                if let reset = primary.resetsAt {
                    Text("Resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let second = values.dropFirst().first {
                    HairlineDivider().padding(.top, 2)
                    LinearMetricLine(value: second, metric: content.metric, now: now,
                                     barHeight: 4, showCountdown: false, labelWidth: 18)
                }
            }
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }

    private func mediumBody(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        return VStack(alignment: .leading, spacing: 8) {
            AccountIdentityHeader(row: row, fontSize: 14, showLabel: true, compactState: false)
            if values.isEmpty || row.state == .error || row.state == .unknown {
                Spacer(minLength: 0)
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(values.prefix(2).enumerated()), id: \.element.id) { idx, value in
                        if idx > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.10))
                                .frame(width: 0.75)
                                .padding(.vertical, 2)
                        }
                        weatherMetricBlock(value, numberSize: 34, barHeight: 6)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let note = content.staleSyncNote(now: now) {
                WidgetFooterBar(leading: note, trailing: nil)
            }
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }

    private func largeBody(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        let others = Array(content.rows.dropFirst().prefix(4))
        let hidden = max(0, content.rows.count - 1 - others.count)

        return VStack(alignment: .leading, spacing: 0) {
            AccountIdentityHeader(row: row, fontSize: 15, showLabel: true, compactState: false)
                .padding(.bottom, 12)

            if values.isEmpty || row.state == .error || row.state == .unknown {
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                    .padding(.vertical, 20)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(values.prefix(2).enumerated()), id: \.element.id) { idx, value in
                        if idx > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.10))
                                .frame(width: 0.75)
                                .padding(.vertical, 2)
                        }
                        weatherMetricBlock(value, numberSize: 44, barHeight: 8)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if !others.isEmpty {
                HairlineDivider().padding(.bottom, 10)
                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { idx, other in
                        if idx > 0 {
                            HairlineDivider().padding(.vertical, 8)
                        }
                        CompactAccountRow(row: other, content: content)
                    }
                }
                Spacer(minLength: 4)
            }

            WidgetFooterBar(
                leading: content.staleSyncNote(now: now),
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }

    private func weatherMetricBlock(_ value: MetricValue, numberSize: CGFloat, barHeight: CGFloat) -> some View {
        let (pct, color) = value.display(content.metric)
        return VStack(alignment: .leading, spacing: 4) {
            Text(value.fullQualifiedLabel(content.metric))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value.percentString(content.metric))
                .font(.system(size: numberSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .widgetAccentableIfAvailable()
            WidgetBarTrack(percent: pct, color: color, height: barHeight)
            if let reset = value.resetsAt {
                Text("Resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))")
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Style 4: Per-Agent Circular ("Agent ring" — Activity-like ring + telemetry)

private struct PerAgentCircularStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    var body: some View {
        if let row = content.rows.first {
            switch family {
            case .systemSmall:
                smallBody(row)
            case .systemMedium:
                mediumBody(row)
            default:
                largeBody(row)
            }
        }
    }

    private func smallBody(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        return VStack(spacing: 4) {
            AccountIdentityHeader(row: row, fontSize: 12, showLabel: false, compactState: true, now: now)
            Spacer(minLength: 0)
            if let primary = values.first, row.state != .error, row.state != .unknown {
                let (pct, color) = primary.display(content.metric)
                ZStack {
                    WidgetRingGauge(percent: pct, color: color, size: 74, lineWidth: 8)
                    VStack(spacing: 0) {
                        Text(primary.percentString(content.metric))
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text(primary.qualifiedLabel(content.metric))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 54)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                if let second = values.dropFirst().first {
                    Text("\(second.shortLabel) \(second.percentString(content.metric)) · \(second.resetsAt.map { UsageFormatting.formatCountdown($0, now: now) } ?? "")")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let reset = primary.resetsAt {
                    Text("Resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                Spacer(minLength: 0)
            }
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }

    private func mediumBody(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                heroRing(row, values: values, size: 96, lineWidth: 10, pctSize: 24)
                VStack(alignment: .leading, spacing: 8) {
                    AccountIdentityHeader(row: row, fontSize: 14, showLabel: true, compactState: false)
                    if values.isEmpty || row.state == .error || row.state == .unknown {
                        RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(values) { value in
                                LinearMetricLine(value: value, metric: content.metric, now: now,
                                                 barHeight: 5, showCountdown: true, labelWidth: 20)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if let note = content.staleSyncNote(now: now) {
                WidgetFooterBar(leading: note, trailing: nil)
            }
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }

    private func largeBody(_ row: DisplayedAccount) -> some View {
        let values = content.metricValues(for: row)
        let others = Array(content.rows.dropFirst().prefix(4))
        let hidden = max(0, content.rows.count - 1 - others.count)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                heroRing(row, values: values, size: 112, lineWidth: 11, pctSize: 26)
                VStack(alignment: .leading, spacing: 10) {
                    AccountIdentityHeader(row: row, fontSize: 15, showLabel: true, compactState: false)
                    if values.isEmpty || row.state == .error || row.state == .unknown {
                        RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(values) { value in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(value.fullQualifiedLabel(content.metric))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(value.percentString(content.metric))
                                            .font(.system(size: 12, weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(.primary)
                                        if let reset = value.resetsAt {
                                            Text("· \(UsageFormatting.formatCountdown(reset, now: now))")
                                                .font(.system(size: 11, weight: .regular))
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    WidgetBarTrack(percent: value.display(content.metric).value,
                                                   color: value.display(content.metric).color, height: 6)
                                }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 12)

            if !others.isEmpty {
                HairlineDivider().padding(.bottom, 10)
                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { idx, other in
                        if idx > 0 {
                            HairlineDivider().padding(.vertical, 8)
                        }
                        CompactAccountRow(row: other, content: content)
                    }
                }
                Spacer(minLength: 4)
            }

            WidgetFooterBar(
                leading: content.staleSyncNote(now: now),
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
        .opacity(row.state == .stale ? 0.85 : 1)
    }

    @ViewBuilder
    private func heroRing(_ row: DisplayedAccount, values: [MetricValue], size: CGFloat, lineWidth: CGFloat, pctSize: CGFloat) -> some View {
        if let primary = values.first, row.state != .error, row.state != .unknown {
            let (pct, color) = primary.display(content.metric)
            ZStack {
                WidgetRingGauge(percent: pct, color: color, size: size, lineWidth: lineWidth)
                VStack(spacing: 1) {
                    Text(primary.percentString(content.metric))
                        .font(.system(size: pctSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(primary.qualifiedLabel(content.metric))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size - lineWidth * 2.4)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        } else {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
                    .frame(width: size, height: size)
                Image(systemName: row.state == .error ? "exclamationmark.triangle" : "minus")
                    .font(.system(size: pctSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Style 5: Concentric Rings ("Concentric" — Activity nested rings)

private struct ConcentricRingsStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    var body: some View {
        switch family {
        case .systemSmall:
            smallBody
        case .systemMedium:
            mediumBody
        default:
            largeBody
        }
    }

    private var smallBody: some View {
        let first = content.rows.first
        let hidden = max(0, content.rows.count - 1)
        return VStack(spacing: 4) {
            if let row = first {
                AccountIdentityHeader(row: row, fontSize: 12, showLabel: false, compactState: true, now: now)
                Spacer(minLength: 0)
                concentricRingView(row, size: 78, lineWidth: 8.5, outerPctSize: 15, innerPctSize: 11)
                Spacer(minLength: 0)
                WidgetFooterBar(
                    leading: "5h · Wk \(content.metricWord)",
                    trailing: hidden > 0 ? "+\(hidden)" : nil
                )
            }
        }
    }

    private var mediumBody: some View {
        let shown = Array(content.rows.prefix(3))
        let hidden = max(0, content.rows.count - shown.count)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                ForEach(shown) { row in
                    VStack(spacing: 4) {
                        concentricRingView(row, size: 78, lineWidth: 8.5, outerPctSize: 14, innerPctSize: 11)
                        HStack(spacing: 4) {
                            Image(systemName: row.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(row.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            StateIndicator(state: row.state, compact: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(row.state == .stale ? 0.85 : 1)
                }
            }
            Spacer(minLength: 0)
            WidgetFooterBar(
                leading: content.staleSyncNote(now: now) ?? "Outer: 5h · Inner: Weekly (\(content.metricWord))",
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
    }

    private var largeBody: some View {
        let useGrid3 = content.rows.count > 4
        let capacity = useGrid3 ? 6 : 4
        let shown = Array(content.rows.prefix(capacity))
        let hidden = max(0, content.rows.count - shown.count)
        let columns = useGrid3 ? 3 : 2
        let ringSize: CGFloat = useGrid3 ? 76 : 100
        let lineWidth: CGFloat = useGrid3 ? 8 : 10

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: useGrid3 ? 8 : 16), count: columns),
                      spacing: useGrid3 ? 16 : 18) {
                ForEach(shown) { row in
                    VStack(spacing: 5) {
                        concentricRingView(row, size: ringSize, lineWidth: lineWidth,
                                           outerPctSize: useGrid3 ? 14 : 18,
                                           innerPctSize: useGrid3 ? 11 : 12)
                        HStack(spacing: 4) {
                            Image(systemName: row.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(row.displayName)
                                .font(.system(size: useGrid3 ? 11 : 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            StateIndicator(state: row.state, compact: true)
                        }
                    }
                    .opacity(row.state == .stale ? 0.85 : 1)
                }
            }
            Spacer(minLength: 0)
            WidgetFooterBar(
                leading: content.staleSyncNote(now: now) ?? "Outer: 5h · Inner: Weekly (\(content.metricWord))",
                trailing: hidden > 0 ? "+\(hidden) more" : nil
            )
        }
    }

    private func concentricRingView(_ row: DisplayedAccount, size: CGFloat, lineWidth: CGFloat,
                                    outerPctSize: CGFloat, innerPctSize: CGFloat) -> some View {
        let values = content.metricValues(for: row)
        let outer = values.first { $0.kind == .fiveHour }
        let inner = values.first { $0.kind == .weekly }
        let isValid = (outer != nil || inner != nil) && row.state != .error && row.state != .unknown
        let outerDisplay = outer?.display(content.metric)
        let innerDisplay = inner?.display(content.metric)

        return ZStack {
            if isValid {
                WidgetConcentricRingsGauge(
                    outerPercent: outerDisplay?.value,
                    outerColor: outerDisplay?.color ?? .clear,
                    innerPercent: innerDisplay?.value,
                    innerColor: innerDisplay?.color ?? .clear,
                    size: size,
                    lineWidth: lineWidth
                )
                VStack(spacing: 0) {
                    if let outer {
                        Text(outer.percentString(content.metric))
                            .font(.system(size: outerPctSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    if let inner {
                        Text(inner.percentString(content.metric))
                            .font(.system(size: innerPctSize, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: max(24, size - lineWidth * 4.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
                    .frame(width: size, height: size)
                Image(systemName: row.state == .error ? "exclamationmark.triangle" : "minus")
                    .font(.system(size: outerPctSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Style 6: Single Agent Focus ("Focus" — Hero number that matters)

private struct SingleAgentFocusStyle: View {
    let content: QuotaWidgetContent
    let family: WidgetFamily
    let now: Date

    var body: some View {
        if let row = content.rows.first {
            let values = content.metricValues(for: row)
            // Dominant metric = highest used% (closest to running out).
            let dominant = values.max { $0.used < $1.used }
            Group {
                switch family {
                case .systemSmall:
                    smallBody(row, dominant: dominant)
                case .systemMedium:
                    mediumBody(row, values: values, dominant: dominant)
                default:
                    largeBody(row, values: values, dominant: dominant)
                }
            }
            .opacity(row.state == .stale ? 0.85 : 1)
        }
    }

    private func smallBody(_ row: DisplayedAccount, dominant: MetricValue?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AccountIdentityHeader(row: row, fontSize: 13, showLabel: false, compactState: true, now: now)
            Spacer(minLength: 0)
            if let dominant, row.state != .error, row.state != .unknown {
                let (pct, color) = dominant.display(content.metric)
                Text(dominant.percentString(content.metric))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .widgetAccentableIfAvailable()
                Text(dominant.fullQualifiedLabel(content.metric))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let reset = dominant.resetsAt {
                    Text("Resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                WidgetBarTrack(percent: pct, color: color, height: 6)
            } else {
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                Spacer(minLength: 0)
            }
        }
    }

    private func mediumBody(_ row: DisplayedAccount, values: [MetricValue], dominant: MetricValue?) -> some View {
        let secondary = dominant.flatMap { dom in values.first { $0.kind != dom.kind } }
        return VStack(alignment: .leading, spacing: 6) {
            AccountIdentityHeader(row: row, fontSize: 14, showLabel: true, compactState: false)
            Spacer(minLength: 0)
            if let dominant, row.state != .error, row.state != .unknown {
                let (pct, color) = dominant.display(content.metric)
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dominant.percentString(content.metric))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .widgetAccentableIfAvailable()
                        Text(dominant.fullQualifiedLabel(content.metric))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let reset = dominant.resetsAt {
                            Text("Resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))")
                                .font(.system(size: 11, weight: .regular))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        WidgetBarTrack(percent: pct, color: color, height: 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let secondary {
                        let (secPct, secColor) = secondary.display(content.metric)
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(width: 0.75)
                            .padding(.vertical, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(secondary.fullQualifiedLabel(content.metric))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(secondary.percentString(content.metric))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            WidgetBarTrack(percent: secPct, color: secColor, height: 5)
                            if let reset = secondary.resetsAt {
                                Text("Resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))")
                                    .font(.system(size: 11, weight: .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 116, alignment: .leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
            }
            Spacer(minLength: 0)
            if let note = content.staleSyncNote(now: now) {
                WidgetFooterBar(leading: note, trailing: nil)
            }
        }
    }

    private func largeBody(_ row: DisplayedAccount, values: [MetricValue], dominant: MetricValue?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountIdentityHeader(row: row, fontSize: 15, showLabel: true, compactState: false)
            if let dominant, row.state != .error, row.state != .unknown {
                let (pct, color) = dominant.display(content.metric)
                Spacer(minLength: 10)
                Text(dominant.percentString(content.metric))
                    .font(.system(size: 74, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .widgetAccentableIfAvailable()
                Text(dominantSubtitle(dominant))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 10)
                WidgetBarTrack(percent: pct, color: color, height: 8)
                Spacer(minLength: 16)

                // The hero already shows the dominant metric; list only the rest.
                let others = values.filter { $0.kind != dominant.kind }
                if !others.isEmpty {
                    HairlineDivider().padding(.bottom, 12)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { idx, value in
                            if idx > 0 {
                                HairlineDivider()
                            }
                            largeMetricDetail(value)
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
                RowPlaceholderText(row: row, hasMetricsSelected: !content.metrics(for: row).isEmpty)
                Spacer(minLength: 0)
            }
            if let note = content.staleSyncNote(now: now) {
                WidgetFooterBar(leading: note, trailing: nil)
                    .padding(.top, 8)
            }
        }
    }

    private func largeMetricDetail(_ value: MetricValue) -> some View {
        let (pct, color) = value.display(content.metric)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(value.fullQualifiedLabel(content.metric))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.percentString(content.metric))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let reset = value.resetsAt {
                    Text("· Resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            WidgetBarTrack(percent: pct, color: color, height: 6)
        }
    }

    private func dominantSubtitle(_ dominant: MetricValue) -> String {
        let base = dominant.fullQualifiedLabel(content.metric)
        guard let reset = dominant.resetsAt else { return base }
        return "\(base) · Resets \(UsageFormatting.formatCountdown(reset, inPrefix: true, now: now))"
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
