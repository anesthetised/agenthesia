#if DEBUG
    import AppKit
    import Rendering

    /// Prototype A: a view-based `NSTableView`, a row per item, row heights from Auto Layout.
    ///
    /// Rows are created and rendered only when they scroll into view; heights of rows not yet seen are estimated.
    /// Text is selectable within a message, not across messages. Messages are text fields; with `textKit`
    /// (prototype A′) the last one is a TextKit 2 text view, which a streamed chunk changes only at the end. A text
    /// view in every row scrolled slower: each draws its whole message into its own layer.
    final class TableTranscript: NSObject, TranscriptPrototype, NSTableViewDataSource, NSTableViewDelegate {
        let view: NSView
        private let table = NSTableView()
        private let scroll = NSScrollView()
        private let textKit: Bool
        private var transcript = LabTranscript(items: [])

        init(textKit: Bool = false) {
            self.textKit = textKit
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .plain
            table.usesAutomaticRowHeights = true
            table.selectionHighlightStyle = .none
            table.intercellSpacing = NSSize(width: 0, height: 12)
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            view = scroll
            super.init()
            table.dataSource = self
            table.delegate = self
        }

        var scrollView: NSScrollView? { scroll }

        func show(_ transcript: LabTranscript) {
            self.transcript = transcript
            table.reloadData()
        }

        func didAppend() {
            table.insertRows(at: [transcript.count - 1])
        }

        func didStream(_ update: StreamingMarkdown.Update) {
            let row = transcript.count - 1
            switch table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as TextKitCell:
                cell.textView.apply(update)
            case let cell as TextCell:
                // A text field has no partial update: the whole message is set again.
                cell.field.attributedStringValue = transcript.text(at: row)
            default: break
            }
            table.noteHeightOfRows(withIndexesChanged: [row])
            scrollToEnd(scroll)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            transcript.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if let card = transcript.card(at: row) {
                let view =
                    tableView.makeView(withIdentifier: ToolCallCard.id, owner: nil) as? ToolCallCard
                    ?? ToolCallCard()
                view.show(title: card.title, output: card.output)
                return view
            }
            if textKit, row == transcript.count - 1 {
                let view =
                    tableView.makeView(withIdentifier: TextKitCell.id, owner: nil) as? TextKitCell ?? TextKitCell()
                view.textView.textStorage?.setAttributedString(transcript.text(at: row))
                view.textView.invalidateIntrinsicContentSize()
                return view
            }
            let view = tableView.makeView(withIdentifier: TextCell.id, owner: nil) as? TextCell ?? TextCell()
            view.field.attributedStringValue = transcript.text(at: row)
            return view
        }
    }

    /// A row with a message: a selectable, wrapping text field.
    private final class TextCell: NSView {
        static let id = NSUserInterfaceItemIdentifier("TextCell")
        let field = NSTextField(wrappingLabelWithString: "")

        init() {
            super.init(frame: .zero)
            identifier = Self.id
            field.isSelectable = true
            // Keeps the text's attributes when selecting it switches the field to its field editor.
            field.allowsEditingTextAttributes = true
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                field.topAnchor.constraint(equalTo: topAnchor),
                field.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    /// A row with a message in a TextKit 2 text view, as tall as its text.
    private final class TextKitCell: NSView {
        static let id = NSUserInterfaceItemIdentifier("TextKitCell")
        let textView = SizingTextView(usingTextLayoutManager: true)

        init() {
            super.init(frame: .zero)
            identifier = Self.id
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isVerticallyResizable = false
            textView.isHorizontallyResizable = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.size.height = .greatestFiniteMagnitude
            textView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    /// A text view whose intrinsic height is its text's at its current width.
    private final class SizingTextView: NSTextView {
        private var measuredWidth: CGFloat = 0

        override var intrinsicContentSize: NSSize {
            guard let layout = textLayoutManager, bounds.width > 0 else {
                return NSSize(width: NSView.noIntrinsicMetric, height: 17)
            }
            layout.ensureLayout(for: layout.documentRange)
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: layout.usageBoundsForTextContainer.height.rounded(.up)
            )
        }

        override func layout() {
            super.layout()
            if bounds.width != measuredWidth {
                measuredWidth = bounds.width
                invalidateIntrinsicContentSize()
            }
        }

        /// Replaces the end of the text, as `update` says.
        func apply(_ update: StreamingMarkdown.Update) {
            guard let storage = textStorage else { return }
            update.apply(to: storage)
            invalidateIntrinsicContentSize()
        }
    }
#endif
