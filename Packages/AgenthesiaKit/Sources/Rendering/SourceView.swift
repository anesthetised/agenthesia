public import AppKit
import Neon
public import STTextView
import SwiftTreeSitter
import SwiftTreeSitterLayer
public import SwiftUI
import TreeSitterClient

/// A read-only source file viewer with line numbers and syntax highlighting.
///
/// Highlighting is lazy: Neon queries tree-sitter only for the visible text, as it scrolls into view, and applies
/// colors as rendering attributes, so the text itself is never restyled.
@MainActor
public final class SourceView: NSView {
    public let textView: STTextView
    public let scrollView: NSScrollView
    public var theme: Theme {
        didSet { applyTheme() }
    }

    public private(set) var text = ""
    public private(set) var language: CodeLanguage?
    /// Offsets where each line starts, in UTF-16 units.
    private(set) var lineStarts = [0]
    private var client: TreeSitterClient?
    private var styler: TextSystemStyler<TextLayoutManagerSystemInterface>?

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
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = false
        applyTheme()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var lineCount: Int { lineStarts.count }

    /// Shows `text`, highlighted as `language`; `nil` shows it without colors.
    public func setText(_ text: String, language: CodeLanguage?) {
        self.text = text
        self.language = language
        lineStarts = Self.lineStarts(of: text)
        textView.text = text
        startHighlighting()
    }

    private func applyTheme() {
        textView.font = theme.codeFont
        textView.textColor = theme.textColor
        textView.gutterView?.font = theme.codeFont
        styler?.invalidate(.all)
        styler?.validate(.range(visibleRange))
    }

    // MARK: - Highlighting

    private func startHighlighting() {
        client = nil
        styler = nil
        guard let configuration = language?.configuration else { return }

        let interface = TextLayoutManagerSystemInterface(textLayoutManager: textView.textLayoutManager) {
            [theme] token in
            theme.color(forCapture: token.name).map { [.foregroundColor: $0] } ?? [:]
        }
        let snapshot = LanguageLayer.ContentSnapshot(string: text)
        let length = text.utf16.count
        let lineStarts = lineStarts
        do {
            let client = try TreeSitterClient(
                rootLanguageConfig: configuration,
                configuration: .init(
                    contentSnapshopProvider: { _ in snapshot },
                    lengthProvider: { length },
                    invalidationHandler: { [weak self] in self?.invalidate($0) },
                    locationTransformer: { Self.point(at: $0, lineStarts: lineStarts) }
                )
            )
            let tokens = client.tokenProvider(with: text.predicateTextProvider)
            self.client = client
            styler = TextSystemStyler(textSystem: interface, tokenProvider: tokens)
            styler?.validate(.range(visibleRange))
        } catch {
            Log.rendering.error("Cannot highlight \(configuration.name, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func invalidate(_ set: IndexSet) {
        styler?.invalidate(.set(set))
        styler?.validate(.range(visibleRange))
    }

    @objc private func visibleTextChanged() {
        styler?.validate(.range(visibleRange))
    }

    /// The text in the viewport; before the first layout, a screenful from the top.
    var visibleRange: NSRange {
        let manager = textView.textContentManager
        guard let viewport = textView.textLayoutManager.textViewportLayoutController.viewportRange else {
            return NSRange(0..<min(text.utf16.count, 8_000))
        }
        let start = manager.offset(from: manager.documentRange.location, to: viewport.location)
        let end = manager.offset(from: manager.documentRange.location, to: viewport.endLocation)
        return NSRange(start..<end)
    }

    // MARK: - Lines

    static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A {
            starts.append(offset + 1)
        }
        return starts
    }

    /// The tree-sitter point of a UTF-16 offset: tree-sitter parses UTF-16, so columns are in bytes.
    static func point(at offset: Int, lineStarts: [Int]) -> Point? {
        guard offset >= 0 else { return nil }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return Point(row: low, column: (offset - lineStarts[low]) * 2)
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
