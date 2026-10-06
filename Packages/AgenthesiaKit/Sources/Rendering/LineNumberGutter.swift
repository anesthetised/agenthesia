import AppKit
import STTextView

/// Line numbers for the visible lines of a ``SourceView``.
///
/// STTextView's own gutter counts the paragraphs above the viewport and recreates its number views on every
/// layout, which costs ~10 ms a frame deep in a 10 000-line file. This one finds each number by binary search in the
/// line starts and draws the visible ones, so a frame costs the same anywhere in the file.
@MainActor
final class LineNumberGutter: NSView {
    weak var textView: STTextView?
    var lineStarts = [0] {
        didSet { updateWidth() }
    }
    var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) {
        didSet { updateWidth() }
    }
    var color = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    private lazy var width = widthAnchor.constraint(equalToConstant: 0)
    private let padding: CGFloat = 8

    init() {
        super.init(frame: .zero)
        width.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func updateWidth() {
        let digits = max(String(lineStarts.count).count, 2)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        width.constant = (CGFloat(digits) * digitWidth + padding * 2).rounded(.up)
        needsDisplay = true
    }

    /// The numbers of the lines in view, with the top of each line in the gutter's coordinates.
    func visibleLines() -> [(number: Int, y: CGFloat)] {
        guard let textView, let clip = textView.enclosingScrollView?.contentView else { return [] }
        let layout = textView.textLayoutManager
        let content = textView.textContentManager
        let visible = clip.documentVisibleRect
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(visible.minY, 0))) else { return [] }

        var lines: [(number: Int, y: CGFloat)] = []
        layout.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) {
            fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= visible.maxY else { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let y = convert(CGPoint(x: 0, y: frame.minY), from: textView).y
            lines.append((SourceView.line(at: offset, lineStarts: lineStarts) + 1, y))
            return true
        }
        return lines
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = font.ascender - font.descender + font.leading
        for line in visibleLines() {
            let rect = NSRect(x: 0, y: line.y, width: bounds.width - padding, height: height)
            ("\(line.number)" as NSString).draw(in: rect, withAttributes: attributes)
        }
    }
}
