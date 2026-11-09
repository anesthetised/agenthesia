import AgenthesiaCore
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

/// Where the reader is relative to the end of the transcript (ADR-0026's amendment).
enum EndPosition: Equatable {
    /// At the end, or following it as it grows.
    case following
    /// Away from the end, which has not changed since the reader left it.
    case scrolledUp
    /// Away from the end, which has changed since the reader left it: `New response below`.
    case newBelow
}

/// Shared native A′ table. The Rendering Lab keeps its measurement implementation unchanged.
final class TranscriptTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = TranscriptTableView()
    let scroll = TranscriptScrollView()
    private weak var session: (any TranscriptSource)?
    private var revision = -1
    private var shownRows: [TranscriptRow] = []
    private var followingBottom = true {
        didSet {
            guard followingBottom != oldValue else { return }
            // Leaving the end remembers it; coming back to it forgets what changed meanwhile.
            if followingBottom { endChanged = false } else { endWhenLeft = session?.end }
            reportPosition()
        }
    }
    /// The transcript's end when the reader left it, and whether it differs now. Only checked while not following.
    private var endWhenLeft: TranscriptState.End?
    private var endChanged = false {
        didSet { if endChanged != oldValue { reportPosition() } }
    }
    private var reportedPosition: EndPosition?
    private var positionReportScheduled = false
    private var adjustingScroll = false
    private var followScheduled = false
    /// What the find bar searches for; rows that show text mark it.
    var findQuery = "" {
        didSet { if findQuery != oldValue { highlightVisibleRows() } }
    }
    /// Opens a file of the displayed session; without it, path links do nothing.
    var openPath: ((PathLink) -> Void)?
    /// The item where an unseen result ends (ADR-0026's amendment). The viewport is watched only while it is set.
    var unseenResult: Int64? {
        didSet {
            guard unseenResult != oldValue else { return }
            if (unseenResult == nil) != (oldValue == nil) { watchViewport(unseenResult != nil) }
            scheduleResultCheck()
        }
    }
    /// Told where the reader is relative to the end, on a later main-queue turn and only when it changed.
    var positionChanged: ((EndPosition) -> Void)?
    /// Called once the end of `unseenResult`'s row was on screen; the table stops watching then.
    var resultShown: ((Int64) -> Void)?
    /// How many coalesced checks ran, so tests can see that nothing runs without a result to watch for.
    private(set) var resultChecks = 0
    private var resultCheckScheduled = false

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
        table.didLayout = { [weak self] in
            self?.scheduleFollowEnd()
            self?.scheduleResultCheck()
        }
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
        return table.selectedRowIndexes.compactMap { row -> String? in
            guard (0..<session.messageCount).contains(row) else { return nil }
            let message = session.message(at: row)
            // An expanded group's cards are rows of their own, so a selection never copies them twice.
            let cards = session.cardCount(ofGroupAt: row)
            if cards > 0, table.selectedRowIndexes.intersects(integersIn: (row + 1)..<(row + 1 + cards)) { return nil }
            return message.copyText?() ?? message.markdown
        }.joined(separator: "\n\n")
    }

    private static let bottomTolerance: CGFloat = 24

    static func followsBottom(documentHeight: CGFloat, visibleRect: NSRect) -> Bool {
        documentHeight - visibleRect.maxY <= bottomTolerance
    }

    /// A row's end is on screen when its bottom edge is within the visible rect, with `followsBottom`'s tolerance:
    /// the top of an answer taller than the viewport is not its result yet.
    static func showsEnd(of row: NSRect, in visibleRect: NSRect) -> Bool {
        row.maxY >= visibleRect.minY && row.maxY - visibleRect.maxY <= bottomTolerance
    }

    /// Whether the reader follows the end of the transcript.
    var followsEnd: Bool { followingBottom }

    var position: EndPosition { followingBottom ? .following : endChanged ? .newBelow : .scrolledUp }

    /// Tells `positionChanged` the current position, also the first time, so that a new table resets what a previous
    /// one reported.
    func reportPosition() {
        guard !positionReportScheduled else { return }
        positionReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.positionReportScheduled = false
            guard self.position != self.reportedPosition else { return }
            self.reportedPosition = self.position
            self.positionChanged?(self.position)
        }
    }

    /// Scrolls to the end without animation and follows it again.
    func scrollToEnd() {
        followingBottom = true
        followEnd()
    }

    func update(_ session: any TranscriptSource) {
        guard revision != session.revision || self.session !== session else { return }
        let initial = self.session !== session
        let origin = scroll.contentView.bounds.origin
        self.session = session
        let rows = session.rows
        if initial {
            followingBottom = true
            table.reloadData()
        } else if rows != shownRows {
            applyRowChanges(rows.difference(from: shownRows))
        }
        shownRows = rows
        // ACP can revise an earlier message or tool row, including in the same frame as an append.
        // Refresh only materialized rows; history is rendered lazily when scrolled into view.
        var changed = IndexSet()
        var available = IndexSet()
        table.enumerateAvailableRowViews { _, row in available.insert(row) }
        for row in available where !initial && row < rows.count {
            guard let visible = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptMessageRow
            else {
                continue
            }
            let message = session.message(at: row)
            let finished = !session.isStreaming(at: row)
            let keepsSelection = visible.streamingCell?.textView.selectedRange().length ?? 0 > 0
            let sameBody =
                visible.markdown == message.markdown && visible.links == message.links
                && visible.caption == message.caption
                && !(finished && visible.streamingCell != nil && !keepsSelection)
            // Only a one-line header's text changed, as a collapsed thought's does with every chunk: the row keeps its
            // views and its height, so it is not measured again.
            if sameBody, visible.tool == message.tool || message.tool.map(visible.retitle) == true { continue }
            if visible.caption != message.caption {
                visible.show(
                    message,
                    streaming: !finished,
                    width: TranscriptColumn.width(inRowOfWidth: table.tableColumns[0].width),
                    controller: self
                )
            } else if visible.tool != message.tool, visible.markdown == message.markdown {
                visible.showHeader(message, controller: self)
                // Thoughts that end change their header with the text they streamed.
                if finished, visible.streamingCell != nil, !keepsSelection {
                    visible.showFinished(
                        message,
                        width: TranscriptColumn.width(inRowOfWidth: table.tableColumns[0].width),
                        controller: self
                    )
                }
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
        revision = session.revision
        if !findQuery.isEmpty { highlightVisibleRows() }
        table.layoutSubtreeIfNeeded()
        if followingBottom {
            followEnd()
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            if !endChanged, session.end != endWhenLeft { endChanged = true }
        }
        scheduleResultCheck()
    }

    /// Scrolling and a resized clip view, as when the permission card docks, move the viewport.
    private func watchViewport(_ watching: Bool) {
        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            if watching {
                center.addObserver(self, selector: #selector(viewportDidChange), name: name, object: scroll.contentView)
            } else {
                center.removeObserver(self, name: name, object: scroll.contentView)
            }
        }
    }

    @objc private func viewportDidChange(_ notification: Notification) { scheduleResultCheck() }

    /// One check per run-loop turn, however many scrolls, updates and layouts asked for it.
    private func scheduleResultCheck() {
        guard unseenResult != nil, !resultCheckScheduled else { return }
        resultCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resultCheckScheduled = false
            self.resultChecks += 1
            self.checkResult()
        }
    }

    private func checkResult() {
        guard let item = unseenResult, let row = session?.row(ofItem: item), row < table.numberOfRows,
            Self.showsEnd(of: table.rect(ofRow: row), in: scroll.contentView.bounds)
        else { return }
        unseenResult = nil
        resultShown?(item)
    }

    private func highlightVisibleRows() {
        table.enumerateAvailableRowViews { _, row in
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptMessageRow)?.highlight(findQuery)
        }
    }

    /// Scrolls to a row that find stepped to and selects it. Row heights settle during layout, so it scrolls again after.
    func reveal(row: Int) {
        guard row < table.numberOfRows else { return }
        followingBottom = false
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        DispatchQueue.main.async { [weak self] in
            guard let self, row < self.table.numberOfRows else { return }
            self.table.scrollRowToVisible(row)
        }
    }

    /// Rows that stay keep their views, so text selected in them and their field editors survive.
    private func applyRowChanges(_ changes: CollectionDifference<TranscriptRow>) {
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        table.beginUpdates()
        table.removeRows(at: removed)
        table.insertRows(at: inserted)
        table.endUpdates()
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { TranscriptRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session else { return nil }
        let rowView = TranscriptMessageRow(markdown: "")
        rowView.show(
            session.message(at: row),
            streaming: session.isStreaming(at: row),
            width: TranscriptColumn.width(inRowOfWidth: tableView.tableColumns[0].width),
            controller: self
        )
        rowView.highlight(findQuery)
        return rowView
    }

    /// Consumes the transcript's own links and relative ones (against the working directory), so that they never
    /// reach `NSWorkspace`; web and mail links are left to AppKit.
    func follow(_ url: URL) -> Bool {
        if PathLink.claims(url) {
            if let link = PathLink(url) { openPath?(link) }
            return true
        }
        guard let root = (session as? LiveTranscriptSource)?.root else { return false }
        switch LinkTarget(url, base: root, root: root) {
        case .file(let path): openPath?(PathLink(path: path))
        case .external: return false
        case .ignored: break
        }
        return true
    }

    @objc func toggleExpansion(_ sender: NSView) {
        let row = table.row(for: sender)
        guard let session, row >= 0, row < session.messageCount else { return }
        session.toggleExpansion(at: row)
        update(session)
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

/// How firmly a row's content keeps its own height: above the height AppKit gives a row (priority 500), so a row last
/// measured at another width shrinks to its content instead of stretching it.
private let rowContentHugging = NSLayoutConstraint.Priority(501)

private final class TranscriptMessageRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("DemoMessage")
    var markdown: String
    var links: Int?
    var tool: ToolCardHeader?
    var caption: String?
    var copyText: (() -> String)?
    var streamingCell: TextKitCell?
    var bubble: BubbleCell?
    var stack: NSStackView?
    var contentWidth: NSLayoutConstraint?
    /// Shown only while the pointer is over the row; Copy stays available as an accessibility action.
    private var copyButton: NSButton?
    private weak var statusLabel: NSTextField?
    private weak var roleLabel: NSTextField?
    /// The field showing the message, with its text before find marked it. A streaming row has none.
    private weak var messageField: LinkTextField?
    private var messageText = NSAttributedString()
    private var markedQuery = ""
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
        // A layout that moves the row from under a still pointer sends no exit event, but it updates the tracking
        // areas: Copy follows where the pointer is now.
        if let window {
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setHovering(window.isKeyWindow && bounds.contains(pointer))
        }
    }

    override func layout() {
        super.layout()
        bubble?.fit(columnWidth: TranscriptColumn.width(inRowOfWidth: bounds.width))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    func setHovering(_ hovering: Bool) {
        self.hovering = hovering
        copyButton?.alphaValue = hovering ? 1 : 0
        copyButton?.setAccessibilityElement(hovering)
    }

    func highlight(_ query: String) {
        guard query != markedQuery, let messageField else { return }
        markedQuery = query
        messageField.attributedStringValue = TranscriptSearch.highlighted(messageText, query: query)
    }

    private func setMessageField(_ field: LinkTextField, text: NSAttributedString) {
        messageField = field
        messageText = text
        markedQuery = ""
    }

    /// Replaces the row's header and body.
    func show(_ message: TranscriptMessage, streaming: Bool, width: CGFloat, controller: TranscriptTableController) {
        stack?.removeFromSuperview()
        bubble = nil
        messageField = nil
        markdown = message.markdown
        links = message.links
        tool = message.tool
        caption = message.caption
        copyText = message.copyText
        if message.kind == .interruption {
            showDivider(message)
            return
        }
        if message.isNotice {
            showNotice(message)
            return
        }
        if message.kind == .group || (message.kind == .question && message.markdown.isEmpty) {
            showGroup(message, controller: controller)
            return
        }
        let content: NSView
        if streaming {
            let cell = TextKitCell()
            cell.textView.followLink = { [weak controller] in controller?.follow($0) ?? false }
            cell.textView.textStorage?.setAttributedString(message.text)
            cell.textView.invalidateIntrinsicContentSize()
            content = cell
        } else if message.kind == .user {
            let cell = BubbleCell()
            cell.field.followLink = { [weak controller] in controller?.follow($0) ?? false }
            cell.field.attributedStringValue = message.text
            setMessageField(cell.field, text: message.text)
            cell.fit(columnWidth: width)
            bubble = cell
            content = cell
        } else {
            let cell = TextCell()
            cell.field.followLink = { [weak controller] in controller?.follow($0) ?? false }
            cell.field.preferredMaxLayoutWidth = max(1, width)
            cell.field.attributedStringValue = message.text
            setMessageField(cell.field, text: message.text)
            content = cell
        }
        if message.kind == .thought { content.alphaValue = Self.thoughtAlpha }
        if message.kind == .failure { content.alphaValue = Self.failureAlpha }
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
        if let caption = message.caption {
            let label = NSTextField(labelWithString: caption)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if message.kind == .failure {
            readAsOneElement(stack, label: "Error: \(message.text.string)", message: message)
        }
    }

    /// Thoughts read as secondary text; dimming keeps the code colors of their Markdown.
    private static let thoughtAlpha: CGFloat = 0.65
    /// An error's message under its red label, as T3 Code dims it.
    private static let failureAlpha: CGFloat = 0.8

    /// VoiceOver reads `view` as one element with `label`; the row's Copy and a disclosure inside it become its actions.
    private func readAsOneElement(_ view: NSView, label: String, message: TranscriptMessage) {
        for child in descendants(of: view) { child.setAccessibilityElement(false) }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(label)
        var actions = accessibilityCustomActions() ?? []
        if let tool = message.tool, tool.expandable,
            let disclosure = descendants(of: view).compactMap({ $0 as? NSButton }).first(where: {
                $0.bezelStyle == .disclosure
            })
        {
            actions.append(
                NSAccessibilityCustomAction(name: tool.expanded ? "Hide details" : "Details") { [weak disclosure] in
                    disclosure?.performClick(nil)
                    return true
                }
            )
        }
        view.setAccessibilityCustomActions(actions)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Centers `view` in a column of at most `TranscriptColumn.maxWidth`, which shrinks to keep the margins, and keeps
    /// the row as tall as its content.
    private func columnConstraints(for view: NSStackView) -> [NSLayoutConstraint] {
        view.setHuggingPriority(rowContentHugging, for: .vertical)
        let fill = view.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * TranscriptColumn.minMargin)
        // Below AppKit's width for the cell (priority 500): above it, a wide row shrinks to fit the column's maximum
        // and the column loses its center.
        fill.priority = .init(499)
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

    /// An interrupted turn ends with a thin red divider: a line, an X, the text, a line, without a box or Copy.
    private func showDivider(_ message: TranscriptMessage) {
        let size = NSFont.smallSystemFontSize
        let text = NSMutableAttributedString(
            string: message.markdown,
            attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.systemRed.withAlphaComponent(0.7),
            ]
        )
        // The label in medium weight, its detail after ` · ` dimmed, as T3 Code's system divider.
        let label = (message.markdown as NSString).range(of: " · ")
        let lead = NSRange(location: 0, length: label.location == NSNotFound ? text.length : label.location)
        text.addAttributes(
            [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.systemRed],
            range: lead
        )
        let caption = NSTextField(labelWithAttributedString: text)
        caption.setContentHuggingPriority(.required, for: .horizontal)
        let icon = NSImageView(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size - 2, weight: .semibold)) ?? NSImage()
        )
        icon.contentTintColor = .systemRed
        let lines = [NSBox(), NSBox()]
        for line in lines {
            line.boxType = .separator
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        let stack = NSStackView(views: [lines[0], icon, caption, lines[1]])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(12, after: lines[0])
        stack.setCustomSpacing(12, after: caption)
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
        readAsOneElement(stack, label: message.markdown, message: message)
    }

    /// A folded group is only a header; its tool cards are rows of their own once it is expanded.
    private func showGroup(_ message: TranscriptMessage, controller: TranscriptTableController) {
        let header = makeHeader(message, controller: controller)
        let stack = NSStackView(views: [header])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        self.stack = stack
        NSLayoutConstraint.activate(
            columnConstraints(for: stack) + [
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ]
        )
    }

    /// Replaces the text of a truncating header label in place when nothing else in the header changed; false otherwise.
    func retitle(_ header: ToolCardHeader) -> Bool {
        guard var shown = tool, let roleLabel, roleLabel.lineBreakMode == .byTruncatingTail else { return false }
        shown.kind = header.kind
        guard shown == header else { return false }
        roleLabel.stringValue = header.kind
        tool = header
        return true
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
    }

    private func makeHeader(_ message: TranscriptMessage, controller: TranscriptTableController) -> NSStackView {
        let role = NSTextField(labelWithString: message.tool?.kind ?? message.role)
        role.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        role.textColor = .secondaryLabelColor
        roleLabel = role
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyMessage(_:)))
        // The inline bezel draws light text on a light fill, unreadable on the selection in light mode; the textured
        // one is a proper control that keeps the label color in light, dark and Increase Contrast.
        copy.bezelStyle = .texturedRounded
        copy.controlSize = .small
        copy.toolTip = "Copy message as Markdown"
        copy.alphaValue = hovering ? 1 : 0
        // Assistive technology uses the row's Copy action while the button is not shown.
        copy.setAccessibilityElement(hovering)
        copyButton = copy
        if message.kind == .group || message.kind == .question || message.tool?.record == true {
            // The title of a running call or a request can be any length.
            role.lineBreakMode = .byTruncatingTail
            role.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        // Users and the agent speak without a label; their Copy button stays at the row's trailing edge.
        let labeled = ![.user, .agent].contains(message.kind)
        let header = NSStackView(
            views: (labeled ? toolHeader(message.tool, kind: message.kind, role: role, controller: controller) : []) + [
                NSView(), copy,
            ]
        )
        header.distribution = .fill
        header.setHuggingPriority(rowContentHugging, for: .vertical)
        // `· kind` follows a record's status as one phrase, so the stack's gap would read as a double space.
        if message.tool?.record == true, let status = statusLabel { header.setCustomSpacing(3, after: status) }
        if message.kind == .question, let status = statusLabel {
            // The answers truncate too, once the questions have given up their room.
            status.lineBreakMode = .byTruncatingTail
            status.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        }
        if message.kind == .failure {
            role.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            role.textColor = .systemRed
        }
        return header
    }

    private func toolHeader(
        _ tool: ToolCardHeader?,
        kind: TranscriptMessage.Kind,
        role: NSTextField,
        controller: TranscriptTableController
    ) -> [NSView] {
        guard let tool else { return [role] }
        // Without details the disclosure stays, invisible and inert, so the icon column does not shift between cards.
        let disclosure = NSButton(
            title: "",
            target: controller,
            action: #selector(TranscriptTableController.toggleExpansion(_:))
        )
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = tool.expanded ? .on : .off
        disclosure.alphaValue = tool.expandable ? 1 : 0
        disclosure.isEnabled = tool.expandable
        disclosure.setAccessibilityElement(tool.expandable)
        disclosure.setAccessibilityLabel(
            tool.detailsDisclosure
                ? (tool.expanded ? "Hide details" : "Details") : (tool.expanded ? "Show less" : "Show all")
        )
        let icon = NSImageView(
            image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.kind) ?? NSImage()
        )
        icon.contentTintColor = kind == .failure ? .systemRed : .secondaryLabelColor
        // The label beside it says the same.
        icon.setAccessibilityElement(false)
        let status = NSTextField(labelWithString: tool.status)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = statusColor(tool.tone)
        statusLabel = status
        // A record leads with its outcome, then says what was asked.
        return tool.record ? [disclosure, icon, status, role] : [disclosure, icon, role, status]
    }

    private func statusColor(_ tone: ToolCardHeader.Tone) -> NSColor {
        switch tone {
        case .neutral: .secondaryLabelColor
        case .primary: .labelColor
        case .running: .controlAccentColor
        case .attention: .systemOrange
        case .success: .systemGreen
        case .failure: .systemRed
        }
    }

    func showFinished(_ message: DemoSession.Message, width: CGFloat, controller: TranscriptTableController) {
        markdown = message.markdown
        links = message.links
        guard let stack else { return }
        let cell = TextCell()
        cell.field.followLink = { [weak controller] in controller?.follow($0) ?? false }
        cell.field.preferredMaxLayoutWidth = max(1, width)
        cell.field.attributedStringValue = message.text
        setMessageField(cell.field, text: message.text)
        if message.kind == .thought { cell.alphaValue = Self.thoughtAlpha }
        contentWidth?.isActive = false
        // The body follows the header.
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
        NSPasteboard.general.setString(copyText?() ?? markdown, forType: .string)
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

/// A transcript row without the system's selection band: a selected row gets a quiet rounded background as wide as
/// the text column plus a small outset, behind its content, and its text keeps its colors.
final class TranscriptRowView: NSTableRowView {
    static let selectionRadius: CGFloat = 10
    /// How far the background reaches past the text column on each side; less than `TranscriptColumn.minMargin`, so
    /// it stays inside the row.
    static let selectionOutset: CGFloat = 8
    static let selectionFade: TimeInterval = 0.12

    let selectionBackground = SelectionBackground()

    override init(frame: NSRect) {
        super.init(frame: frame)
        selectionBackground.alphaValue = 0
        addSubview(selectionBackground, positioned: .below, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The rect of the quiet background in a row of `bounds`.
    var selectionFrame: NSRect {
        NSRect(
            x: TranscriptColumn.minX(inRowOfWidth: bounds.width) - Self.selectionOutset,
            y: 0,
            width: TranscriptColumn.width(inRowOfWidth: bounds.width) + 2 * Self.selectionOutset,
            height: bounds.height
        )
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            let alpha: CGFloat = isSelected ? 1 : 0
            guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                selectionBackground.alphaValue = alpha
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.selectionFade
                selectionBackground.animator().alphaValue = alpha
            }
        }
    }

    /// Text on a selected row stays in its normal colors, as on an unselected one.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func layout() {
        super.layout()
        selectionBackground.frame = selectionFrame
    }
}

