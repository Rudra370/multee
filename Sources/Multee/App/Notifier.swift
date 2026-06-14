import AppKit
import UserNotifications

/// Posts a macOS notification when a session that you're *not currently looking at* needs attention or
/// finishes, and focuses that session + tab when the banner is clicked. Authorization is requested once
/// at launch; each post re-checks the **live** authorization (a launch-time cache goes stale the moment
/// you toggle the OS permission while the app is running), and falls back to the in-app sound when
/// notifications aren't authorized. `willPresent` lets a banner show even while Multee is frontmost
/// (e.g. you're in a different session). One pending notification per tab.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Set by AppDelegate: bring the app forward and focus the session + tab a clicked banner refers to.
    var onActivate: ((_ sessionID: String, _ tabID: String) -> Void)?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a banner if notifications are authorized right now; otherwise run `fallback` (the in-app sound).
    func post(sessionID: String, sessionName: String, tabID: String, tabTitle: String,
              state: ClaudeState, fallback: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                guard ok else { fallback(); return }
                let content = UNMutableNotificationContent()
                content.title = sessionName
                content.body = state == .needs ? "Needs your input" : "Finished — \(tabTitle)"
                content.sound = .default
                content.userInfo = ["sessionID": sessionID, "tabID": tabID]
                center.add(UNNotificationRequest(identifier: "tab-\(tabID)", content: content, trigger: nil))
            }
        }
    }

    /// Show the banner even when Multee is the active app (you may be in a different session/tab).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Banner clicked → focus that session + tab.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let sessionID = info["sessionID"] as? String, let tabID = info["tabID"] as? String {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.onActivate?(sessionID, tabID)
            }
        }
        completionHandler()
    }
}
