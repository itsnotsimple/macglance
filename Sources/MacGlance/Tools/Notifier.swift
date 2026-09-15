import UserNotifications

/// macOS notifications (the banners in the top-right corner).
/// macOS asks the user for permission the first time one is sent.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func post(title: String, body: String) {
        center.requestAuthorization(options: [.alert]) { granted, _ in   // instant after the first answer
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            self.center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Show the banner even while our own window is in front (macOS hides it by default).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
