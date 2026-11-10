import ACP
import AppKit
import Foundation
import JSONRPC
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// Answered questions, interrupted turns and failed ones as T3 Code shows them (#340).
@MainActor @Suite struct TranscriptOutcomeRowsTests {
    private static let schema = ACP.ElicitationSchema(
        properties: [
            "q_0": .string(
                .init(
                    title: "Library",
                    description: "Which date\n  library?",
                    oneOf: [.init(const: "swift", title: "SwiftDate"), .init(const: "own", title: "Our own")]
                )
            ),
            "q_0_custom": .string(.init()),
            "q_1": .multiSelect(
                .init(
                    title: "Features",
                    items: .titled([.init(const: "a", title: "Alpha"), .init(const: "b", title: "Beta")])
                )
            ),
            "q_2": .boolean(.init()),
        ]
    )

    private func input(_ action: ACP.ElicitationResponse.Action?) -> TranscriptState.Input {
        .init(
            requestID: UUID(),
            request: .init(message: "Questions", mode: .form(Self.schema), scope: .session("s", toolCallId: nil)),
            response: action.map { .init(action: $0) }
        )
    }

    @Test func answersPairWithTheComposersStepsAndCustomTextReplacesThePick() {
        let answer = InputAnswer(
            input(.accept(["q_0": "swift", "q_0_custom": "keep it small", "q_1": ["a", "b"], "q_2": true])),
            recording: false
        )
        #expect(
            answer.pairs == [
                .init(question: "Which date\n  library?", answer: "keep it small"),
                .init(question: "Features", answer: "Alpha, Beta"),
                // Without a title or description, a field reads as its name.
                .init(question: "q_2", answer: "Yes"),
            ]
        )
        #expect(answer.outcome == nil)
        #expect(answer.questions == "Which date library? · Features · q_2")
        #expect(answer.answers == "keep it small · Alpha, Beta · Yes")
        #expect(answer.text == "Which date\n  library?\n  keep it small\n\nFeatures\n  Alpha, Beta\n\nq_2\n  Yes")

