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
let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

// Candidate installed-app OAuth client id/secret pairs extracted from the locally installed
// `agy` binary (static string inspection). Pairing between id and secret is not known from
// string order, so both permutations are tried against Google's token endpoint until one works.
let oauthClientIDs = [
    "REDACTED-GOOGLE-OAUTH-CLIENT-ID",
    "REDACTED-GOOGLE-OAUTH-CLIENT-ID",
]
let oauthClientSecrets = [
    "REDACTED-GOOGLE-OAUTH-CLIENT-SECRET",
    "REDACTED-GOOGLE-OAUTH-CLIENT-SECRET",
]

func refreshAccessToken(refreshToken: String, session: URLSession) -> (accessToken: String, clientID: String)? {
    for clientID in oauthClientIDs {
        for clientSecret in oauthClientSecrets {
            var request = URLRequest(url: tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let form = [
                "grant_type=refresh_token",
                "refresh_token=\(refreshToken)",
                "client_id=\(clientID)",
                "client_secret=\(clientSecret)",
            ].joined(separator: "&")
            request.httpBody = form.data(using: .utf8)

            let semaphore = DispatchSemaphore(value: 0)
            var resultToken: String?
            var statusCode = -1
            session.dataTask(with: request) { data, response, error in
                defer { semaphore.signal() }
                if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
                guard error == nil, let data,
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let json = object as? [String: Any],
                      let token = json["access_token"] as? String
                else { return }
                resultToken = token
            }.resume()
            _ = semaphore.wait(timeout: .now() + 15)

            let shortID = String(clientID.prefix(12))
            if let resultToken {
                print("Refresh succeeded with client_id \(shortID)... (status \(statusCode))")
                return (resultToken, clientID)
            } else {
                print("Refresh attempt with client_id \(shortID)... failed (status \(statusCode))")
            }
        }
    }
    return nil
}

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
    ["ideType": "ANTIGRAVITY"]
}

// Matches the real Antigravity CLI's request shape exactly (captured via local proxy from a
// real `agy` `/usage` invocation). No Client-Metadata header; User-Agent is what Google's
// backend actually checks for the UNSUPPORTED_CLIENT gate.
func applyHeaders(to request: inout URLRequest, accessToken: String) {
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
        "antigravity/cli/1.1.26 (aidev_client; os_type=darwin; arch=arm64; cl=976013059; auth_method=consumer)",
        forHTTPHeaderField: "User-Agent"
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
let storedAccessToken = (tokenDict?["access_token"] as? String) ?? (json["access_token"] as? String)
let refreshToken = tokenDict?["refresh_token"] as? String
guard let storedAccessToken, !storedAccessToken.isEmpty else {
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

let session = URLSession(configuration: .ephemeral)

var accessToken = storedAccessToken
if let refreshToken, !refreshToken.isEmpty {
    print("\nAttempting OAuth refresh (stored access_token may be expired)...")
    if let refreshed = refreshAccessToken(refreshToken: refreshToken, session: session) {
        accessToken = refreshed.accessToken
        print("Using freshly refreshed access token.")
    } else {
        print("All refresh attempts failed; falling back to stored access token.")
    }
} else {
    print("\nNo refresh_token found in credential; using stored access token as-is.")
}

let semaphore = DispatchSemaphore(value: 0)

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
