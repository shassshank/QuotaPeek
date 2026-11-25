import QuotaPeekCore
import SwiftUI

extension View {
    /// Marks key gauges and hero numerals as accented in macOS 14+ Vibrant/Tinted mode.
    @ViewBuilder
    func widgetAccentableIfAvailable(_ isAccentable: Bool = true) -> some View {
        if #available(macOS 14.0, *) {
            widgetAccentable(isAccentable)
        } else {
            self
        }
    }
}

/// Capsule progress track designed for both full-color and macOS Vibrant widget modes.
struct WidgetBarTrack: View {
    let percent: Double
    let color: Color
    var height: CGFloat = 5

    private var clampedFraction: CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100.0)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let rawFill = width * clampedFraction
            let fillWidth = percent > 0 ? max(height, min(width, rawFill)) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.11))
                    .frame(height: height)

                if fillWidth > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: fillWidth, height: height)
                        .widgetAccentableIfAvailable()
                }
            }
        }
        .frame(height: height)
    }
}

/// Circular progress ring with neutral track so it reads clearly in Vibrant mode and light/dark.
struct WidgetRingGauge: View {
    let percent: Double
    let color: Color
    var size: CGFloat
    var lineWidth: CGFloat

    private var clampedFraction: CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100.0)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.11), lineWidth: lineWidth)

            if clampedFraction > 0 {
                Circle()
                    .trim(from: 0, to: clampedFraction)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentableIfAvailable()
            }
        }
        .frame(width: size, height: size)
    }
}

/// Activity-style nested rings: outer 5h, inner weekly.
struct WidgetConcentricRingsGauge: View {
    let outerPercent: Double?
    let outerColor: Color
    let innerPercent: Double?
    let innerColor: Color
    let size: CGFloat
    let lineWidth: CGFloat

    private var ringGap: CGFloat { max(2.5, lineWidth * 0.28) }
    private var innerSize: CGFloat { max(16, size - (lineWidth + ringGap) * 2) }

    var body: some View {
        ZStack {
            if let outerPercent {
                WidgetRingGauge(percent: outerPercent, color: outerColor, size: size, lineWidth: lineWidth)
            } else {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
                    .frame(width: size, height: size)
            }

            if let innerPercent {
                WidgetRingGauge(percent: innerPercent, color: innerColor, size: innerSize, lineWidth: lineWidth)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Small semantic status dot paired with primary-colored numbers so yellow never hurts text contrast.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .widgetAccentableIfAvailable()
    }
}

/// Subtle 0.5pt hairline separator matching Apple's Stocks and Reminders widgets.
struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 0.75)
    }
}
