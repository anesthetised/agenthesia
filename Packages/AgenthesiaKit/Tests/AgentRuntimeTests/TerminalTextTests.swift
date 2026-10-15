import AgentRuntime
import Foundation
import Testing

@Suite struct TerminalTextTests {
    private func text(_ raw: String, limit: Int = 1_048_576, truncated: Bool = false) -> TerminalText.Result {
        TerminalText.make(from: TerminalOutput(bytes: Data(raw.utf8), truncated: truncated), byteLimit: limit)
    }

    @Test func removesColorAndCursorSequences() {
        #expect(text("\u{1B}[1;31mred\u{1B}[0m \u{1B}[2K\u{1B}[10;5Hdone").text == "red done")
        #expect(text("\u{1B}[?25lhidden cursor\u{1B}[?25h").text == "hidden cursor")
    }

    @Test func removesStringAndShortSequences() {
        #expect(text("a\u{1B}]0;title\u{07}b\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\").text == "ablink")
        #expect(text("a\u{1B}Pdata\u{1B}\\b\u{1B}_apc\u{1B}\\c").text == "abc")
        #expect(text("a\u{1B}(Bb\u{1B}=c\u{1B}7d").text == "abcd")
    }

    @Test func withholdsIncompleteTrailingSequences() {
        #expect(text("a\u{1B}").text == "a")
        #expect(text("a\u{1B}[31").text == "a")
        #expect(text("a\u{1B}]0;ti").text == "a")
        #expect(text("a\u{1B}(").text == "a")
    }

    @Test func normalizesLineEndingsAndCarriageReturns() {
        #expect(text("one\r\ntwo\r\n").text == "one\ntwo\n")
        #expect(text("10%\r50%\r100%\r\nok").text == "100%\nok")
        #expect(text("kept\r").text == "kept")
        #expect(text("\r\n\r\n").text == "\n\n")
    }

    @Test func dropsOtherControlCharactersButKeepsTabs() {
        #expect(text("a\u{07}b\u{08}c\u{7F}\td\u{00}").text == "abc\td")
    }

    @Test func truncatesFromTheStartAtACharacterBoundary() {
        #expect(text("abcdef", limit: 3) == .init(text: "def", truncated: true))
        #expect(text("abc", limit: 3) == .init(text: "abc", truncated: false))
        #expect(text("✓✓✓", limit: 7) == .init(text: "✓✓", truncated: true))
        #expect(text("abc", limit: 0) == .init(text: "", truncated: true))
    }

    @Test func limitCountsTextWithoutEscapes() {
        #expect(text("\u{1B}[31mabc\u{1B}[0m", limit: 3) == .init(text: "abc", truncated: false))
    }

    @Test func keepsTheRawTruncationFlagAndDropsACutCharacter() {
        var bytes = Data("✓abc".utf8)
        bytes.removeFirst()
        let result = TerminalText.make(from: TerminalOutput(bytes: bytes, truncated: true), byteLimit: 100)
        #expect(result == .init(text: "abc", truncated: true))
        #expect(text("abc", truncated: true).truncated)
    }

    @Test func withholdsAnIncompleteTrailingCharacter() {
        var bytes = Data("ab".utf8)
        bytes.append(contentsOf: [0xE2, 0x9C])
        #expect(TerminalText.make(from: TerminalOutput(bytes: bytes), byteLimit: 100).text == "ab")
        #expect(TerminalText.make(from: TerminalOutput(bytes: Data()), byteLimit: 100).text == "")
    }
}
