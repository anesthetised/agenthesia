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
    /// Opens a file of the displayed session; without it, path links do nothing.
    var openPath: ((PathLink) -> Void)?

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
            if visible.markdown == message.markdown, visible.links == message.links, visible.tool == message.tool,
                visible.input == message.input, !(finished && visible.streamingCell != nil && !keepsSelection)
            {
                continue
            }
            if visible.input != message.input {
                visible.show(
                    message,
                    streaming: !finished,
                    width: TranscriptColumn.width(inRowOfWidth: table.tableColumns[0].width),
                    controller: self
                )
            } else if visible.tool != message.tool, visible.markdown == message.markdown {
                visible.showHeader(message, controller: self)
            } else if visible.tool != message.tool {
                // The header and body changed; rebuild the row's content in place.
                visible.show(
                    message,
                    streaming: !finished,
                    width: TranscriptColumn.width(inRowOfWidth: table.tableColumns[0].width),
                    controller: self
                )
            } else if finished, !keepsSelection {
                visible.showFinished(
                    message,
                    width: TranscriptColumn.width(inRowOfWidth: table.tableColumns[0].width),
                    controller: self
                )
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
                visible.show(
                    message,
                    streaming: true,
                    width: TranscriptColumn.width(inRowOfWidth: table.tableColumns[0].width),
                    controller: self
                )
            }
            visible.markdown = message.markdown
            visible.links = message.links
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
            width: TranscriptColumn.width(inRowOfWidth: tableView.tableColumns[0].width),
            controller: self
        )
        return rowView
    }

    /// Consumes the transcript's own links, so that they never reach `NSWorkspace`; others are left to AppKit.
    func follow(_ url: URL) -> Bool {
        guard PathLink.claims(url) else { return false }
        if let link = PathLink(url) { openPath?(link) }
        return true
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
    var links: Int?
    var tool: ToolCardHeader?
    var input: InputCard?
    var streamingCell: TextKitCell?
    var stack: NSStackView?
    var contentWidth: NSLayoutConstraint?
    var actions: NSView?
    /// Shown only while the pointer is over the row; Copy stays available as an accessibility action.
    private var copyButton: NSButton?
    private(set) var hovering = false

    init(markdown: String) {
        self.markdown = markdown
        super.init(frame: .zero)
        identifier = Self.id
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Copy") { [weak self] in
                self?.copyMessage(nil)
                return true
            }
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    func setHovering(_ hovering: Bool) {
        self.hovering = hovering
        copyButton?.alphaValue = hovering ? 1 : 0
        copyButton?.setAccessibilityElement(hovering)
    }

    /// Replaces the row's header and body.
    func show(_ message: TranscriptMessage, streaming: Bool, width: CGFloat, controller: TranscriptTableController) {
        stack?.removeFromSuperview()
        actions = nil
        markdown = message.markdown
        links = message.links
        tool = message.tool
        input = message.input
        if message.isNotice {
            showNotice(message)
            return
        }
        let content: NSView
        if streaming {
            let cell = TextKitCell()
            cell.textView.followLink = { [weak controller] in controller?.follow($0) ?? false }
            cell.textView.textStorage?.setAttributedString(message.text)
            cell.textView.invalidateIntrinsicContentSize()
            content = cell
        } else {
            let cell = TextCell()
            cell.field.followLink = { [weak controller] in controller?.follow($0) ?? false }
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
        NSLayoutConstraint.activate(
            columnConstraints(for: stack) + [
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                header.widthAnchor.constraint(equalTo: stack.widthAnchor),
                contentWidth,
            ]
        )
        showActions(message, controller: controller)
        if let input = message.input {
            let form = NSHostingView(rootView: InputForm(card: input))
            stack.addArrangedSubview(form)
            form.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Centers `view` in a column of at most `TranscriptColumn.maxWidth`, which shrinks to keep the margins.
    private func columnConstraints(for view: NSView) -> [NSLayoutConstraint] {
        let fill = view.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * TranscriptColumn.minMargin)
        fill.priority = .defaultHigh
        return [
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: TranscriptColumn.maxWidth),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: TranscriptColumn.minMargin),
            fill,
        ]
    }

    /// A session notice is a quiet caption between two hairlines; it has no role label and no Copy.
    private func showNotice(_ message: TranscriptMessage) {
        let caption = NSTextField(wrappingLabelWithString: message.markdown)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.isSelectable = true
        caption.setContentHuggingPriority(.required, for: .horizontal)
        let lines = [NSBox(), NSBox()]
        for line in lines {
            line.boxType = .separator
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        let stack = NSStackView(views: [lines[0], caption, lines[1]])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        self.stack = stack
        NSLayoutConstraint.activate(
            columnConstraints(for: stack) + [
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                lines[0].widthAnchor.constraint(equalTo: lines[1].widthAnchor),
            ]
        )
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
        actions.orientation = .vertical
        actions.alignment = .leading
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
        copy.alphaValue = hovering ? 1 : 0
        // Assistive technology uses the row's Copy action while the button is not shown.
        copy.setAccessibilityElement(hovering)
        copyButton = copy
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
            disclosure.setAccessibilityLabel(
                tool.detailsDisclosure
                    ? (tool.expanded ? "Hide details" : "Details") : (tool.expanded ? "Show less" : "Show all")
            )
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

    func showFinished(_ message: DemoSession.Message, width: CGFloat, controller: TranscriptTableController) {
        markdown = message.markdown
        links = message.links
        guard let stack else { return }
        let cell = TextCell()
        cell.field.followLink = { [weak controller] in controller?.follow($0) ?? false }
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

/// A selectable text field that lets the transcript handle its links before AppKit opens them.
final class LinkTextField: NSTextField {
    var followLink: ((URL) -> Bool)?

    /// The delegate method of the field editor, which AppKit calls on its owner when a link is clicked.
    @objc(textView:clickedOnLink:atIndex:) func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }) else { return false }
        return followLink?(url) ?? false
    }
}

/// A row with a message: a selectable, wrapping text field.
private final class TextCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("TextCell")
    let field = LinkTextField(wrappingLabelWithString: "")

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
    let textView = TranscriptTextView(usingTextLayoutManager: true)

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
final class TranscriptTextView: NSTextView {
    private var measuredWidth: CGFloat = 0
    var followLink: ((URL) -> Bool)?

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }), followLink?(url) == true {
            return
        }
        super.clicked(onLink: link, at: charIndex)
    }

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
