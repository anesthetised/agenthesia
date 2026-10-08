import AppKit
import Rendering
import SwiftUI

struct DemoTranscript: NSViewRepresentable {
    let session: DemoSession

    func makeCoordinator() -> TranscriptTableController { TranscriptTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(session)
        return context.coordinator.scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(session)
    }
}

/// Shared native A′ table. The Rendering Lab keeps its measurement implementation unchanged.
final class TranscriptTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = TranscriptTableView()
    let scroll = TranscriptScrollView()
    private weak var session: (any TranscriptSource)?
    private var revision = -1
    private var count = 0
    private var followingBottom = true
    private var adjustingScroll = false
    private var followScheduled = false

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
        table.setAccessibilityLabel("Conversation")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.didLayout = { [weak self] in self?.scheduleFollowEnd() }
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
            (0..<session.messageCount).contains(row) ? session.message(at: row).markdown : nil
        }.joined(separator: "\n\n")
    }

    static func followsBottom(documentHeight: CGFloat, visibleRect: NSRect) -> Bool {
        documentHeight - visibleRect.maxY <= 24
    }

    func update(_ session: any TranscriptSource) {
        guard revision != session.revision || self.session !== session else { return }
        let initial = self.session !== session
        let origin = scroll.contentView.bounds.origin
        self.session = session
        if initial {
            count = 0
            followingBottom = true
            table.reloadData()
        } else if count < session.messageCount {
            table.insertRows(at: IndexSet(integersIn: count..<session.messageCount))
        }
        // ACP can revise an earlier message or tool row, including in the same frame as an append.
        // Refresh only materialized rows; history is rendered lazily when scrolled into view.
        var changed = IndexSet()
        var available = IndexSet()
        table.enumerateAvailableRowViews { _, row in available.insert(row) }
        for row in available where row < min(count, session.messageCount) {
            guard let visible = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptMessageRow
            else {
                continue
            }
            let message = session.message(at: row)
            let finished = !session.isStreaming(at: row)
            let keepsSelection = visible.streamingCell?.textView.selectedRange().length ?? 0 > 0
            if visible.markdown == message.markdown, visible.tool == message.tool,
                !(finished && visible.streamingCell != nil && !keepsSelection)
            {
                continue
            }
            if visible.tool != message.tool, visible.markdown == message.markdown {
                visible.showHeader(message, controller: self)
            } else if visible.tool != message.tool {
                // The header and body changed; rebuild the row's content in place.
                visible.show(message, streaming: !finished, width: table.tableColumns[0].width - 48, controller: self)
            } else if finished, !keepsSelection {
                visible.showFinished(message, width: table.tableColumns[0].width - 48)
            } else if let cell = visible.streamingCell {
                if let update = message.update, visible.markdown == message.previousMarkdown {
                    cell.textView.apply(update)
                } else {
                    let selection = cell.textView.selectedRange()
                    cell.textView.textStorage?.setAttributedString(message.text)
                    let length = message.text.length
                    cell.textView.setSelectedRange(
                        NSRange(
                            location: min(selection.location, length),
                            length: min(selection.length, max(0, length - selection.location))
                        )
                    )
                    cell.textView.invalidateIntrinsicContentSize()
                }
            } else {
                // `reloadData(forRowIndexes:)` leaves AppKit width constraints pointing at the replaced cell,
                // which throws on the next table resize.
                visible.show(message, streaming: true, width: table.tableColumns[0].width - 48, controller: self)
            }
            visible.markdown = message.markdown
            changed.insert(row)
        }
        if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
        count = session.messageCount
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

    private func scheduleFollowEnd() {
        guard !followScheduled else { return }
        followScheduled = true
        // Scrolling can materialize rows. Never do that while NSTableView changes row constraints.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.followScheduled = false
            self.followEnd()
        }
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

    func numberOfRows(in tableView: NSTableView) -> Int { session?.messageCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session else { return nil }
        let rowView = TranscriptMessageRow(markdown: "")
        rowView.show(
            session.message(at: row),
            streaming: session.isStreaming(at: row),
            width: tableView.tableColumns[0].width - 48,
            controller: self
        )
        return rowView
    }

    @objc func toggleExpansion(_ sender: NSView) {
        let row = table.row(for: sender)
        guard let session, row >= 0, row < session.messageCount else { return }
        session.toggleExpansion(at: row)
        update(session)
    }

    /// The button's tag is the option's index; the controller ignores answers to settled requests.
    @objc func choosePermission(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard let session, row >= 0, row < session.messageCount else { return }
        session.choosePermission(at: row, option: sender.tag)
    }
}

final class TranscriptTableView: NSTableView {
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

final class TranscriptScrollView: NSScrollView {
    var willNavigate: (() -> Void)?
    var didNavigate: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        willNavigate?()
        super.scrollWheel(with: event)
        didNavigate?()
    }
}

