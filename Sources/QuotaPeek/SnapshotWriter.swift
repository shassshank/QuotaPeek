import Foundation

/// Publishes the latest per-account numbers to `snapshot.json` for the
/// statusline hooks' "other agents" segment. Same shape as the subset of the
/// daemon's `/status` the hooks read, so hooks need no special casing. Written
/// atomically (temp file + rename) and only when the content changes; removed
/// when the app quits so hooks drop the segment instead of showing stale data.
@MainActor
final class SnapshotWriter {
    private struct Snapshot: Encodable, Equatable {
        struct Entry: Encodable, Equatable {
            var provider: Provider
            var label: String
            var state: AccountTrustState
            var data: ProviderData?
            var asOf: Int64?

            enum CodingKeys: String, CodingKey {
                case provider, label, state, data
                case asOf = "as_of"
            }
        }

        var v = 1
        /// Lets hooks ignore a snapshot left behind by a crashed app.
        var pid = Int(getpid())
        var statuslineShowOtherAgents: Bool
        var accounts: [Entry]

        enum CodingKeys: String, CodingKey {
            case v, pid
            case statuslineShowOtherAgents = "statusline_show_other_agents"
            case accounts
        }
    }

    private let url: URL
    private let queue = DispatchQueue(label: "com.quotapeek.snapshot", qos: .utility)
    private var lastWritten: Snapshot?

    init(url: URL = AppPaths.snapshotURL) {
        self.url = url
    }

    func update(accounts: [Account], showOtherAgents: Bool) {
        let snapshot = Snapshot(
            statuslineShowOtherAgents: showOtherAgents,
            accounts: accounts.map {
                .init(provider: $0.provider, label: $0.label, state: $0.state, data: $0.data, asOf: $0.asOf)
            }
        )
        guard snapshot != lastWritten else { return }
        lastWritten = snapshot
        let url = self.url
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                ErrorLog.warning("snapshot write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Synchronous so it completes before the process exits.
    func remove() {
        lastWritten = nil
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}
