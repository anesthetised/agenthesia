public import Foundation
public import Persistence

/// Settling by hand and by rule (ADR-0050).
extension SessionManager {
    /// Closes the owner, settles its session, then removes the owner, so that no window lists the session in between.
    /// An owner that never stored its session only ends.
    public func settle(_ owner: LiveSession) async throws {
        try await settle([owner], id: owner.sessionID)
    }

    /// Settles a session, closing its owners first: a live session is never settled.
    public func settle(_ id: UUID) async throws {
        try await settle(owners.filter { $0.sessionID == id }, id: id)
    }

    private func settle(_ ending: [LiveSession], id: UUID?) async throws {
        for owner in ending { await owner.close() }
        defer { owners.removeAll { owner in ending.contains { $0 === owner } } }
        if let id { try await writeSettled(.now, id) }
    }

    /// Unsettle needs a session that is not live or starting (a Continue, which unsettles it itself), merging,
    /// discarding or being deleted. A merged or discarded session can be unsettled: it keeps its outcome (ADR-0032's
    /// amendment).
    public func canUnsettle(_ id: UUID) -> Bool {
        !owners.contains { $0.sessionID == id && $0.isLive } && !isDiscarding(id) && !isMerging(id)
            && !deletingIDs.contains(id)
    }

    /// Brings a settled session back to the list without starting its agent. The `session.unsettled` event restarts
    /// the seven days of the rule. A session that is not settled is left alone. The event goes through the session's
    /// log (#355), so a Continue that starts meanwhile reads it in order.
    public func unsettle(_ id: UUID) async throws {
        guard canUnsettle(id) else { return }
        guard try await library.store().session(id: id)?.settledAt != nil else { return }
        try await append([SessionUnsettled.storedEvent()], to: id)
        try await writeSettled(nil, id)
    }

    /// Settles every saved session the rule settles now (`SessionSettling`): for its outcome only while the outcome is
    /// its last event. Windows run it before each history refresh, which follows launch, a session's end, a merge and a
    /// discard. A failed write does not stop the others; the first failure is thrown at the end.
    public func settleByRule(now: Date = .now) async throws {
        let store = try await library.store()
        let history = try await library.history()
        let last = try await store.lastEvents()
        var failure: (any Error)?
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
            do { try await writeSettled(now, session.id) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    func writeSettled(_ settledAt: Date?, _ id: UUID) async throws {
        if let settledWrite { return try await settledWrite(settledAt, id) }
        try await library.store().setSettled(settledAt, of: id)
    }
}
