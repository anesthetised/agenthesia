#if DEBUG
    import AppKit
    import Rendering

    /// Prototype B: the whole transcript as one TextKit 2 document in a read-only `NSTextView`.
    ///
    /// Tool calls are attachments whose views are the same cards as in prototype A. Every item is rendered when the
    /// transcript opens; TextKit 2 lays out only what is in view. Text is selectable across messages.
    final class DocumentTranscript: TranscriptPrototype {
        let view: NSView
        private let textView = NSTextView(usingTextLayoutManager: true)
        private let scroll = NSScrollView()
        private var transcript = LabTranscript(items: [])
        /// Where the last item starts in the text.
        private var lastStart = 0

        init() {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainerInset = NSSize(width: 7, height: 0)
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            view = scroll
        }

        var scrollView: NSScrollView? { scroll }

        func show(_ transcript: LabTranscript) {
            self.transcript = transcript
            transcript.renderAll()
            let text = NSMutableAttributedString()
            for index in 0..<transcript.count {
                append(index, to: text)
            }
            textView.textStorage?.setAttributedString(text)
        }

        func didAppend() {
            guard let storage = textView.textStorage else { return }
            storage.beginEditing()
            append(transcript.count - 1, to: storage)
            storage.endEditing()
        }

        func didStream(_ update: StreamingMarkdown.Update) {
            guard let storage = textView.textStorage else { return }
            let start = lastStart + update.stablePrefixLength
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: update.tail)
            textView.scrollToEndOfDocument(nil)
        }

        private func append(_ index: Int, to text: NSMutableAttributedString) {
            if index > 0 {
                // An empty line between items.
                text.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
            }
            lastStart = text.length
            if let card = transcript.card(at: index) {
                text.append(NSAttributedString(attachment: CardAttachment(title: card.title, output: card.output)))
            } else {
                text.append(transcript.text(at: index))
            }
        }
    }

    /// A tool call card in the text, as wide as the text container.
    nonisolated private final class CardAttachment: NSTextAttachment {
        let title: String
        let output: String

        init(title: String, output: String) {
            self.title = title
            self.output = output
            super.init(data: nil, ofType: nil)
            // Without an image the text view also draws a placeholder file icon under the card.
            image = NSImage()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewProvider(
            for parentView: NSView?,
            location: any NSTextLocation,
            textContainer: NSTextContainer?
        ) -> NSTextAttachmentViewProvider? {
            CardViewProvider(
                textAttachment: self,
                parentView: parentView,
                textLayoutManager: textContainer?.textLayoutManager,
                location: location
            )
        }

        override func attachmentBounds(
            for attributes: [NSAttributedString.Key: Any],
            location: any NSTextLocation,
            textContainer: NSTextContainer?,
            proposedLineFragment: CGRect,
            position: CGPoint
        ) -> CGRect {
            CGRect(x: 0, y: 0, width: proposedLineFragment.width - 10, height: 44)
        }
    }

    nonisolated private final class CardViewProvider: NSTextAttachmentViewProvider {
        override func loadView() {
            guard let attachment = textAttachment as? CardAttachment else { return }
            let (title, output) = (attachment.title, attachment.output)
            view = MainActor.assumeIsolated { ToolCallCard(title: title, output: output) }
        }
    }
#endif
