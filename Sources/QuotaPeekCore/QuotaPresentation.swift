import Foundation

/// One row a widget shows: an account, or Antigravity's Claude/GPT pool
/// presented as its own row (id `<account id>:claude_gpt`), exactly as the
/// desktop panel does.
public struct DisplayedAccount: Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: Provider
    public var displayName: String
    public var symbolName: String
    public var label: String
    public var state: AccountTrustState
    public var data: ProviderData?
    public var asOf: Int64?

    public init(id: String, provider: Provider, displayName: String, symbolName: String, label: String,
                state: AccountTrustState, data: ProviderData?, asOf: Int64?) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.symbolName = symbolName
        self.label = label
        self.state = state
        self.data = data
        self.asOf = asOf
    }

    /// The label is worth showing only when it distinguishes accounts.
    public var visibleLabel: String? {
        label.isEmpty || label == "Default" ? nil : label
    }
}

public enum QuotaPresentation {
    public static let claudeGptSuffix = ":claude_gpt"

    /// Rows in the user's provider order, filtered to `includedIds` (nil = all),
    /// with the Antigravity Claude/GPT pool split out when enabled.
    public static func displayedAccounts(_ accounts: [QuotaSnapshot.Account],
                                         display: QuotaSnapshot.Display,
                                         includedIds: Set<String>? = nil) -> [DisplayedAccount] {
        let rank = Dictionary(uniqueKeysWithValues: display.providerOrder.enumerated().map { ($1, $0) })
        let ordered = accounts.enumerated().sorted { a, b in
            let ra = rank[a.element.provider] ?? Int.max, rb = rank[b.element.provider] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)

        var rows: [DisplayedAccount] = []
        for account in ordered {
            let row = DisplayedAccount(id: account.id, provider: account.provider,
                                       displayName: account.provider.displayName,
                                       symbolName: account.provider.symbolName, label: account.label,
                                       state: account.state, data: account.data, asOf: account.asOf)
            if includedIds?.contains(row.id) ?? true { rows.append(row) }

            let poolId = account.id + claudeGptSuffix
            if account.provider == .antigravity, display.showAntigravityModelBreakdown,
               includedIds?.contains(poolId) ?? true, let pool = account.data?.thirdPartyPool {
                rows.append(DisplayedAccount(id: poolId, provider: .antigravity, displayName: "Claude/GPT",
                                             symbolName: "sparkles", label: account.label,
                                             state: account.state, data: pool, asOf: account.asOf))
            }
        }
        return rows
    }

    /// Rows the native widget shows, per the selection made in Settings.
    public static func nativeWidgetAccounts(_ snapshot: QuotaSnapshot) -> [DisplayedAccount] {
        displayedAccounts(snapshot.accounts, display: snapshot.display,
                          includedIds: snapshot.nativeWidget.includedAccountIds.map(Set.init))
    }

    /// Every selectable row (for a widget's agent picker), ignoring selection.
    public static func selectableAccounts(_ snapshot: QuotaSnapshot) -> [DisplayedAccount] {
        displayedAccounts(snapshot.accounts, display: snapshot.display, includedIds: nil)
    }
}
