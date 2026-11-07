import AppKit
import Rendering
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct ReviewDiffTests {
    private func host(height: CGFloat = 300) -> (DiffTextView, NSWindow) {
        _ = NSApplication.shared
        let scroll = DiffTextView.scrollable()
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 480, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        guard let textView = scroll.documentView as? DiffTextView else {
            Issue.record("no diff text view")
            return (DiffTextView(), window)
        }
        return (textView, window)
    }

    private func show(_ old: String?, _ new: String, path: String = "file", in textView: DiffTextView) async {
        textView.show(await RenderedDiff.make(SessionReview.Document(path: path, old: old, new: new)))
        textView.enclosingScrollView?.layoutSubtreeIfNeeded()
    }

    @Test func showsEachLineWithItsOldAndNewNumber() async throws {
        let (textView, window) = host()
        defer { window.close() }
        await show("a\nb\nc\n", "a\nB\nc\nd\n", in: textView)
        #expect(textView.string == "@@ -1,3 +1,4 @@\n a\n-b\n+B\n c\n+d")
        #expect(textView.lines.map(\.kind) == [.hunk, .context, .removed, .added, .context, .added])
        #expect(textView.lineStarts == [0, 16, 19, 22, 25, 28])
        #expect(!textView.isEditable && textView.isSelectable)
        let gutter = try #require(textView.enclosingScrollView?.verticalRulerView as? DiffGutter)
        let numbers = gutter.visibleNumbers()
        #expect(numbers.map(\.old) == [1, 2, nil, 3, nil])
        #expect(numbers.map(\.new) == [1, nil, 2, 3, 4])
        #expect(zip(numbers, numbers.dropFirst()).allSatisfy { $0.y < $1.y })
        // Both columns fit the gutter.
        #expect(gutter.ruleThickness > 20)
    }

    @Test func aNewDiffKeepsTheTopLineAndEndsTheSelection() async throws {
        let (textView, window) = host()
        defer { window.close() }
        let old = (1...300).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let changed = old.replacingOccurrences(of: "line 150\n", with: "line 150 changed\n")
        // Every tenth line changed, so the diff has many hunks.
        let spread = (1...300).map { $0 % 10 == 0 ? "line \($0) edited" : "line \($0)" }.joined(separator: "\n") + "\n"
        await show(old, spread, in: textView)
        let middle = try #require(textView.lines.firstIndex { $0.newNumber == 150 })
        textView.scroll(toLine: middle)
        #expect(textView.topLine == middle)
        textView.setSelectedRange(NSRange(location: textView.lineStarts[middle], length: 4))
        // The same document again changes nothing.
        await show(old, spread, in: textView)
        #expect(textView.selectedRange().length == 4 && textView.topLine == middle)
        let inserted = "line 0\n" + spread
        await show(old, inserted, in: textView)
        #expect(textView.selectedRange().length == 0)
        let top = try #require(textView.topLine)
        // Line 150 of the old text is line 151 now; the top shows the nearest line at or after where it stood.
        #expect(textView.lines[top].newPosition >= 150 && textView.lines[top].newPosition <= 152)
        await show(old, changed, in: textView)
        #expect(textView.topLine != nil)
    }

    @Test func escapeClosesOnlyWithoutASelection() async {
        let (textView, window) = host()
        defer { window.close() }
        await show(nil, "one\ntwo\n", in: textView)
        var closed = 0
        textView.onEscape = { closed += 1 }
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        textView.cancelOperation(nil)
        #expect(closed == 0)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.cancelOperation(nil)
        #expect(closed == 1)
    }

    /// ADR-0041 asks for a look at large diffs: a 5,000-line file rewritten (10,000 diff lines) and a new 5,000-line
    /// file, from the document to the first drawn frame. The bound is loose for loaded CI machines; the times print.
    @Test(arguments: [true, false]) func aLargeDiffShowsQuickly(rewritten: Bool) async {
        let (textView, window) = host(height: 700)
        defer { window.close() }
        let old = (1...5_000).map { "let value\($0) = compute(\($0), scale: 2)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "scale: 2", with: "scale: 3")
        let document = SessionReview.Document(path: "large", old: rewritten ? old : nil, new: new)
        let clock = ContinuousClock()
        let start = clock.now
        let diff = await RenderedDiff.make(document)
        let rendered = clock.now
        textView.show(diff)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        let shown = clock.now
        textView.scroll(toLine: diff.lines.count - 1)
        window.contentView?.displayIfNeeded()
        let end = clock.now
        print(
            "Large review diff (\(diff.lines.count) lines): render \(rendered - start), show and draw \(shown - rendered),"
                + " scroll to the end \(end - shown)"
        )
        #expect(diff.lines.count == (rewritten ? 10_001 : 5_001))
        #expect(end - start < .seconds(10))
    }
}
