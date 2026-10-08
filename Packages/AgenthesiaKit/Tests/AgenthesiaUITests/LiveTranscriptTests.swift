import ACP
import AppKit
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite struct LiveTranscriptTests {
    @Test func cachedRenderingHandlesAppendsReplacementsAndUnicode() {
        let source = LiveTranscriptSource()
        let first = source.render(id: 1, role: "Agent", markdown: "Hello 🌍")
        let unchanged = source.render(id: 1, role: "Agent", markdown: "Hello 🌍")
        #expect(unchanged.text === first.text)
        let appended = source.render(id: 1, role: "Agent", markdown: "Hello 🌍 **world**")
        #expect(appended.text.string == "Hello 🌍 world")
        let copy = NSMutableAttributedString(attributedString: first.text)
        appended.update?.apply(to: copy)
        #expect(copy == appended.text)
        #expect(first.text.string == "Hello 🌍")
        let replacement = source.render(id: 1, role: "Agent", markdown: "Different")
        #expect(replacement.previousMarkdown == nil)
        #expect(replacement.text.string == "Different")
    }

    @Test func contentKeepsRolesAttachmentsToolsAndNoticesVisible() {
        let message = TranscriptState.Item(
            id: 1,
            message: .init(
                role: .thought,
                turnID: nil,
                agentMessageID: nil,
                content: [.init(text: "Thinking"), .image(.init(data: "", mimeType: "image/png"))]
            )
        )
        #expect(LiveTranscriptSource.content(message).0 == "Thinking")
        #expect(LiveTranscriptSource.content(message).1.contains("Image attachment"))
        let tool = TranscriptState.Item(id: 2, toolCall: .init(toolCallId: "t", title: "Read file", status: .completed))
        #expect(LiveTranscriptSource.content(tool).1.contains("completed"))
        var declined = tool
        declined.permission = .cancelled
        #expect(LiveTranscriptSource.content(declined).1.contains("Permission request declined"))
        #expect(LiveTranscriptSource.content(.init(id: 3, notice: "Interrupted")).1 == "Interrupted")
    }
}
