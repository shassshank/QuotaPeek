#!/usr/bin/env swift
import Foundation
import Security

let keychainService = "gemini"
let keychainAccount = "antigravity"
let keyringPrefix = "go-keyring-base64:"
let endpoints = [
    URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
    URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
]

func readKeychainData(service: String, account: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
        print("Keychain lookup failed with status \(status)")
        return nil
    }
    return result as? Data
}

func redact(_ text: String) -> String {
    var redacted = text
    let patterns = [
        #"ya29\.[A-Za-z0-9._-]+"#,
        #""access_token"\s*:\s*"[^"]+""#,
        #""refresh_token"\s*:\s*"[^"]+""#,
        #""id_token"\s*:\s*"[^"]+""#,
    ]
    for pattern in patterns {
        redacted = redacted.replacingOccurrences(
            of: pattern,
            with: pattern.contains("access_token") ? #""access_token":"<redacted>""# : "<redacted>",
            options: .regularExpression
        )
    }
    return redacted
}

guard
    let rawData = readKeychainData(service: keychainService, account: keychainAccount),
    let raw = String(data: rawData, encoding: .utf8)
else {
    exit(1)
}

guard raw.hasPrefix(keyringPrefix) else {
    print("Credential did not have expected \(keyringPrefix) prefix")
    exit(1)
}

let encoded = String(raw.dropFirst(keyringPrefix.count))
guard
    let decodedData = Data(base64Encoded: encoded),
    let jsonObject = try? JSONSerialization.jsonObject(with: decodedData),
    let json = jsonObject as? [String: Any]
else {
    print("Could not decode credential JSON")
    exit(1)
}

let tokenDict = json["token"] as? [String: Any]
let accessToken = (tokenDict?["access_token"] as? String) ?? (json["access_token"] as? String)
guard let accessToken, !accessToken.isEmpty else {
    print("Credential JSON had no access token")
    exit(1)
}

print("Decoded credential JSON top-level keys: \(json.keys.sorted())")
if let tokenDict {
    print("Decoded token object keys: \(tokenDict.keys.sorted())")
}
print("Token present: yes (redacted)")

let project = (json["project"] as? String) ?? (json["project_id"] as? String) ?? (json["quota_project"] as? String)
let requestBodies: [[String: Any]] = project.map { [[:], ["project": $0]] } ?? [[:]]

let semaphore = DispatchSemaphore(value: 0)
let session = URLSession(configuration: .ephemeral)

for endpoint in endpoints {
    for body in requestBodies {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        print("\n=== \(endpoint.absoluteString)")
        print("Request body: \(body.isEmpty ? "{}" : String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "{}")")

        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                print("Error: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                print("No HTTP response")
                return
            }
            print("Status: \(http.statusCode)")
            print("Headers:")
            for key in http.allHeaderFields.keys.sorted(by: { "\($0)" < "\($1)" }) {
                print("  \(key): \(http.allHeaderFields[key] ?? "")")
            }
            if let data, !data.isEmpty {
                let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
                print("Body preview:")
                print(String(redact(text).prefix(4000)))
            } else {
                print("Body preview: <empty>")
            }
        }.resume()

        _ = semaphore.wait(timeout: .now() + 30)
    }
}
