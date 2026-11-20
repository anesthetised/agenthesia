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
        defer { removeOwners(ending) }
        guard let id else { return }
        try await writeSettled(.now, id)
        settledIDs.insert(id)
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
        settledIDs.remove(id)
    }

    /// Settles each session of `history` that the rule settles now (`SessionSettling`), from `events` read with it: for
    /// its outcome only while the outcome is its very last event. Windows run it on each history refresh, which follows
    /// launch, a session's end, a merge and a discard. Returns the sessions it settled; a failed write does not stop the
    /// others, and the first one is returned.
    public func settleByRule(
        _ history: [SessionRecord],
        events: SessionLibrary.LastEvents,
        now: Date = .now
    ) async -> (settled: Set<UUID>, failure: (any Error)?) {
        var settled: Set<UUID> = []
        var failure: (any Error)?
        for session in history {
            let isLive = owners.contains { $0.sessionID == session.id && $0.isLive }
            guard
                SessionSettling.settles(
                    session,
                    isLive: isLive,
                    lastOutcome: events.lastOutcomes[session.id],
                    lastActivity: events.activity[session.id],
                    now: now
                )
            else { continue }
            do {
                try await writeSettled(now, session.id)
                settled.insert(session.id)
            } catch { failure = failure ?? error }
        }
        return (settled, failure)
    }

    /// Reads history and the last events, then settles by rule; throws the first failed write.
    @discardableResult func settleByRule(now: Date = .now) async throws -> Set<UUID> {
        let result = await settleByRule(try await library.history(), events: try await library.lastEvents(), now: now)
        if let failure = result.failure { throw failure }
        return result.settled
    }

    func writeSettled(_ settledAt: Date?, _ id: UUID) async throws {
        if let settledWrite { return try await settledWrite(settledAt, id) }
        try await library.store().setSettled(settledAt, of: id)
    }
}
