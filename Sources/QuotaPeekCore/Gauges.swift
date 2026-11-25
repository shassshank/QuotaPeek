import SwiftUI

// Visual building blocks shared by the desktop panel and the native widget.

/// A capsule badge with custom or default styling.
public struct CapsuleBadge: View {
    let text: String
    let color: Color
    var font: Font
    var hPadding: CGFloat
    var vPadding: CGFloat

    public init(text: String, color: Color, font: Font = .caption2.weight(.medium), hPadding: CGFloat = 6, vPadding: CGFloat = 2) {
        self.text = text
        self.color = color
        self.font = font
        self.hPadding = hPadding
        self.vPadding = vPadding
    }

    public var body: some View {
        Text(text)
            .font(font)
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A compact linear progress bar with rounded ends and animated fill.
public struct LinearProgressBar: View {
    let percent: Double
    let color: Color
    var height: CGFloat

    public init(percent: Double, color: Color, height: CGFloat = 5) {
        self.percent = percent
        self.color = color
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: height)

                Capsule()
                    .fill(color)
                    .frame(
                        width: max(0, min(geo.size.width, geo.size.width * CGFloat(min(max(percent, 0), 100) / 100.0))),
                        height: height
                    )
                    .animation(.easeInOut(duration: 0.3), value: percent)
            }
        }
        .frame(height: height)
    }
}

/// A circular progress ring rendered using SwiftUI `Circle().trim`.
public struct CircularRingProgress: View {
    let percent: Double
    let color: Color
    var lineWidth: CGFloat
    var size: CGFloat

    public init(percent: Double, color: Color, lineWidth: CGFloat = 5, size: CGFloat = 46) {
        self.percent = percent
        self.color = color
        self.lineWidth = lineWidth
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent / 100.0, 0), 1)))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: percent)
        }
        .frame(width: size, height: size)
    }
}
