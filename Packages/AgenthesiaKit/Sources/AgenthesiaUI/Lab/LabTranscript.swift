#if DEBUG
    import AppKit
    import Rendering

    /// The transcript every prototype shows: generated items, each rendered once when first asked for.
    final class LabTranscript {
        private(set) var items: [TranscriptGenerator.Item]
        private var texts: [NSAttributedString?]
        let renderer = MarkdownRenderer()
        private var stream = StreamingMarkdown()
        private let streamed = NSMutableAttributedString()

        init(items: [TranscriptGenerator.Item]) {
            self.items = items
            texts = Array(repeating: nil, count: items.count)
        }

        var count: Int { items.count }

        /// The tool call at `index`, which prototypes show as a card instead of text.
        func card(at index: Int) -> (title: String, output: String)? {
            if case .toolCall(let title, let output) = items[index] { (title, output) } else { nil }
        }

        /// The text of the item at `index`; tool calls have none (see ``card(at:)``).
        func text(at index: Int) -> NSAttributedString {
            if let text = texts[index] { return text }
            let text = Self.render(items[index], renderer)
            texts[index] = text
            return text
        }

        /// The text of `item`; tool calls have none.
        nonisolated static func render(
            _ item: TranscriptGenerator.Item,
            _ renderer: MarkdownRenderer
        ) -> NSAttributedString {
            let theme = renderer.theme
            return switch item {
            case .user(let message):
                NSAttributedString(
                    string: message,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: theme.fontSize, weight: .semibold),
                        .foregroundColor: theme.textColor,
                    ]
                )
            case .assistant(let markdown): renderer.render(markdown)
            case .toolCall: NSAttributedString()
            case .diff(let path, let patch): diff(path: path, patch: patch, theme: theme)
            }
        }

        /// Adds an empty assistant message that ``stream(_:)`` fills.
        func startStreaming() {
            stream = StreamingMarkdown(renderer: renderer)
            streamed.setAttributedString(NSAttributedString())
            items.append(.assistant(markdown: ""))
            texts.append(streamed)
        }

        /// Adds `chunk` to the last message; the update says what changed in its text.
        func stream(_ chunk: String) -> StreamingMarkdown.Update {
            let update = stream.append(chunk)
            update.apply(to: streamed)
            return update
        }

        nonisolated private static func diff(path: String, patch: String, theme: Theme) -> NSAttributedString {
            let result = NSMutableAttributedString(
                string: path,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: theme.fontSize - 1, weight: .semibold)]
            )
            for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                let color: NSColor =
                    switch line.first {
                    case "+": .systemGreen
                    case "-": .systemRed
                    case "@": theme.secondaryTextColor
                    default: theme.textColor
                    }
                result.append(
                    NSAttributedString(
                        string: "\n" + line,
                        attributes: [.font: theme.codeFont, .foregroundColor: color]
                    )
                )
            }
            return result
        }
    }

    /// A transcript layout under test. Each run gets a new one.
    protocol TranscriptPrototype: AnyObject {
        var view: NSView { get }
        /// The scroll view that shows the transcript, once ``view`` is in a window.
        var scrollView: NSScrollView? { get }
        /// Shows `transcript` from the top.
        func show(_ transcript: LabTranscript)
        /// An item was added at the end of the transcript.
        func didAppend()
        /// The last item streamed: `update` replaced the tail of its text.
        func didStream(_ update: StreamingMarkdown.Update)
        /// Whether every item is shown; a prototype may show the last ones first.
        var isComplete: Bool { get }
    }

    extension TranscriptPrototype {
        var isComplete: Bool { true }
    }

    /// The card for a tool call, in AppKit prototypes.
    final class ToolCallCard: NSBox {
        static let id = NSUserInterfaceItemIdentifier("ToolCallCard")
        private let titleLabel = NSTextField(labelWithString: "")
        private let outputLabel = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            identifier = Self.id
            boxType = .custom
            cornerRadius = 6
            fillColor = .quaternarySystemFill
            borderColor = .separatorColor
            contentViewMargins = NSSize(width: 10, height: 6)
            titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            outputLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            outputLabel.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [titleLabel, outputLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            contentView = stack
        }

        convenience init(title: String, output: String) {
            self.init()
            show(title: title, output: output)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func show(title: String, output: String) {
            titleLabel.stringValue = "⚙︎ " + title
            outputLabel.stringValue = output
        }
    }

    /// Scrolls to the end of the document, as a transcript does while the last message streams.
    func scrollToEnd(_ scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let end = (clip.documentView?.frame.height ?? 0) - clip.bounds.height
        clip.scroll(to: NSPoint(x: 0, y: max(end, 0)))
        scrollView.reflectScrolledClipView(clip)
    }
#endif
