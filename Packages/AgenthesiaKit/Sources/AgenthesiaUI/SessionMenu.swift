import ACP
import AgenthesiaCore
import Foundation

/// What the menu bar item lists (ADR-0046): the sessions that need the user, then the ones working. Derived on every
/// read from the live sessions, like the sidebar it agrees with; nothing is stored.
struct SessionMenu {
    struct Entry: Identifiable {
        let id: AnyHashable
        /// Nil while a starting session has no record, and so no window target, yet.
        let sessionID: UUID?
        /// `title · detail`.
        let text: String
        /// The oldest pending permission request, which a Needs You entry can answer.
        let request: SessionController.PendingPermission?
        let answer: (ACP.PermissionOptionID) -> Void

        var url: URL? { sessionID.flatMap { WindowTarget.session($0).url } }
    }

    let needsYou: [Entry]
    let working: [Entry]

    /// A Needs You entry reads `title · reason` (`LiveSession.reason`). A Working entry reads `title · step`, the plan
    /// entry in progress, or else `title · Working 1m 12s`, the sidebar's shelf time.
    @MainActor init(owners: [LiveSession], now: Date = .now) {
        let sidebar = SessionSidebar(projects: [], history: [], owners: owners)
        func entries(_ kind: SessionSidebar.Kind) -> [Entry] {
            (sidebar.section(kind)?.rows ?? []).compactMap { row in
                guard case .live(let owner) = row.source else { return nil }
                let detail =
                    kind == .needsYou
                    ? owner.reason
                    : PlanProgress(owner.controller?.transcript.plan)?.current
                        ?? SessionSidebar.shelfTime(
                            activity: owner.activity,
                            turnStartedAt: owner.controller?.turnStartedAt,
                            lastActivity: row.lastActivity,
                            now: now
                        )
                let request = kind == .needsYou ? owner.controller?.pendingPermissions.first : nil
                return Entry(
                    id: row.id,
                    sessionID: owner.sessionID,
                    text: [row.title, detail].compactMap(\.self).joined(separator: " · "),
                    request: request,
                    // The request the entry listed: one answered or replaced meanwhile makes the click do nothing.
                    answer: { [weak owner] option in
                        guard let request else { return }
                        owner?.controller?.answerPermission(request.id, with: option)
                    }
                )
            }
        }
        needsYou = entries(.needsYou)
        working = entries(.working)
    }
}
