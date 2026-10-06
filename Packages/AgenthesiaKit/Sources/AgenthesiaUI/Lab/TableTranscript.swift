#if DEBUG
    import AppKit
    import Rendering

    /// Prototype A: a view-based `NSTableView`, a row per item, row heights from Auto Layout.
    ///
    /// Rows are created and rendered only when they scroll into view; heights of rows not yet seen are estimated.
    /// Text is selectable within a message, not across messages.
    final class TableTranscript: NSObject, TranscriptPrototype, NSTableViewDataSource, NSTableViewDelegate {
        let view: NSView
        private let table = NSTableView()
        private let scroll = NSScrollView()
        private var transcript = LabTranscript(items: [])

        override init() {
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
            // A text field has no partial update: the whole message is set again.
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TextCell {
                cell.field.attributedStringValue = transcript.text(at: row)
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
#endif
