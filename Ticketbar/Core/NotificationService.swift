import Foundation
import UserNotifications

/// New-issue notifications.
///
/// Permission is asked for after the first successful token test, never at launch: a permission
/// prompt from an app that has not proved it can talk to the server yet is noise.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the issue key when the user clicks a notification.
    var onOpenIssue: ((String) -> Void)?

    /// The spec is one notification per newly assigned issue. Past this many at once it stops
    /// being information and becomes a wall, so the overflow collapses into a single summary.
    /// This only ever happens after a long disconnection, never on first run, which is seeded.
    private static let individualLimit = 5

    private let center = UNUserNotificationCenter.current()
    // nonisolated: the delegate callbacks that read it are nonisolated.
    private nonisolated static let issueKeyUserInfo = "issueKey"

    func configure() {
        center.delegate = self
    }

    var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
    }

    /// Asks once. macOS remembers a denial, so re-asking does nothing and shows nothing.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func notify(newIssues issues: [JiraIssue]) {
        guard !issues.isEmpty else { return }

        for issue in issues.prefix(Self.individualLimit) {
            let content = UNMutableNotificationContent()
            content.title = issue.key
            content.body = issue.cleanSummary
            content.subtitle = issue.statusName
            content.sound = .default
            content.userInfo = [Self.issueKeyUserInfo: issue.key]
            center.add(UNNotificationRequest(identifier: "issue-\(issue.key)",
                                             content: content,
                                             trigger: nil))
        }

        let overflow = issues.count - Self.individualLimit
        guard overflow > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(overflow) more issues assigned to you"
        content.body = "Open Ticketbar to see them."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "issue-overflow-\(UUID().uuidString)",
                                         content: content,
                                         trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// The app is an accessory and is usually not frontmost, but when it is, a banner should still
    /// appear rather than being swallowed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo[Self.issueKeyUserInfo] as? String
        await MainActor.run {
            guard let key else { return }
            self.onOpenIssue?(key)
        }
    }
}