private final class TranscriptMessageRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("DemoMessage")
    var markdown: String
    var tool: ToolCardHeader?
    var streamingCell: TextKitCell?
    var stack: NSStackView?
    var contentWidth: NSLayoutConstraint?
    var actions: NSView?

    init(markdown: String) {
        self.markdown = markdown
        super.init(frame: .zero)
        identifier = Self.id
    }

    /// Replaces the row's header and body.
    func show(_ message: TranscriptMessage, streaming: Bool, width: CGFloat, controller: TranscriptTableController) {
        stack?.removeFromSuperview()
        actions = nil
        markdown = message.markdown
        tool = message.tool
        let content: NSView
        if streaming {
            let cell = TextKitCell()
            cell.textView.textStorage?.setAttributedString(message.text)
            cell.textView.invalidateIntrinsicContentSize()
            content = cell
        } else {
            let cell = TextCell()
            cell.field.preferredMaxLayoutWidth = max(1, width)
            cell.field.attributedStringValue = message.text
            content = cell
        }
        let header = makeHeader(message, controller: controller)
        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        streamingCell = content as? TextKitCell
        self.stack = stack
        let contentWidth = content.widthAnchor.constraint(equalTo: stack.widthAnchor)
        self.contentWidth = contentWidth
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentWidth,
        ])
        showActions(message, controller: controller)
    }

    /// Keep the text field and its field editor attached when only native metadata changes.
    func showHeader(_ message: TranscriptMessage, controller: TranscriptTableController) {
        guard let stack, let old = stack.arrangedSubviews.first else { return }
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()
        let header = makeHeader(message, controller: controller)
        stack.insertArrangedSubview(header, at: 0)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        tool = message.tool
        showActions(message, controller: controller)
    }

    /// Option buttons stay below the body, so finishing a streamed body does not touch them.
    private func showActions(_ message: TranscriptMessage, controller: TranscriptTableController) {
        if let actions {
            stack?.removeArrangedSubview(actions)
            actions.removeFromSuperview()
            self.actions = nil
        }
        guard let tool = message.tool, !tool.actions.isEmpty, let stack else { return }
        let buttons = tool.actions.enumerated().map { index, title in
            let button = NSButton(
                title: title,
                target: controller,
                action: #selector(TranscriptTableController.choosePermission(_:))
            )
            button.tag = index
            button.bezelStyle = .push
            if tool.shortcuts, index < 9 { button.toolTip = "⌥⌘\(index + 1)" }
            return button
        }
        let actions = NSStackView(views: buttons)
        actions.setAccessibilityLabel("Permission options")
        stack.addArrangedSubview(actions)
        self.actions = actions
    }

    private func makeHeader(_ message: TranscriptMessage, controller: TranscriptTableController) -> NSStackView {
        let role = NSTextField(labelWithString: message.tool?.kind ?? message.role)
        role.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        role.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyMessage(_:)))
        copy.bezelStyle = .inline
        copy.toolTip = "Copy message as Markdown"
        let header = NSStackView(
            views: Self.toolHeader(message.tool, role: role, controller: controller) + [NSView(), copy]
        )
        header.distribution = .fill
        return header
    }

    private static func toolHeader(
        _ tool: ToolCardHeader?,
        role: NSTextField,
        controller: TranscriptTableController
    ) -> [NSView] {
        guard let tool else { return [role] }
        var views: [NSView] = []
        if tool.expandable {
            let disclosure = NSButton(
                title: "",
                target: controller,
                action: #selector(TranscriptTableController.toggleExpansion(_:))
            )
            disclosure.bezelStyle = .disclosure
            disclosure.setButtonType(.pushOnPushOff)
            disclosure.state = tool.expanded ? .on : .off
            disclosure.setAccessibilityLabel(tool.expanded ? "Show less" : "Show all")
            views.append(disclosure)
        }
        let icon = NSImageView(
            image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.kind) ?? NSImage()
        )
        icon.contentTintColor = .secondaryLabelColor
        let status = NSTextField(labelWithString: tool.status)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor =
            switch tool.tone {
            case .neutral: .secondaryLabelColor
            case .running: .controlAccentColor
            case .success: .systemGreen
            case .failure: .systemRed
            }
        return views + [icon, role, status]
    }

    func showFinished(_ message: DemoSession.Message, width: CGFloat) {
        markdown = message.markdown
        guard let stack else { return }
        let cell = TextCell()
        cell.field.preferredMaxLayoutWidth = max(1, width)
        cell.field.attributedStringValue = message.text
        contentWidth?.isActive = false
        // The body follows the header; option buttons, if any, stay after it.
        if stack.arrangedSubviews.count > 1 {
            let old = stack.arrangedSubviews[1]
            stack.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        stack.insertArrangedSubview(cell, at: min(1, stack.arrangedSubviews.count))
        contentWidth = cell.widthAnchor.constraint(equalTo: stack.widthAnchor)
        contentWidth?.isActive = true
        streamingCell = nil
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
