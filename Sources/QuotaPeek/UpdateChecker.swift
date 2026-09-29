import AppKit

/// "Check for Updates..." in the status item's right-click menu: asks GitHub
/// for the latest published release - the same one install.sh installs - and
/// compares it with this build's CFBundleShortVersionString. It only reports;
/// installing stays with install.sh / Homebrew.
@MainActor
enum UpdateChecker {
    static let repo = "shassshank/QuotaPeek"
    private static var isChecking = false

    enum Outcome {
        case upToDate(current: String)
        case available(latest: String, current: String, page: URL)
        case failed(String)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func checkNow() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let outcome = await fetchOutcome()
            isChecking = false
            present(outcome)
        }
    }

    private static func fetchOutcome() async -> Outcome {
        let current = currentVersion
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // GitHub answers 404 while the repo has no published release yet.
            if status == 404 { return .upToDate(current: current) }
            guard status == 200 else { return .failed("GitHub returned HTTP \(status).") }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = displayVersion(release.tagName)
            return isVersion(latest, newerThan: current)
                ? .available(latest: latest, current: current, page: release.htmlURL)
                : .upToDate(current: current)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func present(_ outcome: Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate(let current):
            alert.messageText = "QuotaPeek is up to date"
            alert.informativeText = "You're running the latest version (\(current))."
        case .available(let latest, let current, let page):
            alert.messageText = "QuotaPeek \(latest) is available"
            alert.informativeText = "You have \(current). Open the release page to download it."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(page)
            }
            return
        case .failed(let reason):
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = reason
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// "v1.2.0" -> "1.2.0".
    static func displayVersion(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Numeric dot-by-dot comparison; "1.10.0" is newer than "1.9.2", and a
    /// suffix such as "-beta" on a component is ignored.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            displayVersion(v).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
