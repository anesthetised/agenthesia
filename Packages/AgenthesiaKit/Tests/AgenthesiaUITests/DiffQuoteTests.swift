import Rendering
import Testing

@testable import AgenthesiaUI

@Suite struct DiffQuoteTests {
    private let diff = UnifiedDiff.parse(
        UnifiedDiff.make(
            old: (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n",
            new: (1...30).map { $0 == 10 ? "ten" : "line \($0)" }.filter { $0 != "line 28" }.joined(separator: "\n")
                + "\n"
        )
    )

    private func lines(_ texts: String...) -> [DiffLine] {
        texts.compactMap { text in diff.first { $0.text == text && $0.kind != .hunk } }
    }

    @Test func quotesLinesWithinAHunk() {
        #expect(
            DiffQuote.make(path: "Sources/App.swift", lines: lines("line 9", "line 10", "ten", "line 11"))
                == """
                `Sources/App.swift:9-11`
                ```diff
                 line 9
                -line 10
                +ten
                 line 11
                ```
                """
        )
    }

    @Test func listsEachRangeAcrossHunks() {
        let quote = DiffQuote.make(path: "a.swift", lines: Array(diff))
        #expect(quote?.hasPrefix("`a.swift:7-13, 25-29`\n```diff\n line 7\n") == true)
        #expect(quote?.contains("@@") == false)
        #expect(quote?.contains("-line 28\n") == true)
    }

    @Test func namesRemovedLinesWithoutALineNumber() {
        #expect(
            DiffQuote.make(path: "a.swift", lines: lines("line 28"))
                == "`a.swift:28 (removed)`\n```diff\n-line 28\n```"
        )
        // A removal beside a kept line is part of its range.
        #expect(
            DiffQuote.make(path: "a.swift", lines: lines("line 27", "line 28"))?.hasPrefix("`a.swift:27`\n") == true
        )
    }

    @Test func quotesAWholeDeletedFile() {
        let deleted = UnifiedDiff.parse(UnifiedDiff.make(old: "a\nb\n", new: ""))
        #expect(DiffQuote.make(path: "old.txt", lines: deleted)?.hasPrefix("`old.txt:1 (removed)`") == true)
    }

    @Test func quotesANewFile() {
        let added = UnifiedDiff.parse(UnifiedDiff.make(old: nil, new: "a\nb\n"))
        #expect(DiffQuote.make(path: "new.txt", lines: added) == "`new.txt:1-2`\n```diff\n+a\n+b\n```")
    }

    @Test func ignoresHeadersAndEmptySelections() {
        #expect(DiffQuote.make(path: "a", lines: []) == nil)
        #expect(DiffQuote.make(path: "a", lines: [diff[0]]) == nil)
        #expect(DiffQuote.make(path: "a", lines: [diff[0]] + lines("line 9"))?.contains("@@") == false)
    }

    @Test func lengthensTheFenceAroundBackticks() {
        let added = UnifiedDiff.parse(UnifiedDiff.make(old: nil, new: "```swift\n"))
        #expect(DiffQuote.make(path: "a.md", lines: added) == "`a.md:1`\n````diff\n+```swift\n````")
    }

    @Test func marksQuotesFromAnEarlierVersion() {
        #expect(
            DiffQuote.make(path: "a", lines: lines("line 9"), stale: true)?.hasSuffix(
                "```\n(from an earlier version; lines may have moved)"
            ) == true
        )
    }
}
