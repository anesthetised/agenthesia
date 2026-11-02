import ACP
import AgenthesiaCore
import Foundation

/// What a session's composer holds until it is sent, so that looking at another session loses nothing.
struct ComposerDraft: Equatable {
    var message = PromptDraft()
    /// The queued message being edited, shown as `message`; `saved` is the draft it replaced.
    var editingQueueID: UUID?
    var saved: PromptDraft?

    mutating func edit(_ entry: QueuedPrompt) {
        saved = message
        editingQueueID = entry.id
        message = PromptDraft(
            text: entry.text,
            attachments: entry.content.compactMap {
                guard case .resourceLink(let link) = $0, let url = URL(string: link.uri), url.isFileURL else {
                    return nil
                }
                return url
            }
        )
    }

    mutating func finishEditing() {
        message = saved ?? PromptDraft()
        editingQueueID = nil
        saved = nil
    }
}
