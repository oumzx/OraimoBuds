import Foundation
import UserNotifications

/// Local (no server, no account) low-battery alerts. Requests authorization
/// lazily the first time it's actually needed rather than at launch, so the
/// permission prompt has context.
final class NotificationManager {
    static let shared = NotificationManager()
    private var authorizationRequested = false

    private func ensureAuthorized(_ completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                completion(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    completion(granted)
                }
            default:
                completion(false)
            }
        }
    }

    func postLowBattery(side: String, percent: UInt8) {
        ensureAuthorized { granted in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Low Battery"
            content.body = "\(side) is at \(percent)%"
            content.sound = .default
            let request = UNNotificationRequest(identifier: "low-battery-\(side)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
