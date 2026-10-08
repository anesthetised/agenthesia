import ACP
import AgenthesiaCore
import AppKit
import Rendering
import SwiftUI

struct TranscriptMessage {
    let role: String
    var markdown: String
    var text: NSAttributedString
    var previousMarkdown: String?
    var update: StreamingMarkdown.Update?
}

protocol TranscriptSource: AnyObject {
    var revision: Int { get }
    var messageCount: Int { get }
    func message(at row: Int) -> TranscriptMessage
    func isStreaming(at row: Int) -> Bool
}

/// Attributed text is cached only for rows requested by NSTableView.
final class LiveTranscriptSource: TranscriptSource {
    var state = TranscriptState()
    var running = false
    var revision = 0
    private struct Cached {
        var markdown: String
        var text: NSAttributedString
        var stream: StreamingMarkdown
    }
    private var cache: [Int64: Cached] = [:]
    var messageCount: Int { state.items.count }

    func update(_ controller: SessionController) {
        state = controller.transcript
        running = controller.status == .running || controller.status == .stopping
        revision += 1
    }

    func isStreaming(at row: Int) -> Bool {
        guard let message = state.items[row].message else { return false }
        return running && message.role != .user && message.turnID == state.activeTurn
    }

    func message(at row: Int) -> TranscriptMessage {
        let item = state.items[row]
        let (role, markdown) = Self.content(item)
        return render(id: item.id, role: role, markdown: markdown)
    }

    func render(id: Int64, role: String, markdown: String) -> TranscriptMessage {
        if let cached = cache[id], cached.markdown == markdown {
            return TranscriptMessage(role: role, markdown: markdown, text: cached.text)
        }
        var cached =
            cache[id] ?? Cached(markdown: "", text: NSAttributedString(string: ""), stream: StreamingMarkdown())
        let previous = cached.markdown
        let update: StreamingMarkdown.Update
        if markdown.hasPrefix(previous) {
            update = cached.stream.append(String(markdown.dropFirst(previous.count)))
        } else {
            cached = Cached(markdown: "", text: NSAttributedString(string: ""), stream: StreamingMarkdown())
            update = cached.stream.append(markdown)
        }
        let text = NSMutableAttributedString(attributedString: cached.text)
        update.apply(to: text)
        cached.markdown = markdown
        cached.text = text
        cache[id] = cached
        return TranscriptMessage(
            role: role,
            markdown: markdown,
            text: text,
            previousMarkdown: markdown.hasPrefix(previous) ? previous : nil,
            update: update
        )
    }

    static func content(_ item: TranscriptState.Item) -> (String, String) {
        if let message = item.message {
            let role: String =
                switch message.role {
                case .user: "You";
                case .assistant: "Agent";
                case .thought: "Thinking"
                }
            let text = message.content.map { block -> String in
                switch block {
                case .text(let text): return text.text
                case .image: return "\n\n[Image attachment]\n\n"
                case .audio: return "\n\n[Audio attachment]\n\n"
                default: return "\n\n[Resource attachment]\n\n"
                }
            }.joined()
            return (role, text)
        }
        if let tool = item.toolCall {
            let permission = item.permission == nil ? "" : "\n\nPermission request declined."
            return ("Tool", "\(tool.title)\n\nStatus: \(tool.status?.rawValue ?? "pending")" + permission)
        }
        return ("Session", item.notice ?? "Permission request declined")
    }
}

struct LiveTranscript: NSViewRepresentable {
    let session: SessionController

    final class Coordinator {
        let table = TranscriptTableController()
        let source = LiveTranscriptSource()
        let frames = SessionFrameDriver()
        weak var session: SessionController?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.table.scroll }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.session !== session {
            coordinator.session = session
            coordinator.frames.start(session: session, in: view)
        }
        coordinator.source.update(session)
        coordinator.table.update(coordinator.source)
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.frames.stop() }
}
