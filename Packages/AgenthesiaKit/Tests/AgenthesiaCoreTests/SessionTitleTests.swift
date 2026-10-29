import Testing

@testable import AgenthesiaCore

struct SessionTitleTests {
    @Test func usesTheFirstNonBlankLineTrimmed() {
        #expect(SessionTitle.fromPrompt("Fix the build") == "Fix the build")
        #expect(SessionTitle.fromPrompt("\n \t\n  Fix the build  \nand the tests") == "Fix the build")
        #expect(SessionTitle.fromPrompt("first\r\nsecond") == "first")
    }

    @Test func blankTextHasNoTitle() {
        for text in ["", "   ", "\n\n", " \t \n \r\n "] { #expect(SessionTitle.fromPrompt(text) == nil) }
    }

    @Test func keepsALineOfExactlyTheLimit() {
        let line = String(repeating: "a", count: 79) + "b"
        #expect(SessionTitle.fromPrompt(line) == line)
        let words = String(repeating: "word ", count: 15) + "word"  // 79 characters
        #expect(SessionTitle.fromPrompt(words + "s") == words + "s")  // 80
    }

    @Test func cutsLongLinesAtTheLastWordBoundary() throws {
        let line = String(repeating: "word ", count: 30)
        let title = try #require(SessionTitle.fromPrompt(line))
        #expect(title == String(repeating: "word ", count: 15) + "word…")
        #expect(title.count <= SessionTitle.maxLength)
        // The cut falls right after a whole word: nothing is dropped.
        let exact = String(repeating: "x", count: 78) + " " + String(repeating: "y", count: 10)
        #expect(SessionTitle.fromPrompt(exact) == String(repeating: "x", count: 78) + "…")
        let partial = String(repeating: "x", count: 70) + " yy " + String(repeating: "z", count: 20)
        #expect(SessionTitle.fromPrompt(partial) == String(repeating: "x", count: 70) + " yy…")
    }

    @Test func cutsASingleLongWordAt79CharactersPlusAnEllipsis() throws {
        let title = try #require(SessionTitle.fromPrompt(String(repeating: "w", count: 200)))
        #expect(title == String(repeating: "w", count: 79) + "…" && title.count == 80)
    }

    @Test func countsEmojiAndCombiningMarksAsCharacters() throws {
        let emoji = String(repeating: "🌍", count: 100)
        #expect(SessionTitle.fromPrompt(emoji) == String(repeating: "🌍", count: 79) + "…")
        let combining = String(repeating: "e\u{301}", count: 100)
        #expect(SessionTitle.fromPrompt(combining) == String(repeating: "e\u{301}", count: 79) + "…")
        #expect(SessionTitle.fromPrompt("🙂 " + String(repeating: "ы", count: 90)) == "🙂…")
    }
}
