public import ACP
public import Foundation

/// A composed message keeps its identity and attachments through queue edits and a grouped send.
public struct QueuedPrompt: Identifiable, Codable, Equatable, Sendable {
    /// Who started the turn (ADR-0049): the user, or another session through the app's tools.
    public enum Origin: Codable, Equatable, Sendable {
        case user
        /// `session_send` from the turn `turnID` of the session `id`.
        case session(id: UUID, turnID: UUID)
        /// A delegated task's first prompt, in the child session.
        case delegation(taskID: UUID)
        /// A delegated task's result, delivered to the parent.
        case delivery(taskID: UUID)
        /// A finished `task_run` command, reported to the session that started it.
        case task(taskID: UUID)

        /// The transcript's and sidebar's label for a turn the user did not send; nil for the user's own.
        /// - Parameters:
        ///   - title: The source session's title, for a `session` origin.
        ///   - agent: The source session's agent name, for a `session` origin.
        public func label(title: String?, agent: String?) -> String? {
            switch self {
            case .user: nil
            case .session: "From \(title ?? "another session")" + (agent.map { " · \($0)" } ?? "")
            case .delegation: "Delegated task"
            case .delivery: "Delegated result"
            case .task: "Background task"
            }
        }

        /// The content as the agent receives it: a prompt the user did not send is marked as another agent
        /// session's, which stays anonymous to the receiver (#93).
        public func wrapped(_ content: [ACP.ContentBlock]) -> [ACP.ContentBlock] {
            let source: String
            switch self {
            case .user: return content
            case .session, .delegation: source = "another agent session"
            case .delivery: source = "another agent session that finished the task you delegated"
            case .task: source = "the app, reporting a background command you started that finished"
            }
            return [.init(text: "The message below comes from \(source), not from the user.\n<message>\n")] + content
                + [.init(text: "\n</message>")]
        }
    }

    public let id: UUID
    public var content: [ACP.ContentBlock]
    /// Absent in logs written before origins, which are the user's.
    public var origin: Origin

    public init(id: UUID = UUID(), content: [ACP.ContentBlock], origin: Origin = .user) {
        self.id = id
        self.content = content
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case id, content, origin }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode([ACP.ContentBlock].self, forKey: .content)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .user
    }

    /// The user's origin is left out, so that their prompts are stored as before.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        if origin != .user { try container.encode(origin, forKey: .origin) }
    }

    public var text: String {
        content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }.joined()
    }
}
