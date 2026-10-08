#if DEBUG
    import ACP
    import AppKit
    import Rendering

    /// Exercises the production table and lazy Markdown cache with the existing deterministic workload.
    /// Does not measure ACP transport, SQLite commits, or SwiftUI observation.
    final class AppTranscriptPrototype: TranscriptPrototype, TranscriptSource {
        private let table = TranscriptTableController()
        private let rendering = LiveTranscriptSource()
        private var items: [(String, String)] = []
        /// Tool cards by item index, rendered as the live transcript renders them.
        private var tools: [Int: ACP.ToolCall] = [:]
        private var streaming = false
        var revision = 0
        var messageCount: Int { items.count }
        var view: NSView { table.scroll }
        var scrollView: NSScrollView? { table.scroll }

        func show(_ transcript: LabTranscript) {
            items = transcript.items.map { item in
                switch item {
                case .user(let text): ("You", text)
                case .assistant(let text): ("Agent", text)
                case .toolCall(let title, let output): ("Tool", title + "\n\n" + output)
                case .diff(let path, let patch): ("Diff", path + "\n\n```diff\n" + patch + "\n```")
                }
            }
            revision += 1
            table.update(self)
        }
        /// Adds tool cards; call before ``didAppend()`` so the streamed answer stays last.
        func appendTools(_ calls: [ACP.ToolCall]) {
            for call in calls {
                tools[items.count] = call
                items.append(("Tool", ""))
            }
        }

        /// Changes a card without updating the table; the next ``append(_:)`` publishes it.
        func replaceTool(_ call: ACP.ToolCall) {
            guard let index = tools.first(where: { $0.value.toolCallId == call.toolCallId })?.key else { return }
            tools[index] = call
        }

        func didAppend() {
            items.append(("Agent", ""))
            streaming = true
            revision += 1
            table.update(self)
        }
        func append(_ chunk: String) {
            items[items.count - 1].1 += chunk
            revision += 1
            table.update(self)
        }
        func didStream(_ update: StreamingMarkdown.Update) {}
        func message(at row: Int) -> TranscriptMessage {
            guard let tool = tools[row] else {
                return rendering.render(id: Int64(row), role: items[row].0, markdown: items[row].1)
            }
            let card = LiveTranscriptSource.toolCard(tool, permission: nil, expanded: false)
            var message = rendering.render(id: Int64(row), role: "Tool", markdown: card.markdown)
            message.tool = card.header
            return message
        }
        func isStreaming(at row: Int) -> Bool { streaming && row == items.count - 1 }
    }
#endif
