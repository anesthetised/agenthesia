public import ACP
public import Foundation
import Observation

/// Something that needs the user while the session is not in front of them (ADR-0026, ADR-0030).
public struct AttentionNotice: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// `canDecide` when the agent offered both `allow_once` and `reject_once`.
        case permission(requestID: UUID, canDecide: Bool)
        case input(requestID: UUID)
        case failure
        case finished
    }

    /// Stable while the notice stays relevant, so a repeated derivation never posts it twice.
    public let id: String
    public let sessionID: UUID
    public let kind: Kind
    public let title: String
    public let body: String

    /// Allow once and Reject appear on a notification only when the agent offered both.
    static func canDecide(_ options: [ACP.PermissionOption]) -> Bool {
        let kinds = Set(options.map(\.kind))
        return kinds.contains(.allowOnce) && kinds.contains(.rejectOnce)
    }

    /// The notices for sessions that are not shown in the key window of the active app.
    @MainActor static func derive(_ owners: [LiveSession], shown: Set<UUID>) -> [AttentionNotice] {
        owners.flatMap { owner -> [AttentionNotice] in
            guard let controller = owner.controller, !shown.contains(controller.session.id) else { return [] }
            let session = controller.session.id
            let title = controller.title ?? "Agent session"
            var notices = controller.pendingPermissions.map { request in
                AttentionNotice(
                    id: "permission.\(request.id)",
                    sessionID: session,
                    kind: .permission(requestID: request.id, canDecide: canDecide(request.options)),
                    title: title,
                    body: request.toolTitle.map { "Permission needed: \($0)" } ?? "Permission needed"
                )
            }
            notices += controller.pendingInputs.map {
                AttentionNotice(
                    id: "input.\($0.id)",
                    sessionID: session,
                    kind: .input(requestID: $0.id),
                    title: title,
                    body: $0.request.message
                )
            }
            switch owner.activity {
            case .failed:
                notices.append(
                    .init(
                        id: "failure.\(session)",
                        sessionID: session,
                        kind: .failure,
                        title: title,
                        body: owner.errorMessage ?? controller.errorMessage ?? "The session failed"
                    )
                )
            case .done:
                notices.append(
                    .init(
                        id: "finished.\(session).\(controller.completedTurns)",
                        sessionID: session,
                        kind: .finished,
                        title: title,
                        body: "The agent finished its turn"
                    )
                )
            default: break
            }
            return notices
        }
    }
}

/// The system side of notifications and the Dock badge; injected so Core stays free of system frameworks.
@MainActor public protocol AttentionSink: AnyObject {
    func requestAuthorization() async
    func post(_ notice: AttentionNotice)
    func remove(ids: [String])
    func setBadge(_ count: Int)
}

/// Keeps notifications and the Dock badge in step with the sessions (ADR-0026, ADR-0030).
///
/// The wanted notices are derived from the manager on every change; a notice is posted when it first
/// appears and removed when it no longer applies, because the request was answered, the session ended or
/// the user looked at it.
@MainActor public final class SessionAttention {
    private let sessions: SessionManager
    private let sink: any AttentionSink
    private var posted: Set<String> = []
    private var requestedAuthorization = false

    public init(sessions: SessionManager, sink: any AttentionSink) {
        self.sessions = sessions
        self.sink = sink
        track()
    }

    /// Answers a permission request from a notification action. Stale requests are ignored.
    @discardableResult public func decide(requestID: UUID, in sessionID: UUID, allow: Bool) -> Bool {
        guard let controller = sessions.owner(of: sessionID)?.controller,
            let option = controller.pendingPermissions.first(where: { $0.id == requestID })?
                .options.first(where: { $0.kind == (allow ? .allowOnce : .rejectOnce) })
        else { return false }
        return controller.answerPermission(requestID, with: option.optionId)
    }

    private func track() {
        let (notices, badge) = withObservationTracking {
            (
                AttentionNotice.derive(sessions.owners, shown: sessions.shownSessionIDs),
                sessions.owners.count { $0.activity == .needsInput }
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        let wanted = Set(notices.map(\.id))
        let obsolete = posted.subtracting(wanted)
        if !obsolete.isEmpty { sink.remove(ids: obsolete.sorted()) }
        for notice in notices where !posted.contains(notice.id) { sink.post(notice) }
        posted = wanted
        sink.setBadge(badge)
        if !requestedAuthorization, !sessions.owners.isEmpty {
            requestedAuthorization = true
            Task { await sink.requestAuthorization() }
        }
    }
}
