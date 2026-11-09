import ACP
import Testing

@testable import AgenthesiaUI

@MainActor @Suite struct ToolGroupsTests {
    /// `t` is a tool call, `h` a thought, `x` anything else.
    private func fold(_ pattern: String, expanded: Set<Int> = []) -> [TranscriptRow] {
        let items = Array(pattern)
        return TranscriptRow.fold(
            count: items.count,
            isToolCall: { items[$0] == "t" },
            isThought: { items[$0] == "h" },
            isExpanded: expanded.contains
        )
    }

    @Test func thoughtsFoldIntoOneRowEvenAlone() {
        #expect(fold("h") == [.thoughts(first: 0)])
        #expect(fold("hhh") == [.thoughts(first: 0)])
        #expect(fold("xhhx") == [.item(0), .thoughts(first: 1), .item(3)])
        // Thoughts end a group of tool calls, and tool calls end a run of thoughts.
        #expect(fold("htth") == [.thoughts(first: 0), .group(first: 1), .thoughts(first: 3)])
        #expect(fold("tht") == [.item(0), .thoughts(first: 1), .item(2)])
        // A thought row holds its text; expanding it adds no rows.
        #expect(fold("hh", expanded: [0]) == [.thoughts(first: 0)])
        let rows = fold("xhhtt", expanded: [3])
        #expect((0..<6).map { TranscriptRow.row(showing: $0, in: rows) } == [0, 1, 1, 3, 4, 4])
    }

    @Test func consecutiveToolCallsFoldAndOneStaysACard() {
        #expect(fold("") == [])
        #expect(fold("t") == [.item(0)])
        #expect(fold("xtx") == [.item(0), .item(1), .item(2)])
        #expect(fold("tt") == [.group(first: 0)])
        #expect(fold("xtttx") == [.item(0), .group(first: 1), .item(4)])
        // Another item, such as a permission request, ends a group; what is left on either side may be one call.
        #expect(fold("ttxt") == [.group(first: 0), .item(2), .item(3)])
        #expect(fold("txtt") == [.item(0), .item(1), .group(first: 2)])
        #expect(fold("ttxtt") == [.group(first: 0), .item(2), .group(first: 3)])
    }

    @Test func anExpandedGroupKeepsItsSummaryAboveItsCards() {
        #expect(fold("xttx", expanded: [1]) == [.item(0), .group(first: 1), .item(1), .item(2), .item(3)])
        // Only the first item keys a group.
        #expect(fold("xttx", expanded: [2]) == [.item(0), .group(first: 1), .item(3)])
    }

    private func calls(_ kinds: ACP.ToolKind?...) -> [ACP.ToolCall] {
        kinds.enumerated().map { .init(toolCallId: "\($0)", title: "Title", kind: $1, status: .completed) }
    }

    private func summary(_ kinds: ACP.ToolKind?...) -> String {
        ToolGroupSummary(
            kinds.enumerated().map { .init(toolCallId: "\($0)", title: "Title", kind: $1, status: .completed) },
            running: false
        ).text
    }

    @Test func summaryNamesEachKindInSingularAndPlural() {
        #expect(summary(.execute) == "Ran 1 command")
        #expect(summary(.execute, .execute) == "Ran 2 commands")
        #expect(summary(.read) == "Read 1 file")
        #expect(summary(.read, .read) == "Read 2 files")
        // Calls, not files: two edits may change the same file.
        #expect(summary(.edit) == "Made 1 edit")
        #expect(summary(.edit, .edit) == "Made 2 edits")
        #expect(summary(.delete) == "Deleted 1 file")
        #expect(summary(.delete, .delete) == "Deleted 2 files")
        #expect(summary(.move) == "Moved 1 file")
        #expect(summary(.move, .move) == "Moved 2 files")
        #expect(summary(.search) == "Searched 1 time")
        #expect(summary(.search, .search) == "Searched 2 times")
        #expect(summary(.fetch) == "Fetched 1 URL")
        #expect(summary(.fetch, .fetch) == "Fetched 2 URLs")
        #expect(summary(.think, .think) == "Thought")
        #expect(summary(.other) == "Used 1 tool")
        #expect(summary(.other, .switchMode, .unknown("deploy"), nil) == "Used 4 tools")
    }

    @Test func summaryJoinsKindsInAFixedOrderAndCapitalizesOnlyTheFirst() {
        #expect(summary(.edit, .execute, .edit, .execute, .execute) == "Ran 3 commands, made 2 edits")
        #expect(
            summary(.other, .think, .fetch, .search, .move, .delete, .edit, .read, .execute)
                == "Ran 1 command, read 1 file, made 1 edit, deleted 1 file, moved 1 file, "
                + "searched 1 time, fetched 1 URL, thought, used 1 tool"
        )
    }

    @Test func failuresAreCountedAndHeaderShowsThemInTheFailureTone() {
        var group = calls(.execute, .execute, .read)
        let quiet = ToolGroupSummary(group, running: false).header(expanded: false)
        #expect(quiet.status == "")
        #expect(quiet.tone == .neutral)
        #expect(quiet.expandable)
        #expect(!quiet.expanded)
        group[0].status = .failed
        group[2].status = .failed
        let summary = ToolGroupSummary(group, running: false)
        #expect(summary.failed == 2)
        #expect(summary.text == "Ran 2 commands, read 1 file")
        let header = summary.header(expanded: true)
        #expect(header.kind == "Ran 2 commands, read 1 file")
        #expect(header.status == "· 2 failed")
        #expect(header.tone == .failure)
        #expect(header.expanded)
    }

    @Test func aRunningLastCallReplacesTheCountsWithItsTitle() {
        var group = calls(.read, .execute)
        group[0].status = .failed
        group[1].title = "just test"
        for status in [ACP.ToolCallStatus.inProgress, .pending] {
            group[1].status = status
            let summary = ToolGroupSummary(group, running: true)
            #expect(summary.text == "just test…")
            #expect(summary.failed == 1)
            // A session that ended left the call unfinished; it does not run.
            #expect(ToolGroupSummary(group, running: false).text == "Ran 1 command, read 1 file")
        }
        group[1].status = .completed
        #expect(ToolGroupSummary(group, running: true).text == "Ran 1 command, read 1 file")
        // Only the last call counts.
        group[0].status = .inProgress
        #expect(ToolGroupSummary(group, running: true).text == "Ran 1 command, read 1 file")
    }

    @Test func aRunningTitleIsOneLineWithoutMarkdownAndFallsBackToCounts() {
        var group = calls(.read, .execute)
        group[1].status = .inProgress
        group[1].title = "`swift test`\n  --parallel"
        #expect(ToolGroupSummary(group, running: true).text == "swift test…")
        for empty in ["", "\n", "``"] {
            group[1].title = empty
            #expect(ToolGroupSummary(group, running: true).text == "Ran 1 command, read 1 file")
        }
    }
}
