import Foundation
import UserNotifications

/// A time-sensitive notification for an approval when no Live Activity can ask (off, dismissed, or
/// never started), so the person still hears about it. Never both: AppModel's askOwner posts it only
/// without a Live Activity. Touch and hold
/// it for Allow (Face ID or the passcode first), Don't Allow, and on a step that turning asking off
/// reaches, Don't Ask Again (Face ID or the passcode first). PokiCore sends no input while an
/// approval waits, so only the person can press them.
enum ApprovalNotice {
    static let category = "approval"
    /// The same buttons and Don't Ask Again, for a step the owner can stop being asked about.
    static let optionalCategory = "approval.optional"
    static let allow = "approval.allow"
    static let deny = "approval.deny"
    static let stopAsking = "approval.stop"

    /// Allow and Don't Allow on the notification itself (touch and hold it, or pull it down), so an
    /// approval can be answered without opening Poki. Allow asks for Face ID or the passcode first.
    @MainActor static func registerActions() {
        let allowAction = UNNotificationAction(identifier: allow, title: AppLocalization.text(LocalizedStringResource("Allow")),
                                               options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let denyAction = UNNotificationAction(identifier: deny, title: AppLocalization.text(LocalizedStringResource("Don’t Allow")),
                                              options: [.destructive], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let stopAction = UNNotificationAction(identifier: stopAsking, title: AppLocalization.text(LocalizedStringResource("Don’t ask again")),
                                              options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        let approvals = UNNotificationCategory(identifier: category, actions: [allowAction, denyAction], intentIdentifiers: [],
                                               options: [.hiddenPreviewsShowTitle])
        let optional = UNNotificationCategory(identifier: optionalCategory, actions: [allowAction, denyAction, stopAction], intentIdentifiers: [],
                                              options: [.hiddenPreviewsShowTitle])
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([approvals, optional])
        center.delegate = ApprovalNoticeDelegate.shared
    }

    static func requestPermission() {
        Task { @MainActor in registerActions() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in AppLog.shared.add("notice", granted ? "notifications allowed" : "notifications not allowed") }
        }
    }

    static func post(_ approval: PendingApproval, caller: String? = nil) {
        let content = UNMutableNotificationContent()
        // The one question, as on the card: from the rules' kind, never the agent's words.
        content.title = approval.question
        content.categoryIdentifier = approval.offersStopAsking ? optionalCategory : category
        content.userInfo = ["approval": approval.id]
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "approvals"
        let request = UNNotificationRequest(identifier: "approval-\(approval.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clear(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(id)"])
        center.removePendingNotificationRequests(withIdentifiers: ["approval-\(id)"])
    }
}

/// Answers from the notification's buttons go the same way as the Live Activity's (ApprovalIntentBridge).
final class ApprovalNoticeDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ApprovalNoticeDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            defer { completionHandler() }
            guard let id = response.notification.request.content.userInfo["approval"] as? String else { return }
            let action = response.actionIdentifier
            guard [ApprovalNotice.allow, ApprovalNotice.deny, ApprovalNotice.stopAsking].contains(action) else { return }
            ApprovalIntentBridge.submit(ApprovalDecision(approvalID: id, approved: action != ApprovalNotice.deny,
                                                         stopAsking: action == ApprovalNotice.stopAsking))
        }
    }

    /// While Poki is open the banner still shows, so the buttons are there too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// The notification for a sign-in from a client outside the relay's known list. A tap opens Poki,
/// where the owner answers (Allow asks for Face ID or the passcode on the alert's own button).
enum ConnectionNotice {
    @MainActor static func post(_ ask: AppModel.ConnectionAsk) {
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text(LocalizedStringResource("Allow \(ask.client) to connect?"))
        content.body = AppLocalization.text(LocalizedStringResource("A client (\(ask.callback)) is signing in with \(ask.connector). Open Poki to allow or deny it."))
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "connections"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "connection-\(ask.id)", content: content, trigger: nil))
    }

    @MainActor static func clear(_ ask: AppModel.ConnectionAsk) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["connection-\(ask.id)"])
    }
}

/// The pairing code as a time-sensitive banner, so it shows over Settings' Pair with Poki screen.
enum PairingNotice {
    static let id = "pairing-code"
    @MainActor static func post(pin: String) {
        let content = UNMutableNotificationContent()
        let shown = pin.count == 6 ? "\(pin.prefix(3)) \(pin.suffix(3))" : pin
        content.title = AppLocalization.text(LocalizedStringResource("Pairing code \(shown)"))
        content.body = AppLocalization.text(LocalizedStringResource("Type it on the Pair with Poki screen in Settings."))
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    @MainActor static func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}

/// What the Live Activity would pop up for (the agent's hand-off, a problem) when there is no Live
/// Activity to pop up: dismissed, off in Settings, or Poki turned on from the background, where iOS does
/// not let an app start one. A time-sensitive banner instead.
enum AttentionNotice {
    static let id = "poki-attention"
    @MainActor static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    @MainActor static func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
