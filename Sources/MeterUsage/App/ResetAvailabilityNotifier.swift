import Foundation
import UserNotifications

/// Presents newly issued usage resets as native macOS banners. The delegate is
/// retained for the application lifetime so banners and their sound still show
/// while the menu-bar app is active in the foreground.
@MainActor
final class ResetAvailabilityNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ event: QuotaResetAvailabilityEvent) {
        let request = UNNotificationRequest(
            identifier: "reset-available-\(event.provider.rawValue)-\(UUID().uuidString)",
            content: Self.notificationContent(for: event),
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    static func notificationContent(
        for event: QuotaResetAvailabilityEvent
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(event.provider.displayName) reset available"
        content.body = event.newResetCount == 1
            ? "An early usage reset is ready to use."
            : "\(event.newResetCount) early usage resets are ready to use."
        content.sound = .default
        content.threadIdentifier = "usage-resets-\(event.provider.rawValue)"
        return content
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
