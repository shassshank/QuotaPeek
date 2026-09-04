import Foundation

/// Antigravity exposes quota to its own CLI, but this account/tier does not provide
/// parseable quota data in local state and rejects direct Code Assist quota calls.
final class AntigravityUsageCollector {
    private struct CredentialError: Error {
        let message: String
    }

    private static let keychainService = "gemini"
    private static let keychainAccount = "antigravity"
    private static let keyringPrefix = "go-keyring-base64:"

    func refreshCache() async {
        UsageCache.merge(provider: "antigravity", usage: fetch())
    }

    func fetch() -> ProviderUsage {
        switch Self.checkCredentialPresence() {
        case .success:
            return ProviderUsage(
                updatedAt: Int(Date().timeIntervalSince1970),
                error: "Antigravity quota is not available for this account (Google backend returns UNSUPPORTED_CLIENT for individual accounts)"
            )
        case .failure(let error):
            return ProviderUsage(
                updatedAt: Int(Date().timeIntervalSince1970),
                error: error.message
            )
        }
    }

    private static func checkCredentialPresence() -> Result<Void, CredentialError> {
        guard let raw = KeychainReader.readString(service: keychainService, account: keychainAccount) else {
            return .failure(CredentialError(message: "Antigravity credentials not found in Keychain (service \"gemini\", account \"antigravity\")"))
        }
        guard raw.hasPrefix(keyringPrefix) else {
            return .failure(CredentialError(message: "Antigravity Keychain credential did not have expected go-keyring-base64 prefix"))
        }
        let encoded = String(raw.dropFirst(keyringPrefix.count))
        guard Data(base64Encoded: encoded) != nil else {
            return .failure(CredentialError(message: "Could not base64-decode Antigravity Keychain credential"))
        }
        return .success(())
    }
}
