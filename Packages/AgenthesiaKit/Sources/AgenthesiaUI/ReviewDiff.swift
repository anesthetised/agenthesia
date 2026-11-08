import AgenthesiaCore
import AppKit
import Rendering
import SwiftUI

/// A review document's diff, highlighted and parsed into lines; text line `i` is `lines[i]`.
struct RenderedDiff {
    let document: SessionReview.Document
    let text: NSAttributedString
    let lines: [DiffLine]

    /// Diffs and highlights off the main actor, as `UnifiedDiff.make` grows with the size of the change.
    static func make(_ document: SessionReview.Document, theme: Theme = .standard) async -> RenderedDiff {
        let (text, lines): (NSAttributedString, [DiffLine]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let diff = UnifiedDiff.make(old: document.old, new: document.new)
                let text: NSAttributedString = UnifiedDiff.highlight(diff, theme: theme)
                continuation.resume(returning: (text, UnifiedDiff.parse(diff)))
            }
        }
        return RenderedDiff(document: document, text: text, lines: lines)
    }
}

/// The review's selectable diff text (ADR-0041). It knows where each diff line starts, so a selection maps to
/// lines, and its ruler shows each line's old and new number.
final class DiffTextView: NSTextView {
    private(set) var lines: [DiffLine] = []
    /// Offsets where each text line starts, in UTF-16 units.
    private(set) var lineStarts = [0]
    /// The document shown; a render of the same document changes nothing.
    private(set) var document: SessionReview.Document?
    var onEscape: () -> Void = {}
    /// Ask agent in the context menu; nil leaves it out.
    weak var model: SessionWindowModel?

