import Foundation

/// `snapshot.json`: the app's latest per-account numbers plus the display
/// preferences a reader needs to render them. Written by the app (only when
/// something changes, atomically), read by the statusline hooks and the
/// widget extension. Version 1 is shared with the hooks: only add fields.
public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var provider: Provider
        public var label: String
        public var state: AccountTrustState
        public var data: ProviderData?
        public var asOf: Int64?

        public init(id: String, provider: Provider, label: String, state: AccountTrustState, data: ProviderData?, asOf: Int64?) {
            self.id = id
            self.provider = provider
            self.label = label
            self.state = state
            self.data = data
            self.asOf = asOf
        }

        enum CodingKeys: String, CodingKey {
            case id, provider, label, state, data
            case asOf = "as_of"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = try c.decode(Provider.self, forKey: .provider)
            // Older snapshots had no id; fall back to the provider so the
            // widget can still address the account.
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? provider.rawValue
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            state = (try? c.decode(AccountTrustState.self, forKey: .state)) ?? .unknown
            data = try? c.decodeIfPresent(ProviderData.self, forKey: .data)
            asOf = try? c.decodeIfPresent(Int64.self, forKey: .asOf)
        }
    }

    /// App-wide display preferences that every surface must honour.
    public struct Display: Codable, Equatable, Sendable {
        public var percentageMetric: PercentageMetric
        public var providerOrder: [Provider]
        public var showAntigravityModelBreakdown: Bool

        public init(percentageMetric: PercentageMetric = .used,
                    providerOrder: [Provider] = Provider.allCases,
                    showAntigravityModelBreakdown: Bool = true) {
            self.percentageMetric = percentageMetric
            self.providerOrder = providerOrder
            self.showAntigravityModelBreakdown = showAntigravityModelBreakdown
        }

        enum CodingKeys: String, CodingKey {
            case percentageMetric = "percentage_metric"
            case providerOrder = "provider_order"
            case showAntigravityModelBreakdown = "show_antigravity_model_breakdown"
        }
    }

    /// What the native widget shows, chosen in QuotaPeek's Settings (the
    /// widget's style is picked per instance in the widget gallery).
    public struct NativeWidget: Codable, Equatable, Sendable {
        /// nil = every account, including ones added later.
        public var includedAccountIds: [String]?
        /// Metrics for accounts without a per-account choice.
        public var visibleMetrics: [WidgetMetricKind]
        public var accountMetrics: [String: [WidgetMetricKind]]

        public init(includedAccountIds: [String]? = nil,
                    visibleMetrics: [WidgetMetricKind] = WidgetMetricKind.offerable,
                    accountMetrics: [String: [WidgetMetricKind]] = [:]) {
            self.includedAccountIds = includedAccountIds
            self.visibleMetrics = visibleMetrics
            self.accountMetrics = accountMetrics
        }

        public func metrics(for accountId: String) -> Set<WidgetMetricKind> {
            Set(accountMetrics[accountId] ?? visibleMetrics)
        }

        enum CodingKeys: String, CodingKey {
            case includedAccountIds = "included_account_ids"
            case visibleMetrics = "visible_metrics"
            case accountMetrics = "account_metrics"
        }
    }

    public var v: Int
    /// Lets readers ignore a snapshot left behind by a crashed app.
    public var pid: Int
    public var statuslineShowOtherAgents: Bool
    public var display: Display
    public var nativeWidget: NativeWidget
    public var accounts: [Account]

    public init(pid: Int, statuslineShowOtherAgents: Bool, display: Display,
                nativeWidget: NativeWidget = NativeWidget(), accounts: [Account]) {
        self.v = 1
        self.pid = pid
        self.statuslineShowOtherAgents = statuslineShowOtherAgents
        self.display = display
        self.nativeWidget = nativeWidget
        self.accounts = accounts
    }

    enum CodingKeys: String, CodingKey {
        case v, pid, display, accounts
        case statuslineShowOtherAgents = "statusline_show_other_agents"
        case nativeWidget = "native_widget"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        statuslineShowOtherAgents = try c.decodeIfPresent(Bool.self, forKey: .statuslineShowOtherAgents) ?? true
        display = (try? c.decodeIfPresent(Display.self, forKey: .display)) ?? Display()
        nativeWidget = (try? c.decodeIfPresent(NativeWidget.self, forKey: .nativeWidget)) ?? NativeWidget()
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
    }

    // MARK: Location and I/O

    /// The user's real home directory. `NSHomeDirectory()` points inside the
    /// container in the sandboxed widget, so resolve it from the passwd entry.
    public static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    public static var supportDirectory: URL {
        URL(fileURLWithPath: realHomeDirectory)
            .appendingPathComponent("Library/Application Support/QuotaPeek", isDirectory: true)
    }

    public static var fileURL: URL { supportDirectory.appendingPathComponent("snapshot.json") }

    public enum ReadResult: Equatable, Sendable {
        case snapshot(QuotaSnapshot)
        /// No file: QuotaPeek isn't running (it removes the file on quit).
        case appNotRunning
        /// Present but unreadable (sandbox denied, corrupt, newer version).
        case unreadable(String)
    }

    public static func read(from url: URL = fileURL) -> ReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .appNotRunning
        } catch {
            return .unreadable(error.localizedDescription)
        }
        guard data.count < 1 << 20 else { return .unreadable("snapshot too large") }
        do {
            let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
            guard snapshot.v == 1 else { return .unreadable("unsupported snapshot version \(snapshot.v)") }
            return .snapshot(snapshot)
        } catch {
            return .unreadable("corrupt snapshot")
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
