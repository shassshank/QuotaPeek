import Foundation
import QuotaPeekCore

/// Publishes the latest per-account numbers to `snapshot.json` (the
/// `QuotaSnapshot` contract in QuotaPeekCore) for the statusline hooks and
/// the native widget. Written atomically and only when the content changes;
/// each change also asks the widget to reload. Removed when the app quits so
/// readers stop showing numbers from a QuotaPeek that isn't running.
@MainActor
final class SnapshotWriter {
    private let url: URL
    private let queue = DispatchQueue(label: "com.quotapeek.snapshot", qos: .utility)
    private let reloader: WidgetReloader
    private var lastWritten: QuotaSnapshot?

    init(url: URL = QuotaSnapshot.fileURL, reloader: WidgetReloader? = nil) {
        self.url = url
        self.reloader = reloader ?? WidgetReloader()
    }

    func update(accounts: [Account], showOtherAgents: Bool, display: QuotaSnapshot.Display,
                nativeWidget: QuotaSnapshot.NativeWidget) {
        let snapshot = QuotaSnapshot(
            pid: Int(getpid()),
            statuslineShowOtherAgents: showOtherAgents,
            display: display,
            nativeWidget: nativeWidget,
            accounts: accounts.filter { !$0.routesEnabled.isEmpty }.map {
                QuotaSnapshot.Account(id: $0.id, provider: $0.provider, label: $0.label,
                                      state: $0.state, data: $0.data, asOf: $0.asOf)
            }
        )
        guard snapshot != lastWritten else { return }
        lastWritten = snapshot
        let url = self.url
        let reloader = self.reloader
        queue.async {
            do {
                try snapshot.encoded().write(to: url, options: .atomic)
                Task { @MainActor in reloader.snapshotChanged() }
            } catch {
                ErrorLog.warning("snapshot write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Synchronous so it completes before the process exits.
    func remove() {
        lastWritten = nil
        queue.sync { try? FileManager.default.removeItem(at: url) }
        reloader.reloadNow()
    }
}
