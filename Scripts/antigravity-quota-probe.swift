#!/usr/bin/env swift
import Foundation
import Security

let keychainService = "gemini"
let keychainAccount = "antigravity"
let keyringPrefix = "go-keyring-base64:"
let discoveryEndpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
let quotaEndpoints = [
    URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!,
    URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
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

func clientMetadata() -> [String: Any] {
    [
        "ideType": "ANTIGRAVITY",
        "platform": "DARWIN_ARM64",
        "pluginType": "GEMINI",
    ]
}

func applyHeaders(to request: inout URLRequest, accessToken: String) {
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("google-api-nodejs-client/9.15.1", forHTTPHeaderField: "User-Agent")
    request.setValue(
        "{\"ideType\":\"ANTIGRAVITY\",\"platform\":\"DARWIN_ARM64\",\"pluginType\":\"GEMINI\"}",
        forHTTPHeaderField: "Client-Metadata"
    )
}

func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func jsonString(_ object: Any) -> String {
    guard
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
}

func quotaBody(project: String?) -> [String: Any] {
    guard let project = trimmedNonEmpty(project) else {
        return [:]
    }
    return ["project": project]
}

@discardableResult
func performRequest(
    label: String,
    endpoint: URL,
    body: [String: Any],
    accessToken: String,
    session: URLSession,
    semaphore: DispatchSemaphore
) -> [String: Any]? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    applyHeaders(to: &request, accessToken: accessToken)
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    print("\n=== \(label): \(endpoint.absoluteString)")
    print("Request body: \(jsonString(body))")

    var parsedJSON: [String: Any]?
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
            if (200...299).contains(http.statusCode),
               let object = try? JSONSerialization.jsonObject(with: data),
               let json = object as? [String: Any] {
                parsedJSON = json
            }
        } else {
            print("Body preview: <empty>")
        }
    }.resume()

    _ = semaphore.wait(timeout: .now() + 30)
    return parsedJSON
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
print("Client metadata: \(jsonString(clientMetadata()))")
print("Discovery endpoint: \(discoveryEndpoint.absoluteString)")
print("Discovery project seed: <none>")
print("Default project cache: ignored")

let semaphore = DispatchSemaphore(value: 0)
let session = URLSession(configuration: .ephemeral)

let discoveryBody: [String: Any] = [
    "metadata": clientMetadata(),
]

let discoveryJSON = performRequest(
    label: "Discovery loadCodeAssist",
    endpoint: discoveryEndpoint,
    body: discoveryBody,
    accessToken: accessToken,
    session: session,
    semaphore: semaphore
)

let discoveredProject = trimmedNonEmpty(discoveryJSON?["cloudaicompanionProject"] as? String)
    ?? trimmedNonEmpty((discoveryJSON?["cloudaicompanionProject"] as? [String: Any])?["id"] as? String)

if let discoveredProject {
    print("\nDiscovered cloudaicompanionProject: \(discoveredProject)")
} else {
    print("\nDiscovered cloudaicompanionProject: <none>; quota calls will omit project")
}
if let currentTier = discoveryJSON?["currentTier"] as? [String: Any] {
    print("Current tier keys: \(currentTier.keys.sorted())")
    print("Current tier id: \(currentTier["id"] ?? "<missing>")")
}
if let paidTier = discoveryJSON?["paidTier"] as? [String: Any] {
    print("Paid tier keys: \(paidTier.keys.sorted())")
    print("Paid tier id: \(paidTier["id"] ?? "<missing>")")
}

for endpoint in quotaEndpoints {
    performRequest(
        label: "Quota using discovered project",
        endpoint: endpoint,
        body: quotaBody(project: discoveredProject),
        accessToken: accessToken,
        session: session,
        semaphore: semaphore
    )
}
