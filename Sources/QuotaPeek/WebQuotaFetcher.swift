import QuotaPeekCore
import CryptoKit
import Foundation

/// Web fallback for when local readings go stale (usage from claude.ai,
/// ChatGPT, another Mac...). Reads the CLI's own stored token, read-only,
/// and never refreshes it: refreshing rotates the refresh token and could log
/// the CLI out. An expired token is reported as `.tokenExpired` so the user
/// can run the CLI once.
///
/// - Claude: `GET api.anthropic.com/api/oauth/usage` (no inference, costs no quota).
/// - Codex:  `GET chatgpt.com/backend-api/wham/usage` (the endpoint the codex CLI uses).
struct WebQuotaFetcher {
    enum FetchError: Error, CustomStringConvertible, Equatable {
        case noCredentials(String)
        case tokenExpired(String)
        case http(Int)
        case badResponse(String)
        case unsupported

        var description: String {
            switch self {
            case .noCredentials(let what): return "no stored login (\(what))"
            case .tokenExpired(let cli): return "login expired; run `\(cli)` once to refresh it"
            case .http(let code): return "HTTP \(code)"
            case .badResponse(let why): return "unexpected response: \(why)"
            case .unsupported: return "no web fallback for this provider"
            }
        }
    }

    static let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    /// Treat a token this close to expiry as expired rather than racing it.
    static let expiryLeeway: TimeInterval = 60

    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    var readKeychain: (_ service: String, _ account: String?) async -> Data? = SecurityCLI.findGenericPassword

    func fetch(provider: Provider, configDir: String?) async throws -> ProviderData {
        switch provider {
        case .claude: return try await fetchClaude(configDir: configDir)
        case .codex: return try await fetchCodex(configDir: configDir)
        case .antigravity: throw FetchError.unsupported
        }
    }

    // MARK: Claude

    /// Keychain item Claude Code uses for a config dir: the default dir uses
    /// the plain name, others append the first 8 hex chars of sha256(NFC path).
    static func claudeKeychainService(configDir: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let dir = configDir, !dir.isEmpty,
              (dir as NSString).standardizingPath != (home as NSString).appendingPathComponent(".claude") else {
            return "Claude Code-credentials"
        }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    func fetchClaude(configDir: String?) async throws -> ProviderData {
        let service = Self.claudeKeychainService(configDir: configDir)
        guard let raw = await readKeychain(service, NSUserName()) else { throw FetchError.noCredentials(service) }
        guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw FetchError.noCredentials("\(service) has no OAuth token")
        }
        if let expiresMs = LocalQuotaParser.number(oauth["expiresAt"]), expiresMs > 0,
           Date().addingTimeInterval(Self.expiryLeeway).timeIntervalSince1970 * 1000 >= expiresMs {
            throw FetchError.tokenExpired("claude")
        }
        var request = URLRequest(url: Self.claudeUsageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = try await send(request, expiredCLI: "claude")
        guard let data = Self.parseClaudeUsage(body) else { throw FetchError.badResponse("no five_hour/seven_day utilization") }
        return data
    }

    /// `{"five_hour":{"utilization":31,"resets_at":"…"},"seven_day":{…}}`, utilization in percent.
    static func parseClaudeUsage(_ body: Data) -> ProviderData? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        var data = ProviderData()
        if let w = obj["five_hour"] as? [String: Any] {
            data.usedPercent5h = LocalQuotaParser.percent(w["utilization"])
            data.resetsAt5h = LocalQuotaParser.resetTime(w["resets_at"])
        }
        if let w = obj["seven_day"] as? [String: Any] {
            data.usedPercentWeekly = LocalQuotaParser.percent(w["utilization"])
            data.resetsAtWeekly = LocalQuotaParser.resetTime(w["resets_at"])
        }
        return data.usedPercent5h == nil && data.usedPercentWeekly == nil ? nil : data
    }

    // MARK: Codex

    /// Mirrors codex-rs compute_store_key: "cli|" + first 16 hex chars of
    /// sha256(canonical CODEX_HOME).
    static func codexKeychainAccount(codexHome: String) -> String {
        let canonical = URL(fileURLWithPath: codexHome).resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "cli|" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    func fetchCodex(configDir: String?) async throws -> ProviderData {
        let home = LocalQuotaParser.canonicalConfigDir(configDir, provider: .codex)
        var raw = await readKeychain("Codex Auth", Self.codexKeychainAccount(codexHome: home))
        if raw == nil {
            raw = FileManager.default.contents(atPath: (home as NSString).appendingPathComponent("auth.json"))
        }
        guard let raw,
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw FetchError.noCredentials("Codex Auth / auth.json")
        }
        if let exp = Self.jwtClaims(token)?["exp"].flatMap(LocalQuotaParser.number),
           Date().addingTimeInterval(Self.expiryLeeway).timeIntervalSince1970 >= exp {
            throw FetchError.tokenExpired("codex")
        }
        let accountID = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ((tokens["id_token"] as? String).flatMap(Self.jwtClaims)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
        var request = URLRequest(url: Self.codexUsageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let body = try await send(request, expiredCLI: "codex")
        guard let data = Self.parseCodexUsage(body) else { throw FetchError.badResponse("no rate_limit windows") }
        return data
    }

    /// `{"rate_limit":{"primary_window":{"used_percent":2,"reset_at":…},"secondary_window":{…}}}`
    static func parseCodexUsage(_ body: Data) -> ProviderData? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let limit = obj["rate_limit"] as? [String: Any] else { return nil }
        var data = ProviderData()
        if let w = limit["primary_window"] as? [String: Any] {
            data.usedPercent5h = LocalQuotaParser.percent(w["used_percent"])
            data.resetsAt5h = LocalQuotaParser.resetTime(w["reset_at"])
        }
        if let w = limit["secondary_window"] as? [String: Any] {
            data.usedPercentWeekly = LocalQuotaParser.percent(w["used_percent"])
            data.resetsAtWeekly = LocalQuotaParser.resetTime(w["reset_at"])
        }
        return data.usedPercent5h == nil && data.usedPercentWeekly == nil ? nil : data
    }

    // MARK: Shared

    private func send(_ request: URLRequest, expiredCLI: String) async throws -> Data {
        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw FetchError.tokenExpired(expiredCLI) }
        guard (200...299).contains(status) else { throw FetchError.http(status) }
        return body
    }

    /// Payload claims of a JWT, unverified: only used to read expiry and the
    /// account id from tokens that are already trusted local state.
    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Reads Keychain items through /usr/bin/security, so an "Always Allow"
/// granted to it once keeps working across app updates.
/// Bounded by a timeout because `security` has been seen to hang.
enum SecurityCLI {
    static func findGenericPassword(service: String, account: String?) async -> Data? {
        var args = ["find-generic-password", "-s", service, "-w"]
        if let account { args += ["-a", account] }
        return await run(args, timeout: 5)
    }

    static func run(_ args: [String], timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = args
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = DispatchTime.now() + timeout
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                var data = Data()
                let reader = DispatchQueue(label: "com.quotapeek.security.read")
                reader.async { data = out.fileHandleForReading.readDataToEndOfFile() }
                if done.wait(timeout: deadline) == .timedOut {
                    process.terminate()
                    ErrorLog.warning("security timed out reading \(args.dropFirst(2).first ?? "?")")
                    continuation.resume(returning: nil)
                    return
                }
                reader.sync {}
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                var trimmed = data
                while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }
}
