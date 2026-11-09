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

    @Test func aStoppedTurnEndsWithTheDivider() async throws {
        let recorded = try await RecordedTranscript()
        let stopped = UUID()
        try await recorded.append(SessionEvent.prompt(id: stopped, content: [.init(text: "go")]).storedEvent())
        try await recorded.append(SessionEvent.stopRequested(id: stopped).storedEvent())
        try await recorded.append(SessionEvent.interrupted(id: stopped).storedEvent())
        #expect(recorded.state.items.count == 1)
        try await recorded.append(SessionEvent.finished(id: stopped, reason: .cancelled).storedEvent())
        #expect(recorded.state.items.last?.isInterruption == true)

        // A turn that ends anyway, or is cancelled by closing the session, has none.
        for reason in [ACP.StopReason.endTurn, .cancelled] {
            let turn = UUID()
            try await recorded.append(SessionEvent.prompt(id: turn, content: [.init(text: "again")]).storedEvent())
            if reason == .endTurn { try await recorded.append(SessionEvent.stopRequested(id: turn).storedEvent()) }
            try await recorded.append(SessionEvent.finished(id: turn, reason: reason).storedEvent())
        }
        #expect(recorded.state.items.count { $0.isInterruption } == 1)

        let source = LiveTranscriptSource()
        source.state = recorded.state
        let divider = source.message(at: 1)
        #expect(divider.kind == .interruption && divider.isNotice)
        #expect(divider.markdown == "Run interrupted · Stopped by user")
        #expect(LiveTranscriptSource.content(recorded.state.items[1]).1 == divider.markdown)
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
