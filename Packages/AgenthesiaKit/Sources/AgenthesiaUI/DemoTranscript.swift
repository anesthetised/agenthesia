import AppKit
import Rendering
import SwiftUI

struct DemoTranscript: NSViewRepresentable {
    let session: DemoSession

    func makeCoordinator() -> DemoTranscriptController { DemoTranscriptController() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(session)
        return context.coordinator.scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(session)
    }
}

/// Demo-only A′ table. The Rendering Lab keeps its measurement implementation unchanged.
final class DemoTranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = DemoTableView()
    let scroll = DemoScrollView()
    private var session: DemoSession?
    private var revision = -1
    private var count = 0
    private var wasStreaming = false
    private var followingBottom = true
    private var adjustingScroll = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = true
        table.allowsMultipleSelection = true
        table.intercellSpacing = NSSize(width: 0, height: 20)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.copyMessages = { [weak self] in self?.selectedMarkdown ?? "" }
        table.setAccessibilityLabel("Demo conversation")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.didLayout = { [weak self] in self?.followEnd() }
        table.willNavigate = { [weak self] in self?.followingBottom = false }
        table.didNavigate = { [weak self] in self?.userDidScroll(nil) }
        scroll.willNavigate = { [weak self] in self?.followingBottom = false }
        scroll.didNavigate = { [weak self] in self?.userDidScroll(nil) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userWillScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scroll
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scroll
        )
    }

    var selectedMarkdown: String {
        guard let session else { return "" }
        return table.selectedRowIndexes.compactMap { row in
            session.messages.indices.contains(row) ? session.messages[row].markdown : nil
        }.joined(separator: "\n\n")
    }

    static func followsBottom(documentHeight: CGFloat, visibleRect: NSRect) -> Bool {
        documentHeight - visibleRect.maxY <= 24
    }

    func update(_ session: DemoSession) {
        guard revision != session.revision else { return }
        let initial = self.session == nil
        let origin = scroll.contentView.bounds.origin
        self.session = session
        if initial {
            table.reloadData()
        } else if count < session.messages.count {
            table.insertRows(at: IndexSet(integersIn: count..<session.messages.count))
        } else if count > 0 {
            let row = count - 1
            let visibleRow = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? DemoMessageRow
            let keepsSelection = visibleRow?.streamingCell?.textView.selectedRange().length ?? 0 > 0
            if wasStreaming != session.isStreaming, !keepsSelection {
                table.reloadData(forRowIndexes: [row], columnIndexes: [0])
            } else if let rowView = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? DemoMessageRow,
                let cell = rowView.streamingCell
            {
                rowView.markdown = session.messages[row].markdown
                if revision + 1 == session.revision, let update = session.lastUpdate {
                    cell.textView.apply(update)
                } else {
                    let selection = cell.textView.selectedRange()
                    cell.textView.textStorage?.setAttributedString(session.messages[row].text)
                    cell.textView.setSelectedRange(selection)
                    cell.textView.invalidateIntrinsicContentSize()
                }
            }
            table.noteHeightOfRows(withIndexesChanged: [row])
        }
        count = session.messages.count
        wasStreaming = session.isStreaming
        revision = session.revision
        table.layoutSubtreeIfNeeded()
        if followingBottom {
            followEnd()
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func userWillScroll(_ notification: Notification) { followingBottom = false }

    @objc private func userDidScroll(_ notification: Notification?) {
        followingBottom = Self.followsBottom(documentHeight: table.frame.height, visibleRect: scroll.contentView.bounds)
    }

    /// Row heights settle during AppKit layout, sometimes after the SwiftUI update.
    /// Keep the reader's intent rather than inferring it again from transient geometry.
    private func followEnd() {
        guard followingBottom, !adjustingScroll else { return }
        let end = max(0, table.frame.height - scroll.contentView.bounds.height)
        guard abs(scroll.contentView.bounds.origin.y - end) > 0.5 else { return }
        adjustingScroll = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
        adjustingScroll = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { session?.messages.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session else { return nil }
        let message = session.messages[row]
        let content: NSView
        if session.isStreaming, row == session.messages.count - 1 {
            let cell = TextKitCell()
            cell.textView.textStorage?.setAttributedString(message.text)
            cell.textView.invalidateIntrinsicContentSize()
            content = cell
        } else {
            let cell = TextCell()
            cell.field.preferredMaxLayoutWidth = max(1, tableView.tableColumns[0].width - 48)
            cell.field.attributedStringValue = message.text
            content = cell
        }
        let role = NSTextField(labelWithString: message.role)
        role.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        role.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy", target: nil, action: nil)
        copy.bezelStyle = .inline
        copy.toolTip = "Copy message as Markdown"
        let header = NSStackView(views: [role, NSView(), copy])
        header.distribution = .fill
        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let rowView = DemoMessageRow(markdown: message.markdown)
        rowView.streamingCell = content as? TextKitCell
        copy.target = rowView
        copy.action = #selector(DemoMessageRow.copyMessage(_:))
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return rowView
    }
}

final class DemoTableView: NSTableView {
    var copyMessages: (() -> String)?
    var didLayout: (() -> Void)?
    var willNavigate: (() -> Void)?
    var didNavigate: (() -> Void)?

    override func layout() {
        super.layout()
        didLayout?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        didLayout?()
    }

    override func keyDown(with event: NSEvent) {
        let navigation = [115, 116, 119, 121, 125, 126].contains(Int(event.keyCode))
        if navigation { willNavigate?() }
        super.keyDown(with: event)
        if navigation { didNavigate?() }
    }

    @objc func copy(_ sender: Any?) {
        guard let markdown = copyMessages?(), !markdown.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
}

final class DemoScrollView: NSScrollView {
    var willNavigate: (() -> Void)?
    var didNavigate: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        willNavigate?()
        super.scrollWheel(with: event)
        didNavigate?()
    }
}

private final class DemoMessageRow: NSView {
    var markdown: String
    var streamingCell: TextKitCell?

    init(markdown: String) {
        self.markdown = markdown
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func copyMessage(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
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
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Keeps the text's attributes when selecting it switches the field to its field editor.
        field.allowsEditingTextAttributes = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        if bounds.width > 0, field.preferredMaxLayoutWidth != bounds.width {
            field.preferredMaxLayoutWidth = bounds.width
        }
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
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
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
