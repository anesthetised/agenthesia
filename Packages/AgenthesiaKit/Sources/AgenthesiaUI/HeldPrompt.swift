import ACP
import AgenthesiaCore
import AppKit
import SwiftUI

/// The first message of a session that is starting, as the one row of a transcript (ADR-0040's amendment of
/// 2026-11-07). The table lays it out as it does the session's own first prompt, so the message stays where it is when
/// that arrives.
final class HeldPromptSource: TranscriptSource {
    let revision = 0
    let messageCount = 1
    private let held: TranscriptMessage

    init(_ prompt: PromptDraft) {
        let blocks = LiveSession.content(prompt.text, attachments: prompt.attachments, checkout: nil)
        var message = LiveTranscriptSource().render(
            id: 0,
            role: "You",
            markdown: LiveTranscriptSource.markdown(of: blocks)
        )
        message.kind = .user
        held = message
    }

    func message(at row: Int) -> TranscriptMessage { held }
    func isStreaming(at row: Int) -> Bool { false }
}

/// A transcript table that shows `HeldPromptSource`.
struct HeldTranscript: NSViewRepresentable {
    let prompt: PromptDraft

    final class Coordinator {
        let table = TranscriptTableController()
        var prompt: PromptDraft?
        var source: HeldPromptSource?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.table.scroll }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.prompt != prompt {
            coordinator.prompt = prompt
            coordinator.source = HeldPromptSource(prompt)
        }
        if let source = coordinator.source { coordinator.table.update(source) }
    }
}
