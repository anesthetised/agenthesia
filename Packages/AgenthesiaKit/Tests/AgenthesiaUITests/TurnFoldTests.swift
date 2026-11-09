import ACP
import AppKit
import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// A finished turn's work folds under `Worked for …` (#341).
@MainActor @Suite struct TurnFoldTests {
    /// `p` starts a turn, `P` is another prompt of the same turn, `a` an agent message, `q` a question, `t` a tool
    /// call, `h` a thought, `w` other work and `o` anything else. Turns are numbered from 0 in order.
    private func fold(
        _ pattern: String,
        running: Set<Int> = [],
        expanded: Set<Int> = []
    ) -> (rows: [TranscriptRow], folds: [TurnFold]) {
        let items = Array(pattern)
        var turns: [UUID] = []
        var parts: [TranscriptRow.TurnPart] = []
        for item in items {
            switch item {
            case "p":
                turns.append(UUID())
                parts.append(.prompt(turns[turns.count - 1]))
            case "P": parts.append(.prompt(turns[turns.count - 1]))
            case "a": parts.append(.answer)
            case "q": parts.append(.question)
            case "o": parts.append(.other)
            default: parts.append(.work)
            }
        }
        let folds = TranscriptRow.turnFolds(
            count: items.count,
            part: { parts[$0] },
            finished: { turn in !running.contains { turns[$0] == turn } },
            isExpanded: { turn in expanded.contains { turns[$0] == turn } }
        )
        let rows = TranscriptRow.fold(
            count: items.count,
            isToolCall: { items[$0] == "t" },
            isThought: { items[$0] == "h" },
            isExpanded: { _ in false },
            turns: folds
        )
        return (rows, folds)
    }

    @Test func aFinishedTurnFoldsEverythingButItsAnswerAndQuestions() {
        #expect(fold("pwwa").rows == [.item(0), .turn(first: 1), .item(3)])
        #expect(fold("pwwa").folds.map(\.kept) == [[3]])
        // Questions stay outside the fold, in their place; the fold's row sits under the prompt.
        #expect(fold("pqwqa").rows == [.item(0), .turn(first: 1), .item(1), .item(3), .item(4)])
        // Only the last agent message is the answer; earlier ones and work after it fold.
        #expect(fold("pawatt").rows == [.item(0), .turn(first: 1), .item(3)])
        // Without an answer everything folds; another item ends the turn and stays.
        #expect(fold("pwwo").rows == [.item(0), .turn(first: 1), .item(3)])
        // Prompts sent together stay above the fold.
        #expect(fold("pPwa").rows == [.item(0), .item(1), .turn(first: 2), .item(3)])
        // Nothing to hide, nothing to fold.
        #expect(fold("pa").rows == [.item(0), .item(1)])
        #expect(fold("pqa").rows == [.item(0), .item(1), .item(2)])
        #expect(fold("wwpa").folds.isEmpty)
    }

