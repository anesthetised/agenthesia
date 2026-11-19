import Foundation
import Persistence

/// The append chain of one session's log (#355). Every write to the log runs as a step here, one at a time in call
/// order: the session's controller's own writes and those of `SessionManager`, such as a worktree's outcome or a pull
/// request. The reducer needs each event to follow the last one it applied, so nothing appends to a log behind it.
@MainActor final class SessionLog {
    let sessionID: UUID
    private let store: PersistenceStore
    private var tail: Task<Void, any Error>?
    /// The controller that keeps this session's transcript; it is handed what other writers append.
    weak var controller: SessionController?

    init(sessionID: UUID, store: PersistenceStore) {
        self.sessionID = sessionID
        self.store = store
    }

    /// Runs `step` once every step reserved before it has finished, whether or not it failed. The order is reserved
    /// at the call, before anything is awaited.
    func run(_ step: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let previous = tail
        let task = Task {
            _ = await previous?.result
            try await step()
        }
        tail = task
        return task
    }

    /// Appends for a writer other than the controller, which is handed the stored events within the same step.
    func append(_ events: [NewEvent]) -> Task<Void, any Error> {
        run {
            let stored = try await self.store.append(events, to: self.sessionID)
            await self.controller?.didAppend(stored)
        }
    }

    /// Returns once no step is pending, including steps reserved while waiting.
    func settled() async {
        while let pending = tail {
            _ = await pending.result
            if tail == pending { return }
        }
    }
}
