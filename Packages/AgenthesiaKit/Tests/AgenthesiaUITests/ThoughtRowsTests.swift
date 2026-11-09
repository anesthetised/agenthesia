import Testing

@testable import AgenthesiaUI

@MainActor @Suite struct ThoughtRowsTests {
    private func thinking(_ text: String, expanded: Bool = false) -> String {
        ThoughtSummary.header(latest: text, thinking: true, duration: 3, expanded: expanded).kind
    }

    @Test func aThinkingHeaderShowsTheLastLineWithoutMarks() {
        #expect(thinking("First\n\n**Checking** the `tests`  \n\n") == "Thinking… Checking the tests")
        #expect(thinking("One line") == "Thinking… One line")
        #expect(thinking("") == "Thinking…" && thinking(" \n ") == "Thinking…" && thinking("``") == "Thinking…")
        // Expanded, the text below the header says it.
        #expect(thinking("One line", expanded: true) == "Thinking…")
    }

    @Test func aFinishedHeaderSaysHowLongAndDisclosesTheText() {
        let header = ThoughtSummary.header(latest: "x", thinking: false, duration: 72.9, expanded: false)
        #expect(header.kind == "Thought for 1m 12s")
        #expect(header.expandable && !header.expanded && header.symbol == "brain" && header.status.isEmpty)
        let expanded = ThoughtSummary.header(latest: "", thinking: false, duration: 12, expanded: true)
        #expect(expanded.kind == "Thought for 12s" && expanded.expanded)
    }
}
