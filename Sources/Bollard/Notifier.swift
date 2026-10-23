import Foundation
import UserNotifications

/// Posts "started" and "stopped" notifications for dev servers. Silent when the user has not
/// granted permission or when running as a plain command-line tool.
@MainActor final class Notifier {
  private var available = Bundle.main.bundleIdentifier != nil
  private var authorized = false
  private var requested = false

  func prepare() {
    guard available, !requested else { return }
    requested = true
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      [weak self] granted, _ in
      Task { @MainActor in self?.authorized = granted }
    }
  }
  func post(title: String, body: String, id: String) {
    guard available else { return }
    if !requested { prepare() }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }
}
