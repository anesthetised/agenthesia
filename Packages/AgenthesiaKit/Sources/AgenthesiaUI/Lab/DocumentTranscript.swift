#if DEBUG
    import AppKit
    import Rendering

    /// Prototype B: the whole transcript as one TextKit 2 document in a read-only `NSTextView`.
    ///
    /// Tool calls are attachments whose views are the same cards as in prototype A. A transcript opens at its end:
    /// the last items are rendered at once, older ones in the background and put above without moving what is in
    /// view. TextKit 2 lays out only what is in view. Text is selectable across messages.
    final class DocumentTranscript: TranscriptPrototype {
        /// How many of the last items show at once when a transcript opens.
        private static let tailCount = 300

        let view: NSView
        private let textView = NSTextView(usingTextLayoutManager: true)
        private let scroll = NSScrollView()
        private var transcript = LabTranscript(items: [])
        /// Where the last item starts in the text.
        private var lastStart = 0
        private(set) var isComplete = true
        private var loading: Task<Void, Never>?

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

        deinit {
            loading?.cancel()
        }

        var scrollView: NSScrollView? { scroll }

        func show(_ transcript: LabTranscript) {
            self.transcript = transcript
            let start = max(transcript.count - Self.tailCount, 0)
            let (text, lastStart) = Self.text(of: transcript.items[start...], renderer: transcript.renderer)
            textView.textStorage?.setAttributedString(text)
            self.lastStart = lastStart
            isComplete = start == 0
            loading?.cancel()
            loading = Task { [weak self] in await self?.load(before: start) }
        }

        /// Renders the items before `end` on a background queue and puts them above.
        private func load(before end: Int) async {
            guard end > 0 else { return }
            let items = transcript.items[..<end]
            let renderer = transcript.renderer
            // The text is created on a background queue and handed over whole, so it is never shared.
            let text: NSAttributedString = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.text(of: items, renderer: renderer).text)
                }
            }
            guard !Task.isCancelled else { return }
            prepend(text)
            isComplete = true
        }

        /// Puts `text` at the start, keeping the text in view where it is.
        private func prepend(_ text: NSAttributedString) {
            guard let storage = textView.textStorage, let layout = textView.textLayoutManager,
                let content = layout.textContentManager
            else { return }
            let clip = scroll.contentView
            let top = clip.bounds.minY - textView.textContainerOrigin.y
            let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(top, 0)))
            let anchor = fragment.map {
                content.offset(from: content.documentRange.location, to: $0.rangeInElement.location)
            }
            let delta = top - (fragment?.layoutFragmentFrame.minY ?? 0)

            // Inserting at the start costs more the longer the text (900 ms at 4 million characters); this costs ~1 s once.
            let combined = NSMutableAttributedString(attributedString: text)
            combined.append(storage)
            storage.setAttributedString(combined)
            lastStart += text.length

            guard let anchor,
                let location = content.location(content.documentRange.location, offsetBy: anchor + text.length)
            else { return }
            let y = layout.textViewportLayoutController.relocateViewport(to: location)
            clip.scroll(to: NSPoint(x: 0, y: y + delta + textView.textContainerOrigin.y))
            scroll.reflectScrolledClipView(clip)
        }

        func didAppend() {
            guard let storage = textView.textStorage else { return }
            let index = transcript.count - 1
            let (text, lastStart) = Self.text(of: transcript.items[index...], renderer: transcript.renderer)
            self.lastStart = storage.length + lastStart
            storage.append(text)
        }

        func didStream(_ update: StreamingMarkdown.Update) {
            guard let storage = textView.textStorage else { return }
            let start = lastStart + update.stablePrefixLength
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: update.tail)
            textView.scrollToEndOfDocument(nil)
        }

        /// The text of `items`, each but the first item of the transcript after an empty line, and where the last
        /// one starts.
        nonisolated private static func text(
            of items: ArraySlice<TranscriptGenerator.Item>,
            renderer: MarkdownRenderer
        ) -> (text: NSAttributedString, lastStart: Int) {
            let text = NSMutableAttributedString()
            var lastStart = 0
            for (index, item) in zip(items.indices, items) {
                if index > 0 {
                    text.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
                }
                lastStart = text.length
                if case .toolCall(let title, let output) = item {
                    text.append(NSAttributedString(attachment: CardAttachment(title: title, output: output)))
                } else {
                    text.append(LabTranscript.render(item, renderer))
                }
            }
            return (text, lastStart)
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
