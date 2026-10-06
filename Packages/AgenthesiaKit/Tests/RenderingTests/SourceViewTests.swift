import AppKit
import STTextView
import Testing

@testable import Rendering

@MainActor
@Suite struct SourceViewTests {
    /// The text color at the first occurrence of `token`, waiting for background highlighting to replace the plain
    /// text color.
    private func renderedColor(of token: String, in view: SourceView) async -> NSColor? {
        let offset = (view.text as NSString).range(of: token).location
        for _ in 0..<200 {
            if let color = color(at: offset, in: view), color != view.theme.textColor { return color }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return color(at: offset, in: view)
    }

    private func color(at offset: Int, in view: SourceView) -> NSColor? {
        view.textView.textContentStorage.textStorage?.attribute(.foregroundColor, at: offset, effectiveRange: nil)
            as? NSColor
    }

    /// Whether any text has a color other than the plain text color.
    private func isColored(_ view: SourceView) -> Bool {
        guard let storage = view.textView.textContentStorage.textStorage else { return false }
        var colored = false
        storage.enumerateAttribute(.foregroundColor, in: NSRange(0..<storage.length)) { value, _, _ in
            colored = colored || (value as? NSColor).map { $0 != view.theme.textColor } ?? false
        }
        return colored
    }

    @Test func loadsTextAndCountsLines() {
        let view = SourceView()
        view.setText("one\ntwo\nthree", language: nil)
        #expect(view.textView.text == "one\ntwo\nthree")
        #expect(view.lineCount == 3)
        #expect(view.textView.isEditable == false)
        #expect(view.showsLineNumbers)
        #expect(!view.textView.showsLineNumbers)
        #expect(view.textView.font == Theme.standard.codeFont)

        view.setText("", language: nil)
        #expect(view.lineCount == 1)
        view.setText("trailing\n", language: nil)
        #expect(view.lineCount == 2)
    }

    @Test func highlightsVisibleText() async {
        let view = SourceView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.setText("let x = 1 // note\n", language: .swift)
        #expect(await renderedColor(of: "let", in: view) == Theme.standard.color(forCapture: "keyword"))
        #expect(await renderedColor(of: "// note", in: view) == Theme.standard.color(forCapture: "comment"))
    }

    @Test func highlightsALargeFile() async {
        let line = "func f() { return \"text\" }\n"
        let view = SourceView()
        view.setText(String(repeating: line, count: 10_000), language: .swift)
        #expect(view.lineCount == 10_001)
        #expect(await renderedColor(of: "func", in: view) == Theme.standard.color(forCapture: "keyword"))
    }

    @Test func unknownLanguageIsNotHighlighted() async {
        let view = SourceView()
        view.setText("let x = 1", language: nil)
        #expect(view.language == nil)
        #expect(!isColored(view))
    }

    @Test func replacedTextIsNotHighlightedLate() async {
        let view = SourceView()
        view.setText("let x = 1", language: .swift)
        view.setText("let x = 1", language: nil)
        // The grammar loads in the background; give it time to arrive for the first text.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!isColored(view))
    }

    @Test func themeChangesTheFont() {
        let view = SourceView()
        view.setText("let x = 1", language: .swift)
        view.theme = Theme(fontSize: 20)
        #expect(view.textView.font == Theme(fontSize: 20).codeFont)
    }

    @Test func gutterNumbersTheVisibleLines() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = SourceView()
        window.contentView = view
        view.setText((1...10_000).map { "line \($0)" }.joined(separator: "\n"), language: nil)
        view.layoutSubtreeIfNeeded()

        let top = view.gutter.visibleLines()
        #expect(top.first?.number == 1)
        #expect(top.map(\.number) == Array(1...top.count))
        #expect(view.gutter.frame.width > 0)

        let clip = view.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 50_000))
        view.scrollView.reflectScrolledClipView(clip)
        view.layoutSubtreeIfNeeded()
        let deep = try #require(view.gutter.visibleLines().first)
        // The number matches the text of the line at the top.
        let offset = (view.text as NSString).range(of: "line \(deep.number)\n").location
        #expect(SourceView.line(at: offset, lineStarts: view.lineStarts) + 1 == deep.number)
        #expect(deep.number > 1_000)
        #expect(abs(deep.y) < 40)

        view.showsLineNumbers = false
        #expect(view.gutter.isHidden)
    }

    @Test func lineStartsAndPoints() {
        let text = "ab\nçd\n\nlast"
        let starts = SourceView.lineStarts(of: text)
        #expect(starts == [0, 3, 6, 7])
        #expect(SourceView.line(at: 5, lineStarts: starts) == 1)
    }
}
