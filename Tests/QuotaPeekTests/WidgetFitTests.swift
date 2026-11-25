import QuotaPeekCore
import QuotaPeekWidgetUI
import SwiftUI
import WidgetKit
import XCTest

/// Every style must fit the content area the system gives it. Sizes are the
/// measured macOS desktop geometry: widget minus 18 pt system margins.
@MainActor
final class WidgetFitTests: XCTestCase {
    static let contentSizes: [(WidgetFamily, CGSize)] = [
        (.systemSmall, CGSize(width: 128, height: 128)),
        (.systemMedium, CGSize(width: 308, height: 128)),
        (.systemLarge, CGSize(width: 308, height: 308)),
    ]

    /// Ideal height of a style at the content width (height unconstrained).
    private func idealHeight(_ style: DesktopWidgetStyle, _ family: WidgetFamily, width: CGFloat,
                             content: QuotaWidgetContent) -> CGFloat {
        let view = QuotaWidgetView(entry: QuotaEntry(date: Date(), state: .ready(content)), style: style, family: family)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.nsImage?.size.height ?? .infinity
    }

    func testEveryStyleFitsEverySize() {
        var single = QuotaWidgetContent.sample
        single.rows = Array(single.rows.prefix(1))
        // Real-world variants: "remaining" wording, stale/restored rows with
        // an old sync time (adds the "updated …" note), full and empty usage.
        var remaining = QuotaWidgetContent.sample
        remaining.metric = .remaining
        var stale = remaining
        stale.rows = stale.rows.enumerated().map { i, row in
            var r = row
            r.state = i % 2 == 0 ? .restored : .stale
            r.asOf = Int64(Date().timeIntervalSince1970) - 3 * 3600
            r.data?.usedPercent5h = i % 2 == 0 ? 100 : 0
            return r
        }
        var staleSingle = stale
        staleSingle.rows = Array(stale.rows.prefix(1))
        var overflow: [String] = []
        for content in [QuotaWidgetContent.sample, single, remaining, stale, staleSingle] {
            for style in DesktopWidgetStyle.allCases {
                for (family, size) in Self.contentSizes {
                    let h = idealHeight(style, family, width: size.width, content: content)
                    if h > size.height + 0.5 {
                        overflow.append("\(style.rawValue) \(family) rows=\(content.rows.count): \(Int(h.rounded())) > \(Int(size.height))")
                    }
                }
            }
        }
        XCTAssertTrue(overflow.isEmpty, "Overflowing widgets:\n" + overflow.joined(separator: "\n"))
    }
}
