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
        private var groupExpanded = false
        private(set) var rows: [TranscriptRow] = []
        var revision = 0
        var messageCount: Int { rows.count }
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
            fold()
            revision += 1
            table.update(self)
        }

        /// Folds consecutive tool cards as the live transcript does; every group shares `groupExpanded`.
        private func fold() {
            rows = TranscriptRow.fold(
                count: items.count,
                isToolCall: { tools[$0] != nil },
                isExpanded: { _ in groupExpanded }
            )
        }

        /// Expands or collapses the groups without updating the table; the next ``append(_:)`` publishes it.
        func toggleGroups() {
            groupExpanded.toggle()
            fold()
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
            fold()
            revision += 1
            table.update(self)
        }
        func append(_ chunk: String) {
            items[items.count - 1].1 += chunk
            // The live transcript folds on every state change; S9 measures what that costs on a long history.
            fold()
            revision += 1
            table.update(self)
        }
        func didStream(_ update: StreamingMarkdown.Update) {}
        func message(at row: Int) -> TranscriptMessage {
            let index: Int
            switch rows[row] {
            case .item(let item): index = item
            case .group(let first):
                let end = TranscriptRow.groupEnd(from: first, count: items.count) { tools[$0] != nil }
                return TranscriptMessage(
                    group: (first..<end).compactMap { tools[$0] },
                    running: streaming,
                    expanded: groupExpanded,
                    copyText: { "" }
                )
            }
            guard let tool = tools[index] else {
                var message = rendering.render(id: Int64(index), role: items[index].0, markdown: items[index].1)
                message.kind =
                    switch items[index].0 {
                    case "You": .user
                    case "Agent": .agent
                    default: .card
                    }
                return message
            }
            let card = LiveTranscriptSource.toolCard(tool, expanded: false)
            var message = rendering.render(id: Int64(index), role: "Tool", markdown: card.markdown)
            message.tool = card.header
            return message
        }
        func isStreaming(at row: Int) -> Bool { streaming && rows[row] == .item(items.count - 1) }
    }
#endif
