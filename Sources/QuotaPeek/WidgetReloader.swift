import Foundation
import WidgetKit

/// Asks WidgetKit to reload the native widget when the snapshot changes.
///
/// Leading edge plus a trailing reload: the first change reloads at once,
/// changes within the next `minInterval` collapse into one reload at the end
/// of it. Measured on macOS 27, app-requested reloads of a visible widget are
/// delivered in ~0.15 s and were not throttled even at 300+/hour (plugged in,
/// battery, Low Power Mode), but Apple documents a 40-70/day budget, so stay
/// well inside a few hundred a day. The widget also refreshes itself every 15
/// minutes and pre-schedules entries at each reset, so a dropped reload only
/// delays numbers, never leaves them wrong for long.
@MainActor
final class WidgetReloader {
    private let minInterval: TimeInterval
    private let reload: () -> Void
    private var lastReload: Date = .distantPast
    private var trailing: DispatchWorkItem?

    /// Reloads every QuotaPeek widget kind (one per style).
    init(minInterval: TimeInterval = 30,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.minInterval = minInterval
        self.reload = reload
    }

    func snapshotChanged(now: Date = Date()) {
        let wait = minInterval - now.timeIntervalSince(lastReload)
        if wait <= 0 {
            fire(now)
        } else if trailing == nil {
            let work = DispatchWorkItem { [weak self] in self?.fire(Date()) }
            trailing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    /// Immediate reload (e.g. on quit, so the widget shows "not running").
    func reloadNow() {
        fire(Date())
    }

    private func fire(_ now: Date) {
        trailing?.cancel()
        trailing = nil
        lastReload = now
        reload()
    }
}