    @Test func aRunningTurnNeverFoldsAndTheOthersDo() {
        #expect(
            fold("pwapwa", running: [1]).rows
                == [.item(0), .turn(first: 1), .item(2), .item(3), .item(4), .item(5)]
        )
        #expect(fold("pwapwa", running: [0, 1]).rows == (0..<6).map(TranscriptRow.item))
    }

    @Test func anExpandedTurnKeepsItsRowAboveItsRowsAsTheyFoldToday() {
        let rows = fold("ptthta", expanded: [0]).rows
        #expect(rows == [.item(0), .turn(first: 1), .group(first: 1), .thoughts(first: 3), .item(4), .item(5)])
        // A hidden item is shown by the turn's row, a kept one by its own.
        let collapsed = fold("pwwa").rows
        #expect((0..<4).map { TranscriptRow.row(showing: $0, in: collapsed) } == [0, 1, 1, 2])
    }

    // MARK: - The live transcript

    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func event(_ event: SessionEvent, at seconds: TimeInterval) throws -> NewEvent {
        NewEvent(kind: SessionEvent.kind, payload: try JSONEncoder().encode(event), timestamp: Self.start + seconds)
    }

    /// A turn of `prompt`: a thought, two calls, a permission record, an answered question, a note, a call and the
    /// answer, over 63 s; items 1 to 8 after the prompt at 0, unless the transcript holds more.
    @discardableResult
    private func turn(
        _ recorded: RecordedTranscript,
        prompt: String = "Fix the bug",
        answer: String = "Fixed the bug",
        at seconds: TimeInterval = 0,
        end: SessionEvent? = nil
    ) async throws -> UUID {
        let turn = UUID()
        let at = Self.start + seconds
        try await recorded.append(try event(.prompt(id: turn, content: [.init(text: prompt)]), at: seconds))
        try await recorded.apply(
            .agentThoughtChunk(.init(content: .init(text: "Look at the Needle"), messageId: .init("h"))),
            at: at + 1
        )
        for id in ["a", "b"] {
            try await recorded.apply(.toolCall(.init(toolCallId: .init(id), title: "Call \(id)", status: .completed)))
        }
        let permission = UUID()
        try await recorded.append(
            try SessionEvent.permissionRequested(id: permission, toolCall: .init(toolCallId: "p"), options: [])
                .storedEvent()
        )
        try await recorded.append(try SessionEvent.permissionResolved(id: permission, outcome: .cancelled).storedEvent())
        let input = UUID()
        let schema = ACP.ElicitationSchema(properties: ["q_0": .boolean(.init(title: "Proceed"))])
        try await recorded.append(
            try SessionEvent.inputRequested(
                id: input,
                request: .init(message: "Questions", mode: .form(schema), scope: .session("s", toolCallId: nil))
            ).storedEvent()
        )
        try await recorded.append(
            try SessionEvent.inputResolved(id: input, response: .init(action: .accept(["q_0": true]))).storedEvent()
        )
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: "Let me check"))))
        try await recorded.apply(.toolCall(.init(toolCallId: "c", title: "Call c", status: .completed)))
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: answer))))
        if let end {
            try await recorded.append(try event(end, at: seconds + 63))
        } else {
            try await recorded.append(try event(.finished(id: turn, reason: .endTurn), at: seconds + 63))
        }
        return turn
    }

    private func source(_ recorded: RecordedTranscript, running: Bool = false) -> LiveTranscriptSource {
        let source = LiveTranscriptSource()
        source.running = running
        source.state = recorded.state
        source.revision += 1
        return source
    }

    private static let folded: [TranscriptRow] = [.item(0), .turn(first: 1), .item(5), .item(8)]

    @Test func aFinishedTurnIsOneRowThatSaysHowLongItWorkedAndAboveItsAnswer() async throws {
        let recorded = try await RecordedTranscript()
        try await turn(recorded)
        let source = source(recorded)
        #expect(source.rows == Self.folded)
        let row = source.message(at: 1)
        #expect(row.kind == .turn && row.tool?.kind == "Worked for 1m 3s" && row.tool?.expanded == false)
        #expect(row.markdown.isEmpty && row.copyText == nil && !source.isStreaming(at: 1))
        #expect(source.message(at: 2).kind == .question && source.message(at: 3).markdown == "Fixed the bug")

        // Expanded, the turn shows its rows as before, below its own.
        source.toggleExpansion(at: 1)
        #expect(
            source.rows == [
                .item(0), .turn(first: 1), .thoughts(first: 1), .group(first: 2), .item(4), .item(5), .item(6),
                .item(7), .item(8),
            ]
        )
        #expect(source.message(at: 1).tool?.expanded == true)
        source.toggleExpansion(at: 1)
        #expect(source.rows == Self.folded)
    }

    @Test func nothingFoldsWhileTheTurnRunsAndAStoppedFailedOrSteeredTurnNeverDoes() async throws {
        let recorded = try await RecordedTranscript()
        let running = UUID()
        try await recorded.append(try event(.prompt(id: running, content: [.init(text: "Go")]), at: 0))
        try await recorded.apply(.toolCall(.init(toolCallId: "a", title: "Call a", status: .completed)))
        try await recorded.apply(.agentMessageChunk(.init(content: .init(text: "Done"))))
        #expect(source(recorded, running: true).rows == [.item(0), .item(1), .item(2)])

        let stopped = try await RecordedTranscript()
        let id = UUID()
        try await stopped.append(try event(.prompt(id: id, content: [.init(text: "Go")]), at: 0))
        try await stopped.append(try event(.stopRequested(id: id), at: 1))
        try await stopped.apply(.toolCall(.init(toolCallId: "a", title: "Call a", status: .completed)))
        try await stopped.append(try event(.finished(id: id, reason: .cancelled), at: 2))
        #expect(source(stopped).rows == [.item(0), .item(1), .item(2)])
        #expect(source(stopped).message(at: 2).kind == .interruption)

        let failed = try await RecordedTranscript()
        let turnID = try await turn(failed, end: .failed(id: UUID(), message: "Overloaded"))
        try await failed.append(try event(.failed(id: turnID, message: "Overloaded"), at: 70))
        #expect(!source(failed).rows.contains { if case .turn = $0 { true } else { false } })
        #expect(source(failed).message(at: source(failed).rows.count - 1).kind == .failure)
    }

    @Test func expansionIsKeptPerTurnWhileANewTurnStreamsAndFinishes() async throws {
        let recorded = try await RecordedTranscript()
        try await turn(recorded)
        let source = source(recorded, running: true)
        source.toggleExpansion(at: 1)
        let expanded = source.rows
        let next = UUID()
        try await recorded.append(try event(.prompt(id: next, content: [.init(text: "More")]), at: 100))
        try await recorded.apply(.toolCall(.init(toolCallId: "d", title: "Call d", status: .completed)))
        for chunk in ["All ", "done"] {
            try await recorded.apply(.agentMessageChunk(.init(content: .init(text: chunk))))
            source.state = recorded.state
            #expect(source.rows == expanded + [.item(9), .item(10), .item(11)])
        }
        try await recorded.append(try event(.finished(id: next, reason: .endTurn), at: 112))
        source.state = recorded.state
        source.running = false
        // The new turn folds collapsed; the first stays open.
        #expect(source.rows == expanded + [.item(9), .turn(first: 10), .item(11)])
        #expect(source.message(at: source.rows.count - 2).tool?.kind == "Worked for 12s")
    }

    @Test func findOpensTheFoldedTurnItStepsIntoAndCopySkipsTheFoldsRow() async throws {
        let recorded = try await RecordedTranscript()
        try await turn(recorded)
        let source = source(recorded)
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)

        // The fold's row has nothing to copy; the prompt and the answer around it copy as before.
        controller.table.selectRowIndexes([0, 1, 3], byExtendingSelection: false)
        #expect(controller.selectedMarkdown == "Fix the bug\n\nFixed the bug")
        let foldRow = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(foldRow.accessibilityCustomActions()?.isEmpty != false)

        // The answer is shown already: stepping to it leaves the turn folded.
        #expect(source.reveal(item: 8) == 3 && source.rows == Self.folded)
        #expect(TranscriptSearch.matches("needle", in: source.state.items) == [1])
        let revealed = try #require(source.reveal(item: 1))
        controller.update(source)
        controller.reveal(row: revealed)
        #expect(source.message(at: 1).tool?.expanded == true && revealed == 2)
        #expect(source.message(at: revealed).tool?.expanded == true)
        #expect(controller.table.selectedRowIndexes == [2] && controller.table.numberOfRows == 9)

        // Inner rows copy as before.
        controller.table.selectRowIndexes([3], byExtendingSelection: false)
        #expect(controller.selectedMarkdown.contains("Call a") && controller.selectedMarkdown.contains("Call b"))
    }

    @Test func theTableFoldsAFinishedTurnInPlaceAndItsChevronOpensIt() async throws {
        let recorded = try await RecordedTranscript()
        try await turn(recorded, end: .queuePaused(false))
        let source = source(recorded, running: true)
        let controller = TranscriptTableController()
        let window = host(controller)
        defer { window.close() }
        controller.update(source)
        #expect(controller.table.numberOfRows == 8)
        let answer = try #require(controller.table.view(atColumn: 0, row: 7, makeIfNecessary: true))

        let turnID = try #require(recorded.state.activeTurn)
        try await recorded.append(try event(.finished(id: turnID, reason: .endTurn), at: 63))
        source.state = recorded.state
        source.running = false
        source.revision += 1
        controller.update(source)
        #expect(controller.table.numberOfRows == 4)
        // The answer keeps its row.
        #expect(controller.table.view(atColumn: 0, row: 3, makeIfNecessary: false) === answer)
        let row = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let toggle = try #require(views(NSButton.self, in: row).first)
        #expect(toggle.title == "Worked for 1m 3s")
        #expect(toggle.accessibilityRole() == .disclosureTriangle && toggle.isAccessibilityExpanded() == false)

        controller.toggleExpansion(toggle)
        #expect(controller.table.numberOfRows == 9)
        let open = try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let openToggle = try #require(views(NSButton.self, in: open).first)
        #expect(openToggle.isAccessibilityExpanded() && openToggle.title == "Worked for 1m 3s")
        controller.toggleExpansion(openToggle)
        #expect(controller.table.numberOfRows == 4)
    }

    @Test func rowsFitTheirContentWhenATurnFoldsExpandsCollapsesAndResizes() async throws {
        let recorded = try await RecordedTranscript()
        let long = String(repeating: "An answer that wraps when the transcript is narrow. ", count: 12)
        try await turn(recorded, answer: long)
        func heights(_ controller: TranscriptTableController) -> [CGFloat] {
            (0..<controller.table.numberOfRows).map { controller.table.rect(ofRow: $0).height }
        }
        // AppKit measures the rows again on a later turn of the main queue.
        func settle(_ window: NSWindow) async {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func fresh(width: CGFloat, expanded: Bool) async -> [CGFloat] {
            let controller = TranscriptTableController()
            let freshSource = source(recorded)
            if expanded { freshSource.toggleExpansion(at: 1) }
            let window = host(controller, width: width)
            defer { window.close() }
            controller.update(freshSource)
            await settle(window)
            return heights(controller)
        }

        let controller = TranscriptTableController()
        let window = host(controller, width: 500)
        defer { window.close() }
        controller.update(source(recorded))
        await settle(window)
        let collapsed = heights(controller)
        #expect(collapsed.count == 4 && collapsed[1] < collapsed[3])
        #expect(collapsed == (await fresh(width: 500, expanded: false)))

        let toggle = try #require(
            views(NSButton.self, in: try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true)))
                .first
        )
        controller.toggleExpansion(toggle)
        await settle(window)
        #expect(heights(controller)[1] == collapsed[1])
        window.setContentSize(.init(width: 1364, height: 600))
        await settle(window)
        let wide = await fresh(width: 1364, expanded: true)
        #expect(zip(heights(controller), wide).allSatisfy { abs($0 - $1) <= 1 }, "\(heights(controller)), \(wide)")

        let reopened = try #require(
            views(NSButton.self, in: try #require(controller.table.view(atColumn: 0, row: 1, makeIfNecessary: true)))
                .first
        )
        controller.toggleExpansion(reopened)
        await settle(window)
        let wideCollapsed = await fresh(width: 1364, expanded: false)
        #expect(heights(controller).count == 4)
        #expect(
            zip(heights(controller), wideCollapsed).allSatisfy { abs($0 - $1) <= 1 },
            "\(heights(controller)), \(wideCollapsed)"
        )
    }

    #if DEBUG
        @Test func theRenderingLabPrototypeFoldsFinishedTurns() {
            let prototype = AppTranscriptPrototype()
            prototype.foldsTurns = true
            prototype.show(
                LabTranscript(items: [
                    .user("Go"), .assistant(markdown: "Fine"), .toolCall(title: "Run", output: "ok"),
                    .diff(path: "a.swift", patch: "+a"),
                ])
            )
            #expect(prototype.rows == [.item(0), .turn(first: 1), .item(1)])
            #expect(prototype.message(at: 1).tool?.kind == "Worked for 0s")
            prototype.startTurn()
            prototype.appendTools(RenderingLab.toolCards())
            prototype.didAppend()
            prototype.append("Hello")
            let running: [TranscriptRow] = [.item(0), .turn(first: 1), .item(1), .item(4), .group(first: 5), .item(10)]
            #expect(prototype.rows == running)
            prototype.finishTurn()
            #expect(prototype.rows == [.item(0), .turn(first: 1), .item(1), .item(4), .turn(first: 5), .item(10)])
        }
    #endif

    private func host(_ controller: TranscriptTableController, width: CGFloat = 600) -> NSWindow {
        let window = OffscreenWindow(size: .init(width: width, height: 600))
        controller.scroll.frame = window.contentLayoutRect
        controller.table.frame.size.width = width
        window.contentView = controller.scroll
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func views<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
        ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
}
