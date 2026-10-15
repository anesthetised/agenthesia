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

    static let kind = "session.event"
    static let updateKind = "acp.session/update"

    func storedEvent() throws -> NewEvent {
        NewEvent(kind: Self.kind, payload: try JSONEncoder().encode(self))
    }
}
