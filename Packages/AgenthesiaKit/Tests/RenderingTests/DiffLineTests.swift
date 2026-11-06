import Testing

@testable import Rendering

@Suite struct DiffLineTests {
    private func numbered(_ range: ClosedRange<Int>, changing: [Int: String] = [:]) -> String {
        range.map { changing[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    @Test func numbersContextAddedAndRemovedLines() {
        let lines = UnifiedDiff.parse(UnifiedDiff.make(old: "a\nb\nc\n", new: "a\nB\nB2\nc\n"))
        #expect(
            lines == [
                DiffLine(kind: .hunk, text: "@@ -1,3 +1,4 @@"),
                DiffLine(kind: .context, oldNumber: 1, newNumber: 1, newPosition: 1, text: "a"),
                DiffLine(kind: .removed, oldNumber: 2, newPosition: 2, text: "b"),
                DiffLine(kind: .added, newNumber: 2, newPosition: 2, text: "B"),
                DiffLine(kind: .added, newNumber: 3, newPosition: 3, text: "B2"),
                DiffLine(kind: .context, oldNumber: 3, newNumber: 4, newPosition: 4, text: "c"),
            ]
        )
    }

    @Test func restartsNumbersAtEachHunk() {
        let diff = UnifiedDiff.make(old: numbered(1...30), new: numbered(1...30, changing: [2: "a", 28: "b"]))
        let lines = UnifiedDiff.parse(diff)
        #expect(lines.filter { $0.kind == .hunk }.count == 2)
        #expect(lines.first { $0.text == "a" }?.newNumber == 2)
        #expect(lines.first { $0.text == "line 2" }?.oldNumber == 2)
        #expect(lines.first { $0.text == "b" }?.newNumber == 28)
        #expect(lines.first { $0.text == "line 28" }?.oldNumber == 28)
        #expect(lines.last?.oldNumber == 30 && lines.last?.newNumber == 30)
    }

    @Test func keepsOneEntryPerTextLine() {
        let diff = UnifiedDiff.make(old: numbered(1...30), new: numbered(1...30, changing: [2: "a", 28: "b"]))
        #expect(UnifiedDiff.parse(diff).count == diff.components(separatedBy: "\n").count)
    }

    @Test func numbersANewFile() {
        let lines = UnifiedDiff.parse(UnifiedDiff.make(old: nil, new: "one\ntwo\n"))
        #expect(lines.map(\.kind) == [.hunk, .added, .added])
        #expect(lines.compactMap(\.newNumber) == [1, 2])
        #expect(lines.compactMap(\.oldNumber).isEmpty)
    }

    @Test func numbersADeletedFile() {
        let lines = UnifiedDiff.parse(UnifiedDiff.make(old: "one\ntwo\n", new: ""))
        #expect(lines.map(\.kind) == [.hunk, .removed, .removed])
        #expect(lines.compactMap(\.oldNumber) == [1, 2])
        #expect(lines.compactMap(\.newNumber).isEmpty)
        #expect(lines.map(\.newPosition) == [0, 1, 1])
    }

    @Test func treatsAFileWithoutFinalNewlineAsWholeLines() {
        let lines = UnifiedDiff.parse(UnifiedDiff.make(old: "a\nb", new: "a\nc"))
        #expect(lines.map(\.text) == ["@@ -1,2 +1,2 @@", "a", "b", "c"])
        #expect(lines.map(\.newNumber) == [nil, 1, nil, 2])
    }

    @Test func skipsTheNoNewlineMarker() {
        let lines = UnifiedDiff.parse("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file")
        #expect(lines.map(\.kind) == [.hunk, .removed, .added])
        #expect(lines.map(\.text) == ["@@ -1 +1 @@", "a", "b"])
        #expect(lines.last?.newNumber == 1)
    }

    @Test func readsEmptyAndBlankLines() {
        #expect(UnifiedDiff.parse("").isEmpty)
        let lines = UnifiedDiff.parse(UnifiedDiff.make(old: "a\n\nb\n", new: "a\n\nc\n"))
        #expect(lines.map(\.text) == ["@@ -1,3 +1,3 @@", "a", "", "b", "c"])
        #expect(lines[2].newNumber == 2)
    }

    @Test func keepsTextThatLooksLikeAHeader() {
        let lines = UnifiedDiff.parse(UnifiedDiff.make(old: nil, new: "@@ -1 +1 @@\n"))
        #expect(lines.map(\.kind) == [.hunk, .added])
        #expect(lines[1].text == "@@ -1 +1 @@")
    }
}
