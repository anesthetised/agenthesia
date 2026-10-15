public import ACP
public import Foundation

/// A composed message keeps its identity and attachments through queue edits and a grouped send.
public struct QueuedPrompt: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var content: [ACP.ContentBlock]

    public init(id: UUID = UUID(), content: [ACP.ContentBlock]) {
        self.id = id
        self.content = content
    }

    public var text: String {
        content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }.joined()
    }
}
