import QuotaPeekCore
import QuotaPeekWidgetUI
import SwiftUI
import WidgetKit
import XCTest

/// Renders every widget style x size with sample data to PNGs, for visual
/// review without installing: `QP_PREVIEW_DIR=/tmp/qp swift test --filter WidgetPreviewRenderer`.
@MainActor
final class WidgetPreviewRenderer: XCTestCase {
    /// macOS 27 desktop widget sizes, measured on device via WidgetGeometryProbe
    /// (large: 344x344 with 18 pt margins; small/medium follow the same grid).
    static let sizes: [(WidgetFamily, CGSize, String)] = [
        (.systemSmall, CGSize(width: 164, height: 164), "small"),
        (.systemMedium, CGSize(width: 344, height: 164), "medium"),
        (.systemLarge, CGSize(width: 344, height: 344), "large"),
    ]
    /// System content margins on the desktop (measured).
    static let margin: CGFloat = 18

    func testRenderAllStyles() throws {
        guard let dir = ProcessInfo.processInfo.environment["QP_PREVIEW_DIR"] else {
            throw XCTSkip("set QP_PREVIEW_DIR to render previews")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let entry = QuotaEntry(date: Date(), state: .ready(.sample))
        for scheme in [ColorScheme.light, .dark] {
            for style in DesktopWidgetStyle.allCases {
                for (family, size, name) in Self.sizes {
                    let view = QuotaWidgetView(entry: entry, style: style, family: family)
                        .padding(Self.margin) // stands in for the system content margins
                        .frame(width: size.width, height: size.height)
                        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.nsImage)
                    let tiff = try XCTUnwrap(image.tiffRepresentation)
                    let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                    try png.write(to: out.appendingPathComponent("\(style.rawValue)-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
        // One contact sheet per colour scheme: a row per style, all sizes.
        for scheme in [ColorScheme.light, .dark] {
            let sheet = VStack(alignment: .leading, spacing: 18) {
                ForEach(DesktopWidgetStyle.allCases) { style in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(style.displayName).font(.system(size: 13, weight: .semibold))
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(Self.sizes, id: \.2) { family, size, _ in
                                QuotaWidgetView(entry: entry, style: style, family: family)
                                    .padding(Self.margin)
                                    .frame(width: size.width, height: size.height)
                                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            }
                        }
                    }
                }
            }
            .padding(24)
            .background(scheme == .dark ? Color(white: 0.06) : Color(white: 0.82))
            .environment(\.colorScheme, scheme)
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 1.5
            let tiff = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
            try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("sheet-\(scheme == .dark ? "dark" : "light").png"))
        }

        for (state, name) in [(QuotaWidgetState.notRunning, "not-running"), (.ready(QuotaWidgetContent(rows: [], metric: .used, selection: .init())), "empty")] {
            let view = QuotaWidgetView(entry: QuotaEntry(date: Date(), state: state), style: .combinedLinear, family: .systemSmall)
                .padding(Self.margin).frame(width: 164, height: 164).background(Color(white: 0.96))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let tiff = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
            try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("state-\(name).png"))
        }
    }
}
