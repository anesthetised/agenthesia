public import ACP
public import Foundation
import Persistence

/// Version 1 of the app-owned event payload. ACP notifications are stored separately, byte-for-byte.
public enum SessionEvent: Codable, Equatable, Sendable {
    /// How a saved session was reattached (ADR-0017).
    public enum ReopenMethod: String, Codable, Sendable {
        case resume, load
    }

    case started(configOptions: [ACP.ConfigOption])
    /// A saved session was reattached; the new baseline, like `started`.
    case reopened(configOptions: [ACP.ConfigOption], method: ReopenMethod)
    case prompt(id: UUID, content: [ACP.ContentBlock])
    case queueChanged([QueuedPrompt])
    case queuePaused(Bool)
    /// Durable injection intent; new composed messages remain recoverable in the queue until acknowledged.
    case injectionPrepared([QueuedPrompt])
    /// The turn was stopped before invoking the wire prompt; keep the composed messages for retry.
    case promptsNotSent(turnID: UUID, prompts: [QueuedPrompt])
    /// Each member has its own event sequence (transcript row identity); the whole batch is atomic.
    case promptMessage(prompt: QueuedPrompt, turnID: UUID, startsTurn: Bool, sentTogether: Bool)
    case interrupted(id: UUID)
    case stopRequested(id: UUID)
    case finished(id: UUID, reason: ACP.StopReason)
    case failed(id: UUID, message: String)
    case configOptions([ACP.ConfigOption])
    /// A decision recorded before requests had their own events. Still read; no longer written.
    case permission(toolCall: ACP.ToolCallUpdate, outcome: ACP.PermissionOutcome)
    /// Recorded before the request is shown. `id` is local; ACP has no request identity of its own.
    case permissionRequested(id: UUID, toolCall: ACP.ToolCallUpdate, options: [ACP.PermissionOption])
    /// The response returned to the agent. A later resolution of the same request supersedes an earlier one.
    case permissionResolved(id: UUID, outcome: ACP.PermissionOutcome)

    case inputRequested(id: UUID, request: ACP.ElicitationRequest)
    case inputResolved(id: UUID, response: ACP.ElicitationResponse)
    /// Appended after Git removed the session's worktree and branch; the session is read-only from then on
    /// and this stays its last event (ADR-0032).
    case worktreeRemoved(WorktreeOutcome)

    static let kind = "session.event"
    static let updateKind = "acp.session/update"

    func storedEvent() throws -> NewEvent {
        NewEvent(kind: Self.kind, payload: try JSONEncoder().encode(self))
    }
}

/// How a session's worktree ended (ADR-0032).
public enum WorktreeOutcome: Codable, Equatable, Sendable {
    /// The squash commit on the base branch. The worktree may outlive a failed removal; Discard finishes it.
    case merged(commit: String, into: String)
    case discarded

    /// The outcome recorded by a session's last event, if that event is one.
    init?(lastEvent: StoredEvent) {
        guard lastEvent.event.kind == SessionEvent.kind, lastEvent.event.formatVersion == 1,
            case .worktreeRemoved(let outcome) = try? JSONDecoder().decode(
                SessionEvent.self,
                from: lastEvent.event.payload
            )
        else { return nil }
        self = outcome
    }

    /// The transcript and status line text.
    public var notice: String {
        switch self {
        case .merged(let commit, let base): "Merged into \(base) as \(commit.prefix(7))."
        case .discarded: "The worktree was discarded."
        }
    }
}
