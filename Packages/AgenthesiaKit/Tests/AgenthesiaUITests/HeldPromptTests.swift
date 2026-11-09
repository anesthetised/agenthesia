import AppKit
import Foundation
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// The first message of a starting session is the one row of a transcript table, laid out as the session's own first
/// prompt will be (ADR-0040's amendment of 2026-11-07).
@MainActor @Suite struct HeldPromptTests {
    @Test(arguments: [false, true])
    func theMessageKeepsItsPlaceWhenTheSessionsTranscriptReplacesIt(attached: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "held-\(UUID()).txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let prompt = PromptDraft(text: "Fix the **build**\n\nplease", attachments: attached ? [file] : [])
        let recorded = try await RecordedTranscript()
        let content = LiveSession.content(prompt.text, attachments: prompt.attachments, checkout: nil)
        try await recorded.append(SessionEvent.prompt(id: UUID(), content: content).storedEvent())
        let live = LiveTranscriptSource()
        live.state = recorded.state
        live.revision += 1
        let held = HeldPromptSource(prompt)

        #expect(held.messageCount == 1 && held.rows == [.item(0)])
        #expect(held.message(at: 0).kind == .user && held.message(at: 0).role == "You")
        #expect(held.message(at: 0).markdown == live.message(at: 0).markdown)
        #expect(held.message(at: 0).markdown.contains("[Attachment: `\(file.lastPathComponent)`]") == attached)
        let (heldRow, heldFrames) = try layout(held)
        let (liveRow, liveFrames) = try layout(live)
        #expect(abs(heldRow.minY - liveRow.minY) < 1 && abs(heldRow.height - liveRow.height) < 1)
        #expect(!heldFrames.isEmpty && heldFrames.count == liveFrames.count)
        for (held, live) in zip(heldFrames, liveFrames) {
            #expect(abs(held.minX - live.minX) < 1 && abs(held.minY - live.minY) < 1)
            #expect(abs(held.width - live.width) < 1 && abs(held.height - live.height) < 1)
        }
    }

    @Test func anAttachmentOnlyMessageHasNoEmptyTextAboveIt() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "held-\(UUID()).txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let markdown = HeldPromptSource(PromptDraft(text: " ", attachments: [file])).message(at: 0).markdown
        #expect(markdown == "\n\n[Attachment: `\(file.lastPathComponent)`]\n\n")
    }

    /// The first row's frame in the table, and the frames of its views in the table's coordinates.
    private func layout(_ source: any TranscriptSource) throws -> (NSRect, [NSRect]) {
        let controller = TranscriptTableController()
        let window = OffscreenWindow(size: .init(width: 900, height: 600))
        defer { window.close() }
        controller.scroll.frame = window.contentLayoutRect
        controller.table.frame.size.width = 900
        window.contentView = controller.scroll
        window.contentView?.layoutSubtreeIfNeeded()
        controller.update(source)
        let row = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        row.layoutSubtreeIfNeeded()
        func frames(of view: NSView) -> [NSRect] {
            [controller.table.convert(view.bounds, from: view)] + view.subviews.flatMap(frames)
        }
        return (controller.table.rect(ofRow: 0), frames(of: row))
    }
}
