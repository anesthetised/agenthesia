import ACP
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

    /// The notices for sessions that are not shown in the key window of the active app. A session that
    /// failed before it had a controller still has a failure to report.
    @MainActor static func derive(_ owners: [LiveSession], shown: Set<UUID>) -> [AttentionNotice] {
        owners.flatMap { owner -> [AttentionNotice] in
            guard let session = owner.controller?.session.id ?? owner.sessionID, !shown.contains(session) else {
                return []
            }
            let controller = owner.controller
            // The name the sidebar shows, so a banner says which session asks.
            let title =
                owner.controller?.session.title ?? owner.resuming?.title ?? controller?.title ?? "Agent session"
            var notices = (controller?.pendingPermissions ?? []).map { request in
                AttentionNotice(
                    id: "permission.\(request.id)",
                    sessionID: session,
                    kind: .permission(requestID: request.id, canDecide: canDecide(request.options)),
                    title: title,
                    body: request.toolTitle.map { "Permission needed: \($0)" } ?? "Permission needed"
                )
            }
            notices += (controller?.pendingInputs ?? []).map {
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
                        body: owner.errorMessage ?? controller?.errorMessage ?? "The session failed"
                    )
                )
            case .done:
                if let controller {
                    notices.append(
                        .init(
                            id: "finished.\(session).\(controller.completedTurns)",
                            sessionID: session,
                            kind: .finished,
                            title: title,
                            body: "The agent finished its turn"
                        )
                    )
                }
            default: break
            }
            return notices
        }
    }

    /// Sessions that have failed, shown or not.
    @MainActor static func failedSessions(_ owners: [LiveSession]) -> Set<UUID> {
        Set(owners.compactMap { $0.activity == .failed ? $0.controller?.session.id ?? $0.sessionID : nil })
    }
}

/// The system side of notifications and the Dock badge; injected so Core stays free of system frameworks.
@MainActor public protocol AttentionSink: AnyObject {
    func requestAuthorization() async
    func post(_ notice: AttentionNotice)
    func remove(ids: [String])
    /// `badge` counts the sessions that need input; `live` counts the sessions that are running at all.
    func setDock(badge: Int, live: Int)
}

/// Keeps notifications and the Dock badge in step with the sessions (ADR-0026, ADR-0030).
///
/// The wanted notices are derived from the manager on every change; a notice is posted when it first
/// appears and removed when it no longer applies, because the request was answered, the session ended or
/// the user looked at it.
@MainActor public final class SessionAttention {
    private struct Snapshot {
        let notices: [AttentionNotice]
        let failed: Set<UUID>
        let shown: Set<UUID>
        let badge: Int
        let live: Int
    }

    private let sessions: SessionManager
    private let sink: any AttentionSink
    private var posted: Set<String> = []
    private var requestedAuthorization = false
    /// Nothing is posted before the system has answered, or the first notice would be lost.
    private var authorized = false
    /// A failure stays failed, so it is announced once and only again if the session fails anew.
    private var acknowledgedFailures: Set<UUID> = []
    private var latest: Snapshot?

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
        let snapshot = withObservationTracking {
            Snapshot(
                notices: AttentionNotice.derive(sessions.owners, shown: sessions.shownSessionIDs),
                failed: AttentionNotice.failedSessions(sessions.owners),
                shown: sessions.shownSessionIDs,
                badge: sessions.owners.count { $0.activity == .needsInput },
                live: sessions.owners.count { $0.activity != .failed }
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        latest = snapshot
        apply(snapshot)
        if !requestedAuthorization, !sessions.owners.isEmpty {
            requestedAuthorization = true
            Task {
                await sink.requestAuthorization()
                authorized = true
                if let latest { apply(latest) }
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        acknowledgedFailures.formUnion(snapshot.failed.intersection(snapshot.shown))
        acknowledgedFailures.formIntersection(snapshot.failed)
        let notices = authorized ? snapshot.notices.filter(isWanted) : []
        let wanted = Set(notices.map(\.id))
        let obsolete = posted.subtracting(wanted)
        if !obsolete.isEmpty { sink.remove(ids: obsolete.sorted()) }
        for notice in notices where !posted.contains(notice.id) { sink.post(notice) }
        posted = wanted
        sink.setDock(badge: snapshot.badge, live: snapshot.live)
    }

    private func isWanted(_ notice: AttentionNotice) -> Bool {
        if case .failure = notice.kind { return !acknowledgedFailures.contains(notice.sessionID) }
        return true
    }
}
