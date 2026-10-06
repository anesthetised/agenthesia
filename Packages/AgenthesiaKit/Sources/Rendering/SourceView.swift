public import AppKit
public import STTextView
public import SwiftUI

/// A read-only source file viewer with line numbers and syntax highlighting.
///
/// The text shows at once; the whole file is highlighted in the background and its colors applied to the text in
/// one pass. Colors as text attributes draw as fast as plain text, unlike Neon's rendering attributes, which cost
/// ~8 ms a frame when scrolling a 10 000-line file.
@MainActor
public final class SourceView: NSView {
    public let textView: STTextView
    public let scrollView: NSScrollView
    let gutter = LineNumberGutter()
    public var theme: Theme {
        didSet { applyTheme() }
    }

    public private(set) var text = ""
    public private(set) var language: CodeLanguage?
    /// Offsets where each line starts, in UTF-16 units.
    private(set) var lineStarts = [0]
    /// Counts texts shown, so that colors computed for an earlier text are not applied.
    private var generation = 0

    #if DEBUG
        /// Benchmark instrumentation: completion of the latest highlight, including applying its attributes.
        public private(set) var highlightCompletedAt: ContinuousClock.Instant?
    #endif

    public init(theme: Theme = .standard) {
        self.theme = theme
        textView = STTextView()
        scrollView = NSScrollView()
        super.init(frame: .zero)

        // As STTextView.scrollableTextView() sets it up.
        scrollView.clipsToBounds = true
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        textView.isEditable = false
        textView.highlightSelectedLine = false
        applyTheme()

        gutter.textView = textView
        gutter.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleTextChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func visibleTextChanged() {
        gutter.needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var lineCount: Int { lineStarts.count }

    public var showsLineNumbers: Bool {
        get { !gutter.isHidden }
        set { gutter.isHidden = !newValue }
    }

    /// Shows `text`, highlighted as `language`; `nil` shows it without colors.
    public func setText(_ text: String, language: CodeLanguage?) {
        self.text = text
        self.language = language
        lineStarts = Self.lineStarts(of: text)
        textView.text = text
        gutter.lineStarts = lineStarts
        startHighlighting()
    }

    private func applyTheme() {
        textView.font = theme.codeFont
        textView.textColor = theme.textColor
        gutter.font = theme.codeFont
        gutter.color = theme.secondaryTextColor
        startHighlighting()
    }

    // MARK: - Highlighting

    private func startHighlighting() {
        generation += 1
        #if DEBUG
            highlightCompletedAt = nil
        #endif
        guard let language, !text.isEmpty else { return }
        let generation = generation
        let text = text
        let highlighter = Highlighter(theme: theme)
        Task {
            // The colored text is created on a background queue and handed over whole, so it is never shared.
            let colored: NSAttributedString = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: highlighter.highlight(text, language: language))
                }
            }
            guard generation == self.generation else { return }
            // Replacing the whole text costs about as much as showing it; coloring it in place took up to 300 ms.
            let origin = scrollView.contentView.bounds.origin
            textView.attributedText = colored
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            #if DEBUG
                highlightCompletedAt = .now
            #endif
        }
    }

    // MARK: - Lines

    static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A {
            starts.append(offset + 1)
        }
        return starts
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
}

/// ``SourceView`` for SwiftUI.
public struct SourceViewRepresentable: NSViewRepresentable {
    public var text: String
    public var language: CodeLanguage?

    public init(text: String, language: CodeLanguage?) {
        self.text = text
        self.language = language
    }

    public func makeNSView(context: Context) -> SourceView {
        let view = SourceView()
        view.setText(text, language: language)
        return view
    }

    public func updateNSView(_ view: SourceView, context: Context) {
        if view.text != text || view.language != language {
            view.setText(text, language: language)
        }
    }
}
