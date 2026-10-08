#if DEBUG
    import AppKit
    import Rendering

    /// Exercises the production table and lazy Markdown cache with the existing deterministic workload.
    /// Does not measure ACP transport, SQLite commits, or SwiftUI observation.
    final class AppTranscriptPrototype: TranscriptPrototype, TranscriptSource {
        private let table = TranscriptTableController()
        private let rendering = LiveTranscriptSource()
        private var items: [(String, String)] = []
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
            rendering.render(id: Int64(row), role: items[row].0, markdown: items[row].1)
        }
        func isStreaming(at row: Int) -> Bool { streaming && row == items.count - 1 }
    }
#endif
