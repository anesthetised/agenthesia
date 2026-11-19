import ACP
import AgenthesiaCore
import Foundation

/// What a session's composer holds until it is sent, so that looking at another session loses nothing.
struct ComposerDraft: Equatable {
    var message = PromptDraft()
    /// The queued message being edited, shown as `message`; `saved` is the draft it replaced.
    var editingQueueID: UUID?
    var saved: PromptDraft?
    /// Why the edit became this draft: its message left the queue while it was edited (#390).
    var editLeftQueue: LeftQueue?

    enum LeftQueue: Equatable {
        case sent, removed

        var line: String {
            switch self {
            case .sent: "The message was already sent; your edit is now a draft"
            case .removed: "The message was removed from the queue; your edit is now a draft"
            }
        }
    }

    mutating func edit(_ entry: QueuedPrompt) {
        saved = message
        editLeftQueue = nil
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

    /// Keeps the typed text, followed by the draft the edit replaced; the message's attachments stay with it.
    mutating func keepEditAsDraft(_ reason: LeftQueue) {
        let saved = saved ?? PromptDraft()
        message = PromptDraft(
            text: [message.text, saved.text].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            attachments: saved.attachments
        )
        editingQueueID = nil
        self.saved = nil
        editLeftQueue = reason
    }

    mutating func finishEditing() {
        message = saved ?? PromptDraft()
        editingQueueID = nil
        saved = nil
    }
}