    /// A scroll view with the text view and its line-number ruler.
    static func scrollable() -> NSScrollView {
        // TextKit 1 with contiguous layout: line positions are exact, which the ruler and keeping the top line need.
        // TextKit 2 and non-contiguous layout estimate the positions of text not laid out yet.
        let textView = DiffTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel("File changes")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.verticalRulerView = DiffGutter(textView: textView, scrollView: scroll)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    /// Shows `diff` in place of the shown one. Unless it is the first, the line at the top stays at the top, or the
    /// nearest line after it in the new file, and the selection ends.
    func show(_ diff: RenderedDiff) {
        guard diff.document != document else { return }
        let anchor = document == nil ? nil : topLine.map { lines[$0].newPosition }
        document = diff.document
        lines = diff.lines
        lineStarts = [0]
        for (offset, unit) in diff.text.string.utf16.enumerated() where unit == 0x0A { lineStarts.append(offset + 1) }
        textStorage?.setAttributedString(diff.text)
        setSelectedRange(NSRange(location: 0, length: 0))
        (enclosingScrollView?.verticalRulerView as? DiffGutter)?.update()
        let target = anchor.flatMap { position in lines.firstIndex { $0.kind != .hunk && $0.newPosition >= position } }
        scroll(toLine: target ?? 0)
    }

    /// The text line at the top of the visible area.
    var topLine: Int? {
        guard !lines.isEmpty, let layout = layoutManager, let container = textContainer else { return nil }
        let visible = visibleRect.offsetBy(dx: 0, dy: -textContainerOrigin.y)
        // A point below the edge: a clip view snapped to whole pixels (scale 1) can sit half a point above the line.
        let glyphs = layout.glyphRange(
            forBoundingRect: NSRect(x: 0, y: visible.minY + 1, width: 1, height: 1),
            in: container
        )
        return Self.line(at: layout.characterIndexForGlyph(at: glyphs.location), lineStarts: lineStarts)
    }

    /// The top of the text line at `index`, in the text view's coordinates.
    func top(ofLine index: Int) -> CGFloat {
        guard let layout = layoutManager, index < lineStarts.count, lineStarts[index] < (string as NSString).length
        else { return textContainerOrigin.y }
        let glyph = layout.glyphIndexForCharacter(at: lineStarts[index])
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
    }

    /// Scrolls the text line at `index` to the top.
    func scroll(toLine index: Int) {
        guard let clip = enclosingScrollView?.contentView, let layout = layoutManager, let container = textContainer
        else { return }
        let y = index == 0 ? 0 : top(ofLine: index)
        if index > 0 {
            // Lays out through the screen below the line and fits the frame to it; otherwise the clip view is clamped
            // to the shorter frame that background layout has reached so far. At the top, layout can stay lazy.
            layout.ensureLayout(
                forBoundingRect: NSRect(x: 0, y: y, width: 1, height: clip.bounds.height),
                in: container
            )
            sizeToFit()
        }
        // The ruler overlays the clip view, which keeps it clear with an inset: x stays as the scroll view set it.
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y - clip.contentInsets.top))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// The zero-based line that contains a UTF-16 offset.
    static func line(at offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The text lines a selection touches, whole: a selection that ends at a line's start leaves that line out.
    /// Nil when nothing is selected.
    static func lines(in selection: NSRange, lineStarts: [Int]) -> ClosedRange<Int>? {
        guard selection.length > 0 else { return nil }
        let first = line(at: selection.location, lineStarts: lineStarts)
        return first...line(at: NSMaxRange(selection) - 1, lineStarts: lineStarts)
    }

    /// The selected lines as an Ask agent quote; `stale` when the file changed since the shown diff (ADR-0041).
    func quote(stale: Bool) -> String? {
        guard let document, let range = Self.lines(in: selectedRange(), lineStarts: lineStarts),
            range.upperBound < lines.count
        else { return nil }
        return DiffQuote.make(path: document.path, lines: Array(lines[range]), stale: stale)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let model, let menu else { return menu }
        let item = NSMenuItem(title: "Ask Agent", action: #selector(askAgent(_:)), keyEquivalent: "")
        item.target = self
        item.toolTip = model.askAgentHelp
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc func askAgent(_ sender: Any?) { model?.askAgent() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(askAgent(_:)) ? model?.canAskAgent == true : super.validateMenuItem(item)
    }

    /// Escape closes the pane unless text is selected (ADR-0041).
    override func cancelOperation(_ sender: Any?) {
        if selectedRange().length == 0 { onEscape() }
    }
}

/// The old and the new line number of each visible diff line; hunk headers have none.
final class DiffGutter: NSRulerView {
    private weak var textView: DiffTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private let padding: CGFloat = 6
    private var columnWidth: CGFloat = 0

    init(textView: DiffTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // The ruler's own background and edge are drawn past its bounds unless clipped (views no longer clip by default).
        clipsToBounds = true
        update()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func scrolled() { needsDisplay = true }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Fits both columns to the largest number shown.
    func update() {
        let largest = textView?.lines.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) } ?? 0
        let digits = max(String(largest).count, 2)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        columnWidth = (CGFloat(digits) * digitWidth).rounded(.up)
        ruleThickness = 2 * columnWidth + 3 * padding
        scrollView?.tile()
        needsDisplay = true
    }

    /// The visible lines' numbers and tops, in the ruler's coordinates.
    func visibleNumbers() -> [(old: Int?, new: Int?, y: CGFloat)] {
        guard let textView, !textView.lines.isEmpty, let layout = textView.layoutManager,
            let container = textView.textContainer
        else { return [] }
        var visible = textView.visibleRect
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = DiffTextView.line(at: characters.location, lineStarts: textView.lineStarts)
        let last = DiffTextView.line(at: NSMaxRange(characters), lineStarts: textView.lineStarts)
        return (first...min(last, textView.lines.count - 1)).compactMap { index in
            let line = textView.lines[index]
            guard line.kind != .hunk else { return nil }
            let y = convert(NSPoint(x: 0, y: textView.top(ofLine: index)), from: textView).y
            return (line.oldNumber, line.newNumber, y)
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]
        // Centered on the code font's first line, which is taller than the ruler's font.
        let offset = ((Theme.standard.codeFont.boundingRectForFont.height - font.boundingRectForFont.height) / 2)
            .rounded()
        for line in visibleNumbers() {
            for (number, x) in [(line.old, padding), (line.new, 2 * padding + columnWidth)] {
                guard let number else { continue }
                let frame = NSRect(
                    x: x,
                    y: line.y + offset,
                    width: columnWidth,
                    height: font.boundingRectForFont.height
                )
                ("\(number)" as NSString).draw(in: frame, withAttributes: attributes)
            }
        }
    }
}

/// ``DiffTextView`` for SwiftUI. It reports whether text is selected, which holds the diff while the file changes,
/// and gives the window's model the view to quote for Ask agent.
struct ReviewDiffView: NSViewRepresentable {
    let diff: RenderedDiff
    let model: SessionWindowModel
    let onSelection: (Bool) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = DiffTextView.scrollable()
        if let textView = scroll.documentView as? DiffTextView {
            textView.delegate = context.coordinator
            update(textView, coordinator: context.coordinator)
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let textView = view.documentView as? DiffTextView else { return }
        update(textView, coordinator: context.coordinator)
    }

    private func update(_ textView: DiffTextView, coordinator: Coordinator) {
        coordinator.onSelection = onSelection
        textView.onEscape = onEscape
        textView.model = model
        model.reviewDiff = textView
        textView.show(diff)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.onSelection(false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: (Bool) -> Void = { _ in }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selected = textView.selectedRange().length > 0
            // Reported only when it changes, so selecting does not invalidate the pane on each drag step.
            if selected != hasSelection {
                hasSelection = selected
                onSelection(selected)
            }
        }

        private var hasSelection = false
    }
}
