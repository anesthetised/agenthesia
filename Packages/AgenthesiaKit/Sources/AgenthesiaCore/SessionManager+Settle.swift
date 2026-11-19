public import Foundation
public import Persistence

/// Settling by hand and by rule (ADR-0050).
extension SessionManager {
    /// Ends the owner, then settles its session. An owner that never stored its session only ends.
    public func settle(_ owner: LiveSession) async throws {
        let id = owner.sessionID
        await end(owner)
        if let id { try await settle(id) }
    }

    /// Settles a session, ending its owners first: a live session is never settled.
    public func settle(_ id: UUID) async throws {
        for owner in owners where owner.sessionID == id { await end(owner) }
        try await library.store().setSettled(.now, of: id)
    }

    /// Unsettle needs a session that is not live or starting (a Continue), merged, discarded or deleted.
    public func canUnsettle(_ id: UUID) -> Bool {
        !owners.contains { $0.sessionID == id && $0.isLive } && !isDiscarding(id) && !isMerging(id)
            && !deletingIDs.contains(id) && !unsettlingIDs.contains(id)
    }

    /// Brings a settled session back to the list without starting its agent. The `session.unsettled` event restarts
    /// the seven days of the rule.
    public func unsettle(_ id: UUID) async throws {
        guard canUnsettle(id) else { return }
        unsettlingIDs.insert(id)
        defer { unsettlingIDs.remove(id) }
        let store = try await library.store()
        // A second writer on a saved session's log, as `SessionLibrary.record` is; `canUnsettle` and `resume` keep a
        // Continue out meanwhile. #355's one log writer per session replaces both.
        _ = try await store.append([SessionUnsettled.storedEvent()], to: id)
        try await store.setSettled(nil, of: id)
    }

    /// Settles every saved session the rule settles now (`SessionSettling`). Windows run it before each history
    /// refresh, which follows launch, a session's end, a merge and a discard.
    public func settleByRule(now: Date = .now) async throws {
        let store = try await library.store()
        let history = try await library.history()
        let last = try await store.lastEvents()
        for session in history {
            let isLive = owners.contains { $0.sessionID == session.id && $0.isLive }
            let event = last[session.id]
            guard
                SessionSettling.settles(
                    session,
                    isLive: isLive,
                    lastOutcome: event.flatMap(WorktreeOutcome.init(lastEvent:)),
                    lastActivity: event?.event.timestamp,
                    now: now
                )
            else { continue }
            try await store.setSettled(now, of: session.id)
        }
    }
}
