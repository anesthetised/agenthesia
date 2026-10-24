import AgenthesiaCore
import AppKit
import UserNotifications

/// Posts notices to Notification Center and shows the Dock badge (ADR-0026, ADR-0030).
@MainActor final class SystemAttention: NSObject, AttentionSink, UNUserNotificationCenterDelegate {
    /// What a notification carries and what its buttons do. Pure, so it is tested without the system.
    struct Payload: Equatable {
        static let decisionCategory = "agenthesia.decision"
        static let allow = "agenthesia.allow"
        static let reject = "agenthesia.reject"

        enum Route: Equatable {
            case open(sessionID: UUID)
            case decide(sessionID: UUID, requestID: UUID, allow: Bool)
        }

        let title: String
        let body: String
        let category: String?
        let userInfo: [String: String]
        let sound: Bool

        init(_ notice: AttentionNotice) {
            title = notice.title
            body = notice.body
            var info = ["session": notice.sessionID.uuidString]
            switch notice.kind {
            case .permission(let requestID, let canDecide):
                info["request"] = requestID.uuidString
                category = canDecide ? Self.decisionCategory : nil
                sound = true
            case .input(let requestID):
                info["request"] = requestID.uuidString
                category = nil
                sound = true
            case .failure:
                category = nil
                sound = true
            case .finished:
                category = nil
                sound = false
            }
            userInfo = info
        }

        /// A tap opens the session; the buttons answer the permission request they belong to.
        static func route(action: String, userInfo: [String: String]) -> Route? {
            guard let session = userInfo["session"].flatMap(UUID.init(uuidString:)) else { return nil }
            switch action {
            case UNNotificationDefaultActionIdentifier:
                return .open(sessionID: session)
            case allow, reject:
                guard let request = userInfo["request"].flatMap(UUID.init(uuidString:)) else { return nil }
                return .decide(sessionID: session, requestID: request, allow: action == allow)
            default:
                return nil
            }
        }
    }

    private let center: UNUserNotificationCenter
    private let open: (URL) -> Void
    private let badge: (String?) -> Void
    weak var attention: SessionAttention?

    init(
        center: UNUserNotificationCenter = .current(),
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        badge: @escaping (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 }
    ) {
        self.center = center
        self.open = open
        self.badge = badge
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Payload.decisionCategory,
                actions: [
                    UNNotificationAction(identifier: Payload.allow, title: "Allow once"),
                    UNNotificationAction(identifier: Payload.reject, title: "Reject"),
                ],
                intentIdentifiers: []
            )
        ])
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(_ notice: AttentionNotice) {
        let payload = Payload(notice)
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.userInfo = payload.userInfo
        content.threadIdentifier = notice.sessionID.uuidString
        if let category = payload.category { content.categoryIdentifier = category }
        if payload.sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    func remove(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func setBadge(_ count: Int) { badge(count > 0 ? String(count) : nil) }

    func handle(action: String, userInfo: [String: String]) {
        switch Payload.route(action: action, userInfo: userInfo) {
        case .open(let sessionID):
            if let url = WindowTarget.session(sessionID).url { open(url) }
        case .decide(let sessionID, let requestID, let allow):
            attention?.decide(requestID: requestID, in: sessionID, allow: allow)
        case nil:
            break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        await handle(action: action, userInfo: info)
    }

    /// The notice exists only while its session is not in front, so show it even while the app is active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
