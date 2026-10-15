import AppKit
import Testing

@testable import Rendering

@Suite struct UnifiedDiffTests {
    let theme = Theme.standard

    private func numbered(_ range: ClosedRange<Int>, changing: [Int: String] = [:]) -> String {
        range.map { changing[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    @Test func emptyWhenNothingChanged() {
        #expect(UnifiedDiff.make(old: "a\nb\n", new: "a\nb\n") == "")
        #expect(UnifiedDiff.make(old: nil, new: "") == "")
    }

    @Test func newFileAndDeletedContent() {
        #expect(UnifiedDiff.make(old: nil, new: "one\ntwo") == "@@ -0,0 +1,2 @@\n+one\n+two")
        #expect(UnifiedDiff.make(old: "one\ntwo\n", new: "") == "@@ -1,2 +0,0 @@\n-one\n-two")
    }

    @Test func keepsContextAroundChanges() {
        let diff = UnifiedDiff.make(old: numbered(1...10), new: numbered(1...10, changing: [5: "five"]))
        #expect(
            diff == """
                @@ -2,7 +2,7 @@
                 line 2
                 line 3
                 line 4
                -line 5
                +five
                 line 6
                 line 7
                 line 8
                """
        )
    }

    @Test func mergesNearbyChangesAndSplitsDistantOnes() {
        let near = UnifiedDiff.make(old: numbered(1...20), new: numbered(1...20, changing: [5: "a", 11: "b"]))
        #expect(near.hasPrefix("@@ -2,13 +2,13 @@"))
        #expect(near.components(separatedBy: "@@ -").count == 2)
        let far = UnifiedDiff.make(old: numbered(1...20), new: numbered(1...20, changing: [2: "a", 18: "b"]))
        #expect(
            far.components(separatedBy: "\n").filter { $0.hasPrefix("@@") } == ["@@ -1,5 +1,5 @@", "@@ -15,6 +15,6 @@"]
        )
    }

    @Test func showsLargeRewritesAsAWholeReplacement() {
        let count = UnifiedDiff.editLimit / 2 + 1
        let old = (0..<count).map { "old \($0)" }
        let new = (0..<count).map { "new \($0)" }
        let diff = UnifiedDiff.make(
            old: (["kept"] + old).joined(separator: "\n"),
            new: (["kept"] + new).joined(separator: "\n")
        )
        let lines = diff.components(separatedBy: "\n")
        #expect(lines.first == "@@ -1,\(count + 1) +1,\(count + 1) @@")
        let removed: [String] = old.map { "-" + $0 }
        let added: [String] = new.map { "+" + $0 }
        #expect(Array(lines.dropFirst(2)) == removed + added)
    }

    @Test func boundsEditsByUnmatchedLines() {
        #expect(UnifiedDiff.minimumEdits(from: ["a", "b", "a"], to: ["a", "c", "b"]) == 2)
        #expect(UnifiedDiff.minimumEdits(from: ["a", "b"], to: ["b", "a"]) == 0)
    }

    @Test func handlesInsertionsAndCRLF() {
        #expect(UnifiedDiff.make(old: "a\r\nc\r\n", new: "a\r\nb\r\nc\r\n") == "@@ -1,2 +1,3 @@\n a\n+b\n c")
    }

    private func background(of token: String, after offset: Int = 0, in text: NSAttributedString) -> NSColor? {
        let string = text.string as NSString
        let range = string.range(of: token, range: NSRange(location: offset, length: string.length - offset))
        return text.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    @Test func highlightsLinesAndChangedWords() {
        let diff = "@@ -1,2 +1,2 @@\n same\n-let value = old\n+let value = new"
        let text = UnifiedDiff.highlight(diff, theme: theme)
        #expect(text.string == diff)
        #expect(background(of: "same", in: text) == theme.codeBackgroundColor)
        #expect(background(of: "let", in: text) == theme.diffRemovedColor)
        #expect(background(of: "old", in: text) == theme.diffRemovedWordColor)
        let added = (diff as NSString).range(of: "+let").location
        #expect(background(of: "let", after: added, in: text) == theme.diffAddedColor)
        #expect(background(of: "new", in: text) == theme.diffAddedWordColor)
        let header = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(header == theme.secondaryTextColor)
    }

    @Test func skipsWordsForUnpairedAndOversizedRuns() {
        let lone = UnifiedDiff.highlight("+only added", theme: theme)
        #expect(background(of: "only", in: lone) == theme.diffAddedColor)
        let limit = UnifiedDiff.wordDiffLineLimit
        let big = (Array(repeating: "-old", count: limit) + ["+new"]).joined(separator: "\n")
        #expect(background(of: "new", in: UnifiedDiff.highlight(big, theme: theme)) == theme.diffAddedColor)
    }

    @Test func markdownRendersDiffBlocks() {
        let text = MarkdownRenderer().render("```diff\n-a\n+b\n```")
        #expect(text.string == "-a\n+b")
        #expect(background(of: "b", in: text) == theme.diffAddedWordColor)
    }
}