        // A pick without custom text reads as its title; an unanswered step has no answer.
        let picked = InputAnswer(input(.accept(["q_0": "own", "q_0_custom": ""])), recording: false)
        #expect(picked.pairs.map(\.answer) == ["Our own", "", ""])
        #expect(picked.answers == "Our own")
    }

    @Test func aFormThatWasNotSubmittedReadsAsItsOutcome() {
        let cases: [(ACP.ElicitationResponse.Action?, Bool, String)] = [
            (.decline, false, "Declined"), (.cancel, false, "Cancelled"), (nil, true, "Recording answer…"),
            (nil, false, "Cancelled"),
        ]
        for (action, recording, outcome) in cases {
            let answer = InputAnswer(input(action), recording: recording)
            #expect(answer.outcome == outcome && answer.answers == outcome)
            #expect(answer.pairs.allSatisfy { $0.answer.isEmpty })
            #expect(answer.text == "Which date\n  library?\n\nFeatures\n\nq_2\n\n\(outcome)")
        }
    }

    @Test func anAnsweredFormIsOneRowWithItsAnswersBehindTheDisclosure() async throws {
        let recorded = try await RecordedTranscript()
        let id = UUID()
        let form = input(nil)
        try await recorded.append(SessionEvent.inputRequested(id: id, request: form.request).storedEvent())
        try await recorded.append(
            SessionEvent.inputResolved(id: id, response: .init(action: .accept(["q_0": "swift", "q_1": ["b"]])))
                .storedEvent()
        )
        let source = LiveTranscriptSource()
        source.state = recorded.state
        let collapsed = source.message(at: 0)
        #expect(collapsed.kind == .question && collapsed.markdown.isEmpty)
        #expect(collapsed.tool?.kind == "Which date library? · Features · q_2")
        #expect(collapsed.tool?.status == "SwiftDate · Beta" && collapsed.tool?.tone == .primary)
        #expect(collapsed.tool?.expandable == true && collapsed.tool?.expanded == false)
        let text = "Which date\n  library?\n  SwiftDate\n\nFeatures\n  Beta\n\nq_2"
        #expect(collapsed.copyText?() == text)
        #expect(LiveTranscriptSource.content(recorded.state.items[0]).1 == text)

        source.toggleExpansion(at: 0)
        let expanded = source.message(at: 0)
        #expect(expanded.markdown == text && expanded.tool?.expanded == true && expanded.tool?.tone == .neutral)
        #expect(expanded.text.string == "Which date\n  library?\nSwiftDate\nFeatures\nBeta\nq_2")
    }

    /// Stop records the stop request alone; a prompt sent now records it with `interrupted`, then starts its own turn.
    private func interrupt(
        _ recorded: RecordedTranscript,
        steer: String?,
        reason: ACP.StopReason = .cancelled
    )
        async throws
    {
        let turn = UUID()
        try await recorded.append(SessionEvent.prompt(id: turn, content: [.init(text: "go")]).storedEvent())
        try await recorded.append(SessionEvent.stopRequested(id: turn).storedEvent())
        if steer != nil { try await recorded.append(SessionEvent.interrupted(id: turn).storedEvent()) }
        try await recorded.append(SessionEvent.finished(id: turn, reason: reason).storedEvent())
        guard let steer else { return }
        let prompt = QueuedPrompt(content: [.init(text: steer)])
        try await recorded.append(
            SessionEvent.promptMessage(prompt: prompt, turnID: UUID(), startsTurn: true, sentTogether: false)
                .storedEvent()
        )
    }

    @Test func stopEndsWithTheRedDividerAndASteerWithALineAndItsLabel() async throws {
        let recorded = try await RecordedTranscript()
        try await interrupt(recorded, steer: nil)
        try await interrupt(recorded, steer: "now")
        let items = recorded.state.items
        #expect(items.map(\.interruption) == [nil, .stopped, nil, .steered, nil])
        #expect(items.compactMap(\.message).map(\.isSteer) == [false, false, true])

        let source = LiveTranscriptSource()
        source.state = recorded.state
        let stopped = source.message(at: 1)
        #expect(stopped.kind == .interruption && stopped.markdown == "Run interrupted · Stopped by user")
        let line = source.message(at: 3)
        #expect(line.kind == .interruption && line.isNotice && line.markdown.isEmpty)
        let steer = source.message(at: 4)
        #expect(steer.kind == .user && steer.label == "Steer" && steer.markdown == "now" && steer.role == "You")
        #expect(source.message(at: 2).label == nil)

        // Another session's steer keeps its origin label and says `Steer` after it.
        source.originLabel = { $0 == .user ? "From Fix CI" : nil }
        #expect(source.message(at: 4).role == "From Fix CI · Steer" && source.message(at: 4).kind == .card)
        #expect(source.message(at: 4).label == nil && source.message(at: 2).role == "From Fix CI")
    }

    @Test func aSteerSentAfterATurnThatEndedAnywayIsStillOneAndAStopDropsAPendingSteer() async throws {
        let recorded = try await RecordedTranscript()
        // The turn finished before the stop reached the agent: no line, but the prompt was sent now.
        try await interrupt(recorded, steer: "late", reason: .endTurn)
        #expect(recorded.state.items.allSatisfy { $0.interruption == nil })
        #expect(recorded.state.items.last?.message?.isSteer == true)

        // Stop after the interrupted turn ended: the steering prompt was never sent, the next one is no steer.
        let turn = UUID()
        try await recorded.append(SessionEvent.prompt(id: turn, content: [.init(text: "go")]).storedEvent())
        try await recorded.append(SessionEvent.stopRequested(id: turn).storedEvent())
        try await recorded.append(SessionEvent.interrupted(id: turn).storedEvent())
        try await recorded.append(SessionEvent.finished(id: turn, reason: .cancelled).storedEvent())
        try await recorded.append(SessionEvent.queuePaused(true).storedEvent())
        try await recorded.append(SessionEvent.prompt(id: UUID(), content: [.init(text: "later")]).storedEvent())
        #expect(recorded.state.items.last?.message?.isSteer == false)

        // Closing the session cancels a turn without a stop request: nothing marks it.
        let closed = UUID()
        try await recorded.append(SessionEvent.prompt(id: closed, content: [.init(text: "go")]).storedEvent())
        try await recorded.append(SessionEvent.finished(id: closed, reason: .cancelled).storedEvent())
        #expect(recorded.state.items.last?.interruption == nil)
    }

    @Test(arguments: [true, false]) func theSteerAndItsLineInLightAndDark(light: Bool) async throws {
        let recorded = try await RecordedTranscript()
        try await interrupt(recorded, steer: "now")
        let source = LiveTranscriptSource()
        source.state = recorded.state
        let controller = TranscriptTableController()
        let window = host(controller, width: 600)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        defer { window.close() }
        controller.update(source)
        window.contentView?.layoutSubtreeIfNeeded()

        // A plain line: no text, no symbol, no red, nothing for VoiceOver or Copy.
        let line = try cell(controller, row: 1)
        #expect(labels(in: line).isEmpty && views(NSImageView.self, in: line).isEmpty)
        #expect(views(NSButton.self, in: line).isEmpty && views(NSBox.self, in: line).count == 1)
        #expect(line.accessibilityCustomActions()?.isEmpty != false)
        controller.table.selectRowIndexes([1, 2], byExtendingSelection: false)
        #expect(controller.selectedMarkdown == "now")

        // The steer: the bubble with `↪ Steer` right-aligned above it, read as one element.
        let steer = try cell(controller, row: 2)
        let bubble = try #require(views(BubbleCell.self, in: steer).first)
        let label = try #require(views(NSTextField.self, in: bubble).first { $0.stringValue == "Steer" })
        #expect(label.textColor == .secondaryLabelColor && label.font?.pointSize == NSFont.smallSystemFontSize)
        let icon = try #require(views(NSImageView.self, in: bubble).first)
        let field = try #require(views(LinkTextField.self, in: bubble).first)
        let labelFrame = label.convert(label.bounds, to: bubble)
        let fieldFrame = field.convert(field.bounds, to: bubble)
        #expect(labelFrame.minY > fieldFrame.maxY)
        // Right-aligned with the bubble; a text field's frame reaches a few points past its text.
        #expect(abs(labelFrame.maxX - bubble.bounds.maxX) <= 3 && labelFrame.minX > bubble.bounds.midX)
        #expect(icon.convert(icon.bounds, to: bubble).maxX <= labelFrame.minX)
        #expect(bubble.isAccessibilityElement() && bubble.accessibilityLabel() == "Steer, now")
        #expect(!field.isAccessibilityElement() && !label.isAccessibilityElement())
    }

    @Test(arguments: [true, false]) func theThreeRowsInLightAndDark(light: Bool) async throws {
        let recorded = try await rows()
        let source = LiveTranscriptSource()
        source.state = recorded.state
        let controller = TranscriptTableController()
        let window = host(controller, width: 600)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        defer { window.close() }
        controller.update(source)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(source.rows == [.item(0), .item(1), .item(2), .item(3), .item(4)])

        let question = try cell(controller, row: 1)
        #expect(labels(in: question).prefix(2) == ["Which date library? · Features · q_2", "SwiftDate · Beta"])
        #expect(
            views(NSTextField.self, in: question).first { $0.stringValue == "SwiftDate · Beta" }?.textColor
                == .labelColor
        )
        #expect(views(NSButton.self, in: question).contains { $0.bezelStyle == .disclosure && $0.isEnabled })

        let divider = try cell(controller, row: 2)
        #expect(labels(in: divider) == ["Run interrupted · Stopped by user"])
        #expect(views(NSButton.self, in: divider).isEmpty && views(NSBox.self, in: divider).count == 2)
        let line = try #require(views(NSStackView.self, in: divider).first)
        #expect(line.isAccessibilityElement() && line.accessibilityLabel() == "Run interrupted · Stopped by user")
        #expect(views(NSTextField.self, in: line).allSatisfy { !$0.isAccessibilityElement() })

        let error = try cell(controller, row: 4)
        let label = try #require(views(NSTextField.self, in: error).first { $0.stringValue == "Error" })
        #expect(label.textColor == .systemRed && label.font?.pointSize == NSFont.systemFontSize)
        #expect(labels(in: error).contains("Model overloaded"))
        let element = try #require(views(NSStackView.self, in: error).first)
        #expect(element.isAccessibilityElement() && element.accessibilityLabel() == "Error: Model overloaded")
        #expect(element.accessibilityCustomActions()?.map(\.name) == ["Copy", "Details"])
    }

    /// #351: the divider is drawn across the column, not bunched at its leading edge. No exact widths: only that each
    /// hairline is longer than the caption is tall, that the two match, and that the X and the caption sit in the middle.
    @Test(arguments: [1200.0, 600.0]) func theDividerSpansTheColumnWithItsCaptionInTheMiddle(width: Double) async throws
    {
        let recorded = try await rows()
        let source = LiveTranscriptSource()
        source.state = recorded.state
        let controller = TranscriptTableController()
        let window = host(controller, width: width)
        defer { window.close() }
        controller.update(source)
        window.contentView?.layoutSubtreeIfNeeded()

        let divider = try cell(controller, row: 2)
        let lines = views(NSBox.self, in: divider)
        let caption = try #require(views(NSTextField.self, in: divider).first)
        #expect(lines.count == 2)
        let icon = try #require(views(NSImageView.self, in: divider).first)
        let captionFrame = caption.convert(caption.bounds, to: divider)
        let middle = icon.convert(icon.bounds, to: divider).union(captionFrame).midX
        for line in lines {
            #expect(line.convert(line.bounds, to: divider).width > captionFrame.height)
        }
        let widths = lines.map { $0.convert($0.bounds, to: divider).width }
        #expect(abs(widths[0] - widths[1]) <= 2)
        #expect(abs(middle - divider.bounds.midX) <= 4)
    }

    /// Rows keep their own height since #302: each of the three fits its content after a resize, and the question's
    /// row grows with its answers and shrinks back.
    @Test func theRowsFitTheirContentAfterAResize() async throws {
        let recorded = try await rows(message: String(repeating: "The model is overloaded right now. ", count: 12))
        let source = LiveTranscriptSource()
        source.state = recorded.state
        func heights(_ controller: TranscriptTableController) -> [CGFloat] {
            (0..<controller.table.numberOfRows).map { controller.table.rect(ofRow: $0).height }
        }
        let fresh = TranscriptTableController()
        let freshWindow = host(fresh, width: 1364)
        defer { freshWindow.close() }
        fresh.update(source)
        freshWindow.contentView?.layoutSubtreeIfNeeded()

        let resized = TranscriptTableController()
        let window = host(resized, width: 500)
        defer { window.close() }
        resized.update(source)
        window.contentView?.layoutSubtreeIfNeeded()
        let narrow = heights(resized)
        window.setContentSize(.init(width: 1364, height: 600))
        await nextTurn()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(narrow[4] > heights(fresh)[4] + 20)
        for (row, (height, expected)) in zip(heights(resized), heights(fresh)).enumerated() {
            #expect(abs(height - expected) <= 1, "row \(row) is \(height) pt, \(expected) pt when built this wide")
        }

        let folded = heights(resized)[1]
        source.toggleExpansion(at: 1)
        resized.update(source)
        await nextTurn()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(heights(resized)[1] > folded + 40)
        source.toggleExpansion(at: 1)
        resized.update(source)
        await nextTurn()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(heights(resized)[1] - folded) <= 1)
    }

    /// A prompt, an answered form, a stopped turn's divider, a prompt and its error.
    private func rows(message: String = "Model overloaded") async throws -> RecordedTranscript {
        let recorded = try await RecordedTranscript()
        let stopped = UUID()
        try await recorded.append(SessionEvent.prompt(id: stopped, content: [.init(text: "go")]).storedEvent())
        let id = UUID()
        try await recorded.append(SessionEvent.inputRequested(id: id, request: input(nil).request).storedEvent())
        try await recorded.append(
            SessionEvent.inputResolved(id: id, response: .init(action: .accept(["q_0": "swift", "q_1": ["b"]])))
                .storedEvent()
        )
        try await recorded.append(SessionEvent.stopRequested(id: stopped).storedEvent())
        try await recorded.append(SessionEvent.finished(id: stopped, reason: .cancelled).storedEvent())
        let failed = UUID()
        try await recorded.append(SessionEvent.prompt(id: failed, content: [.init(text: "again")]).storedEvent())
        let stored = String(describing: RPCError(code: -32603, message: message, data: nil))
        try await recorded.append(SessionEvent.failed(id: failed, message: stored).storedEvent())
        return recorded
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func host(_ controller: TranscriptTableController, width: CGFloat) -> NSWindow {
        let window = OffscreenWindow(size: .init(width: width, height: 600))
        controller.scroll.frame = window.contentLayoutRect
        controller.table.frame.size.width = width
        window.contentView = controller.scroll
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func cell(_ controller: TranscriptTableController, row: Int) throws -> NSView {
        let view = try #require(controller.table.view(atColumn: 0, row: row, makeIfNecessary: true))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func views<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
        ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func labels(in view: NSView) -> [String] {
        views(NSTextField.self, in: view).filter { !($0.superview is NSButton) }.map(\.stringValue)
    }
}
