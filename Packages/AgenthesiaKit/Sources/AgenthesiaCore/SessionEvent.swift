public import ACP
public import Foundation
import Persistence

/// Version 1 of the app-owned event payload. ACP notifications are stored separately, byte-for-byte.
public enum SessionEvent: Codable, Equatable, Sendable {
    case started(configOptions: [ACP.ConfigOption])
    case prompt(id: UUID, content: [ACP.ContentBlock])
    case stopRequested(id: UUID)
    case finished(id: UUID, reason: ACP.StopReason)
    case failed(id: UUID, message: String)
    case configOptions([ACP.ConfigOption])
    case permission(toolCall: ACP.ToolCallUpdate, outcome: ACP.PermissionOutcome)

    static let kind = "session.event"
    static let updateKind = "acp.session/update"

    func storedEvent() throws -> NewEvent {
        NewEvent(kind: Self.kind, payload: try JSONEncoder().encode(self))
    }
}