final class SelectionBackground: NSView {
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TranscriptRowView.selectionRadius
        setAccessibilityElement(false)
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A user message: a rounded bubble at the trailing edge that hugs its text, up to 80 % of the column.
final class BubbleCell: NSView {
    let field = LinkTextField(wrappingLabelWithString: "")
    private let bubble = BubbleBackground()
    private let width: NSLayoutConstraint
    private var fittedColumnWidth: CGFloat = -1

    init() {
        width = bubble.widthAnchor.constraint(equalToConstant: 0)
        super.init(frame: .zero)
        field.isSelectable = true
        // Keeps the text's attributes when selecting it switches the field to its field editor.
        field.allowsEditingTextAttributes = true
        field.translatesAutoresizingMaskIntoConstraints = false
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(field)
        addSubview(bubble)
        let padding = TranscriptColumn.bubblePadding
        NSLayoutConstraint.activate([
            width,
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: padding.width),
            field.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -padding.width),
            field.topAnchor.constraint(equalTo: bubble.topAnchor, constant: padding.height),
            field.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -padding.height),
        ])
    }

    /// Sizes the bubble to its text, wrapped at the widest the column allows.
    func fit(columnWidth: CGFloat) {
        guard columnWidth != fittedColumnWidth else { return }
        fittedColumnWidth = columnWidth
        // Unwrapped: text that is wider than the limit fills the bubble, as a CSS `fit-content` box does.
        let natural = field.attributedStringValue.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin
        ).width.rounded(.up)
        width.constant = TranscriptColumn.bubbleWidth(forTextWidth: natural, inColumnOfWidth: columnWidth)
        field.preferredMaxLayoutWidth = max(1, width.constant - 2 * TranscriptColumn.bubblePadding.width)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class BubbleBackground: NSView {
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TranscriptColumn.bubbleRadius
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
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
