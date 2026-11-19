import ACP
import AgenthesiaCore
import Foundation

/// What a session's composer holds until it is sent, so that looking at another session loses nothing.
struct ComposerDraft: Equatable {
    var message = PromptDraft()
    /// The queued message being edited, shown as `message`; `saved` is the draft it replaced.
    var editingQueueID: UUID?
    var saved: PromptDraft?
    /// The edited message was sent anyway, so the edit became this draft (#390).
    var editWasSent = false

    mutating func edit(_ entry: QueuedPrompt) {
        saved = message
        editWasSent = false
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

    /// Keeps the typed text, followed by the draft the edit replaced; the sent message's attachments went with it.
    mutating func keepEditAsDraft() {
        let saved = saved ?? PromptDraft()
        message = PromptDraft(
            text: [message.text, saved.text].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            attachments: saved.attachments
        )
        editingQueueID = nil
        self.saved = nil
        editWasSent = true
    }

    mutating func finishEditing() {
        message = saved ?? PromptDraft()
        editingQueueID = nil
        saved = nil
    }
}
