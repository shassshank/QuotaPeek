import Foundation
import UserNotifications

/// Manages local user notifications for provider threshold alerts and test notifications.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // Tracks the last threshold percentage for which a notification was delivered per account.
    // This prevents repeated spam for the same crossing while usage remains above the threshold.
    private var lastNotifiedThreshold: [String: Int] = [:]

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

    /// Evaluates current account usage against configured notification thresholds.
    /// Fires local notifications when a threshold is crossed and prevents duplicate spam.
    func evaluate(accounts: [Account], config: DaemonConfig?) {
        for account in accounts {
            guard let providerConfig = config?.config(for: account.provider),
                  let threshold = providerConfig.notifyThresholdPercent,
                  !account.routesEnabled.isEmpty else {
                // Notifications or provider disabled; clear any previous threshold memory
                lastNotifiedThreshold.removeValue(forKey: account.id)
                continue
            }

            // Only evaluate if account state is not unknown/error and has data
            guard account.state != .unknown && account.state != .error,
                  let data = account.data else {
                continue
            }

            // Quota usage: max of 5h and weekly percent (per API contract)
            let quotaValues = [data.usedPercent5h, data.usedPercentWeekly].compactMap { $0 }
            guard let currentMaxUsage = quotaValues.max() else { continue }

            if currentMaxUsage >= Double(threshold) {
                if lastNotifiedThreshold[account.id] != threshold {
                    lastNotifiedThreshold[account.id] = threshold
                    dispatchThresholdNotification(for: account, usage: currentMaxUsage, threshold: threshold)
                }
            } else {
                // Usage dropped back below the threshold; allow notifying again on future crossing
                lastNotifiedThreshold.removeValue(forKey: account.id)
            }
        }
    }

    private func dispatchThresholdNotification(for account: Account, usage: Double, threshold: Int) {
        Task {
            let content = UNMutableNotificationContent()
            content.title = "\(account.provider.displayName) (\(account.label)) Limit Alert"
            content.body = "\(account.provider.displayName) (\(account.label)) usage has reached \(Int(usage))% (threshold: \(threshold)%)."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "limit-\(account.id)-\(threshold)-\(UUID().uuidString)",
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
