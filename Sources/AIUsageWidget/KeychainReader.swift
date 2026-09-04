import Foundation
import Security

/// Reads generic-password Keychain items. Never edits or creates entries — the app only ever
/// asks macOS for a value that another app (Claude Code, Antigravity) already stored, and macOS
/// shows its own per-app access dialog the first time. If the user denies it, we just get nil back.
enum KeychainReader {
    static func readData(service: String, account: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func readString(service: String, account: String? = nil) -> String? {
        guard let data = readData(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
