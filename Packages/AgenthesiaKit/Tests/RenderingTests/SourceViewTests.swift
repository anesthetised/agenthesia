import AppKit
import STTextView
import Testing

@testable import Rendering

@MainActor
@Suite struct SourceViewTests {
    /// The highlight color rendered at the first occurrence of `token`, waiting for background parsing.
    private func renderedColor(of token: String, in view: SourceView) async -> NSColor? {
        let offset = (view.text as NSString).range(of: token).location
        let manager = view.textView.textLayoutManager
        let content = view.textView.textContentManager
        guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        for _ in 0..<200 {
            var color: NSColor?
            manager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, range in
                if range.contains(location) { color = attributes[.foregroundColor] as? NSColor }
                return false
            }
            if let color { return color }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
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
        let manager = view.textView.textLayoutManager
        var colored = false
        manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attributes, _ in
            colored = colored || attributes[.foregroundColor] != nil
            return true
        }
        #expect(!colored)
    }

    @Test func replacedTextIsNotHighlightedLate() async {
        let view = SourceView()
        view.setText("let x = 1", language: .swift)
        view.setText("let x = 1", language: nil)
        // The grammar loads in the background; give it time to arrive for the first text.
        try? await Task.sleep(for: .milliseconds(300))
        let manager = view.textView.textLayoutManager
        var colored = false
        manager.enumerateRenderingAttributes(from: manager.documentRange.location, reverse: false) { _, attributes, _ in
            colored = colored || attributes[.foregroundColor] != nil
            return true
        }
        #expect(!colored)
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
        #expect(SourceView.point(at: 0, lineStarts: starts) == .init(row: 0, column: 0))
        #expect(SourceView.point(at: 2, lineStarts: starts) == .init(row: 0, column: 4))
        #expect(SourceView.point(at: 4, lineStarts: starts) == .init(row: 1, column: 2))
        #expect(SourceView.point(at: 6, lineStarts: starts) == .init(row: 2, column: 0))
        #expect(SourceView.point(at: 9, lineStarts: starts) == .init(row: 3, column: 4))
        #expect(SourceView.point(at: -1, lineStarts: starts) == nil)
        #expect(SourceView.line(at: 5, lineStarts: starts) == 1)
    }
}
