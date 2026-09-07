import Foundation
import UserNotifications

/// Manages local user notifications for provider threshold alerts and test notifications.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // Tracks the last threshold percentage for which a notification was delivered per provider.
    // This prevents repeated spam for the same crossing while usage remains above the threshold.
    private var lastNotifiedThreshold: [Provider: Int] = [:]

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Requests user authorization for alert and sound notifications.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Sends an immediate test notification to confirm permissions and delivery.
    func sendTestNotification(for provider: Provider = .claude) {
        Task {
            _ = await requestAuthorization()
            let content = UNMutableNotificationContent()
            content.title = "\(provider.displayName) Limit Alert (Test)"
            content.body = "Notifications are working properly for \(provider.displayName)."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "test-\(provider.rawValue)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Evaluates current provider usage against configured notification thresholds.
    /// Fires local notifications when a threshold is crossed and prevents duplicate spam.
    func evaluate(providers: [Provider: ProviderStatus], config: DaemonConfig?) {
        for provider in Provider.allCases {
            guard let providerConfig = config?.config(for: provider),
                  let threshold = providerConfig.notifyThresholdPercent,
                  !providerConfig.routesEnabled.isEmpty else {
                // Notifications or provider disabled; clear any previous threshold memory
                lastNotifiedThreshold.removeValue(forKey: provider)
                continue
            }

            guard let status = providers[provider],
                  let data = status.data else {
                continue
            }

            // Quota usage: max of 5h and weekly percent (per API contract)
            let quotaValues = [data.usedPercent5h, data.usedPercentWeekly].compactMap { $0 }
            guard let currentMaxUsage = quotaValues.max() else { continue }

            if currentMaxUsage >= Double(threshold) {
                if lastNotifiedThreshold[provider] != threshold {
                    lastNotifiedThreshold[provider] = threshold
                    dispatchThresholdNotification(for: provider, usage: currentMaxUsage, threshold: threshold)
                }
            } else {
                // Usage dropped back below the threshold; allow notifying again on future crossing
                lastNotifiedThreshold.removeValue(forKey: provider)
            }
        }
    }

    private func dispatchThresholdNotification(for provider: Provider, usage: Double, threshold: Int) {
        Task {
            let content = UNMutableNotificationContent()
            content.title = "\(provider.displayName) Limit Alert"
            content.body = "\(provider.displayName) usage has reached \(Int(usage))% (threshold: \(threshold)%)."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "limit-\(provider.rawValue)-\(threshold)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Present banner and sound even when the app is currently in the foreground / active
        completionHandler([.banner, .sound])
    }
}
