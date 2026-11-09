import ACP
import AppKit
import Foundation
import JSONRPC
import SwiftUI
import Testing

@testable import AgenthesiaCore
@testable import AgenthesiaUI

/// A pending form docked in the composer and answered one step at a time (#326).
@MainActor @Suite(.timeLimit(.minutes(1))) struct InputDockTests {
    /// The shape `claude-agent-acp` 0.101.0 gives AskUserQuestion: a choice and an optional `Other` text per question.
    private let questions = ACP.ElicitationSchema(properties: [
        "question_0": .string(
            .init(
                title: "Library",
                description: "Which library?",
                oneOf: [.init(const: "A", title: "A"), .init(const: "B", title: "B", description: "Second")]
            )
        ),
        "question_0_custom": .string(.init(title: "Other", description: "Your own answer")),
        "question_1": .multiSelect(.init(title: "Tests", items: .strings(["Unit", "UI", "Bench"]))),
        "question_1_custom": .string(.init(title: "Other")),
    ])

    private func form(
        _ schema: ACP.ElicitationSchema,
        message: String = "Please answer the following questions.",
        answer: @escaping (ACP.ElicitationResponse) -> Bool = { _ in true }
    ) -> DockedInput {
        let request = ACP.ElicitationRequest(
            message: message,
            mode: .form(schema),
            scope: .session("s", toolCallId: nil)
        )
        return DockedInput(
            input: .init(id: UUID(), request: request),
            schema: schema,
            draft: InputDraft(schema: schema),
            answer: answer
        )
    }

    // MARK: - Steps

    @Test func aChoiceAndTheOptionalTextAfterItAreOneStep() {
        #expect(
            InputStep.steps(questions) == [
                .init(control: "question_0", text: "question_0_custom"),
                .init(control: "question_1", text: "question_1_custom"),
            ]
        )
    }

    @Test func anyOtherFieldIsAStepOfItsOwn() {
        let schema = ACP.ElicitationSchema(
            properties: [
                "a": .string(.init(enum: ["x", "y"])), "b": .string(.init()),
                "c": .string(.init(oneOf: [.init(const: "x", title: "X")])), "d": .string(.init()),
                "e": .boolean(.init()), "f": .integer(.init()), "g": .number(.init()),
                "h": .multiSelect(.init(items: .strings(["x"]))), "i": .string(.init(enum: ["z"])),
                "j": .unknown(["type": "object"]),
            ],
            required: ["d"]
        )
        #expect(
            InputStep.steps(schema) == [
                .init(control: "a", text: "b"),
                // A required text is not an optional answer to the choice before it.
                .init(control: "c"), .init(text: "d"),
                .init(control: "e"), .init(text: "f"), .init(text: "g"),
                // A choice after a choice stays its own step.
                .init(control: "h"), .init(control: "i"), .init(control: "j"),
            ]
        )
    }

    /// The decoded schema has no order, so names with numbers are compared by value; the names mean nothing else.
    @Test func stepsFollowTheNamesWithNumbersComparedByValue() {
        var properties: [String: ACP.PropertySchema] = [:]
        for index in [0, 2, 10] {
            properties["pick_\(index)"] = .string(.init(enum: ["x"]))
            properties["pick_\(index)_note"] = .string(.init())
        }
        #expect(InputStep.steps(.init(properties: properties)).map(\.control) == ["pick_0", "pick_2", "pick_10"])
        #expect(InputStep.steps(.init(properties: properties)).allSatisfy { $0.text == "\($0.control ?? "")_note" })
        #expect(InputStep.steps(.init()) == [InputStep()])
    }

    @Test func theTranscriptRowCountsTheQuestions() {
        #expect(LiveTranscriptSource.waitingInput(questions) == "Asked 2 questions · answer below")
        #expect(
            LiveTranscriptSource.waitingInput(.init(properties: ["a": .string(.init())]))
                == "Asked 1 question · answer below"
        )
    }

    // MARK: - The docked form

    @Test func eachStepShowsItsQuestionChoicesAndProgress() {
        let form = form(questions)
        #expect(form.progress == "1 of 2" && !form.isLast)
        #expect(form.title == "Library" && form.question == "Which library?")
        #expect(form.message == "Please answer the following questions.")
        #expect(form.choices.map(\.title) == ["A", "B"] && !form.isMultiple)
        #expect(form.placeholder == "Your own answer")
        #expect(form.announcement == "Question 1 of 2 Library: Which library?")

        let single = self.form(
            .init(properties: ["q": .string(.init(title: "Pick", oneOf: [.init(const: "x", title: "X")]))]),
            message: "Which one?"
        )
        #expect(single.progress == nil && single.isLast)
        #expect(single.question == "Which one?" && single.message == nil)
        #expect(!single.takesText && single.placeholder == "Return continues")
    }

    @Test func picksAndTextFillTheStepsAnswers() {
        let form = form(questions)
        form.movePick(by: 1)
        #expect(form.draft.values["question_0"] == "A")
        form.movePick(by: 1)
        form.movePick(by: 1)
        #expect(form.draft.values["question_0"] == "B")
        form.movePick(by: -1)
        #expect(form.draft.values["question_0"] == "A")
        form.pick(1)
        #expect(form.isPicked(form.choices[1]) && !form.isPicked(form.choices[0]))
        form.pick(7)
        #expect(form.draft.values["question_0"] == "B")

        form.text = "with a note"
        #expect(form.text == "with a note" && form.draft.values["question_0_custom"] == "with a note")
        // An optional text emptied again is left out, as if never typed.
        form.text = ""
        #expect(form.draft.values["question_0_custom"] == nil)
        form.text = "with a note"

        #expect(form.advance())
        #expect(form.index == 1 && form.text.isEmpty && form.isMultiple && form.isLast)
        form.pick(0)
        form.pick(2)
        form.pick(0)
        form.movePick(by: 1)
        #expect(form.draft.values["question_1"] == ["Bench"])
        form.pick(2)
        #expect(form.draft.values["question_1"] == nil)
    }

    /// Back shows the previous step with its answers; the later step keeps its own, and nothing is sent meanwhile.
    @Test func backKeepsTheAnswersOfBothSteps() {
        var answered = false
        let form = form(questions) { _ in
            answered = true
            return true
        }
        #expect(!form.canGoBack && !form.goBack() && form.index == 0)
        form.pick(1)
        form.text = "a note"
        #expect(form.advance())
        form.pick(0)
        form.text = "more"
        #expect(form.canGoBack && form.goBack())
        #expect(form.index == 0 && form.progress == "1 of 2" && !form.canGoBack)
        #expect(form.isPicked(form.choices[1]) && form.text == "a note")
        form.pick(0)
        #expect(form.advance())
        #expect(form.text == "more" && form.isPicked(form.choices[0]) && !answered)
        #expect(form.draft.values["question_0"] == "A" && form.draft.values["question_0_custom"] == "a note")
    }

    @Test func theLastStepSendsTheAnswersAndSkipDeclines() {
        var responses: [ACP.ElicitationResponse] = []
        let form = form(questions) {
            responses.append($0)
            return true
        }
        form.pick(0)
        #expect(form.advance() && responses.isEmpty)
        form.pick(1)
        form.text = "Snapshot"
        #expect(form.advance())
        #expect(
            responses == [
                .init(action: .accept(["question_0": "A", "question_1": ["UI"], "question_1_custom": "Snapshot"]))
            ]
        )
        #expect(form.decline())
        #expect(responses.last == .init(action: .decline))
    }

    /// Validation stays as ADR-0020 has it: a step with errors does not move on, and the last step checks the form.
    @Test func errorsHoldTheStepBack() {
        let schema = ACP.ElicitationSchema(
            properties: [
                "count": .integer(.init(title: "Count", maximum: 3)), "name": .string(.init(minLength: 2)),
                "flag": .boolean(.init()),
            ],
            required: ["name", "future"]
        )
        var answered = false
        let form = form(schema) { _ in
            answered = true
            return true
        }
        #expect(form.steps.map(\.keys) == [["count"], ["flag"], ["name"]])
        form.text = "7"
        #expect(form.errors.map(\.key) == ["count"] && !form.canAdvance && !form.advance())
        form.text = "two"
        #expect(!form.canAdvance)
        form.text = "2"
        #expect(form.draft.values["count"] == 2)
        #expect(form.advance() && form.title == "flag")
        #expect(form.advance() && form.title == "name (required)")
        #expect(form.errors.map(\.key) == ["future", "name"])
        #expect(form.errors.first?.message == "future: Required field.")
        form.text = "Ada"
        #expect(!form.advance() && !answered)
    }

    // MARK: - With the agent

    @Test func theDraftWaitsWhileTheFormIsAnsweredAndTheAgentGetsTheAnswers() async throws {
        let fixture = try await Fixture()
        let model = fixture.model
        let controller = fixture.controller
        model.composer.message.text = "my draft"
        try await controller.submit([.init(text: "ask")])
        try await waitUntil { !controller.pendingInputs.isEmpty }

        let transcript = LiveTranscriptSource()
        transcript.update(controller)
        let rows = (0..<transcript.messageCount).map { transcript.message(at: $0) }
        #expect(rows.contains { $0.markdown == "Asked 2 questions · answer below" && $0.input == nil })

        let first = try #require(model.dockedInput(controller))
        #expect(first.progress == "1 of 2" && first.title == "Library")
        #expect(first.choices.map(\.const) == ["Foundation", "SwiftDate"])
        first.pick(1)
        first.text = "with ISO weeks"
        #expect(model.composer.message.text == "my draft")
        #expect(first.advance())

        let second = try #require(model.dockedInput(controller))
        #expect(second.index == 1 && second.isMultiple && second.text.isEmpty)
        #expect(second.draft === first.draft)
        second.pick(0)
        second.pick(2)
        #expect(second.advance())
        try await waitUntil { controller.status == .idle }
        #expect(model.dockedInput(controller) == nil)
        #expect(model.composer.message.text == "my draft")
        let expected =
            #"Answers: {"question_0":"SwiftDate","question_0_custom":"with ISO weeks","question_1":["Unit","Benchmark"]}"#
        #expect(agentText(of: controller).contains(expected))
        transcript.update(controller)
        #expect((0..<transcript.messageCount).contains { transcript.message(at: $0).input?.input.response != nil })
        await fixture.remove()
    }

    @Test func theOldestFormDocksAndSkipDeclinesIt() async throws {
        let fixture = try await Fixture()
        let controller = fixture.controller
        let agentSession = try #require(controller.session.agentSessionID)
        let request = ACP.ElicitationRequest(
            message: "Name",
            mode: .form(.init(properties: ["name": .string(.init())])),
            scope: .session(agentSession, toolCallId: nil)
        )
        let first = Task { await controller.requestInput(request) }
        try await waitUntil { controller.pendingInputs.count == 1 }
        let second = Task { await controller.requestInput(request) }
        try await waitUntil { controller.pendingInputs.count == 2 }
        let oldest = try #require(fixture.model.dockedInput(controller))
        #expect(oldest.input.id == controller.pendingInputs.first?.id)
        oldest.text = "Ada"
        #expect(oldest.decline())
        #expect(await first.value == .init(action: .decline))

        // The next form docks with answers of its own.
        let next = try #require(fixture.model.dockedInput(controller))
        #expect(next.input.id != oldest.input.id && next.text.isEmpty)
        #expect(next.advance())
        #expect(await second.value == .init(action: .accept([:])))
        await fixture.remove()
    }

    // MARK: - Hosted

    /// The dock shows above the composer, whose text is the step's answer; Return moves on and 1–9 pick.
    @Test func theComposerAnswersTheDockedForm() async throws {
        let fixture = try await Fixture()
        let model = fixture.model
        let controller = fixture.controller
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView(model: model))
        let window = OffscreenWindow(size: .init(width: 1000, height: 700))
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await controller.submit([.init(text: "hello")])
        try await waitUntil { controller.status == .idle }
        model.composer.message.text = "my draft"
        let scroll = try #require(first(TranscriptScrollView.self, in: view))
        let composer = try #require(first(FileTextView.self, in: view))
        try await waitUntil { composer.string == "my draft" }
        let height = scroll.contentView.bounds.height

        try await controller.submit([.init(text: "ask")])
        try await waitUntil { !controller.pendingInputs.isEmpty }
        try await waitUntil { composer.accessibilityLabel() == "Answer" && composer.string.isEmpty }
        #expect(window.makeFirstResponder(composer))
        // The dock's question and choices take room from the transcript, more than the status line does.
        try await waitUntil { height - scroll.contentView.bounds.height > 80 }

        composer.keyDown(with: try key("2", code: 19))
        let form = try #require(model.dockedInput(controller))
        #expect(form.draft.values["question_0"] == "SwiftDate")
        #expect(composer.string.isEmpty)
        composer.insertText("a note", replacementRange: composer.selectedRange())
        #expect(form.draft.values["question_0_custom"] == "a note")
        // A digit after text is part of the answer.
        composer.keyDown(with: try key("1", code: 18))
        try await waitUntil { form.draft.values["question_0_custom"] == "a note1" }

        composer.keyDown(with: try key("\r", code: 36))
        try await waitUntil { form.index == 1 && composer.string.isEmpty }
        composer.keyDown(with: try key("1", code: 18))
        #expect(form.draft.values["question_1"] == ["Unit"])

        // Back shows step 1 with its pick and text; a changed pick is what the agent gets.
        // The dock's buttons are SwiftUI's own, not AppKit views a test can click; this is Back's action.
        #expect(form.goBack())
        try await waitUntil { form.index == 0 && composer.string == "a note1" }
        #expect(form.isPicked(form.choices[1]))
        composer.selectAll(nil)
        composer.deleteBackward(nil)
        try await waitUntil { form.draft.values["question_0_custom"] == nil }
        composer.keyDown(with: try key("1", code: 18))
        #expect(form.draft.values["question_0"] == "Foundation")
        composer.keyDown(with: try key("\r", code: 36))
        try await waitUntil { form.index == 1 }
        composer.keyDown(with: try key("\r", code: 36))
        try await waitUntil { controller.status == .idle && composer.string == "my draft" }
        #expect(composer.accessibilityLabel() == "Message")
        try await waitUntil { scroll.contentView.bounds.height >= height - 1 }
        #expect(agentText(of: controller).contains(#"Answers: {"question_0":"Foundation","question_1":["Unit"]}"#))
        await fixture.remove()
    }

    /// A step without a text answer leaves the composer read-only; Return still reaches it.
    @Test func aReadOnlyComposerStillTakesReturn() throws {
        final class Delegate: NSObject, NSTextViewDelegate {
            var commands: [Selector] = []
            func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
                commands.append(selector)
                return true
            }
        }
        let window = OffscreenWindow(size: .init(width: 300, height: 100))
        let text = FileTextView(frame: .init(x: 0, y: 0, width: 300, height: 100))
        let delegate = Delegate()
        text.delegate = delegate
        text.isEditable = false
        window.contentView = text
        #expect(window.makeFirstResponder(text))
        text.keyDown(with: try key("\r", code: 36))
        #expect(delegate.commands == [#selector(NSResponder.insertNewline(_:))])
        window.close()
    }

    // MARK: - Support

    private func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            )
        )
    }

    private func agentText(of controller: SessionController) -> String {
        controller.transcript.items.compactMap(\.message).filter { $0.role == .assistant }
            .map { LiveTranscriptSource.markdown(of: $0.content) }.joined()
    }

    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "input-dock-\(UUID())")
        let sessions: SessionManager
        let model: SessionWindowModel
        let controller: SessionController

        init() async throws {
            sessions = SessionManager(
                library: SessionLibrary(databaseURL: directory.appending(path: "history.sqlite"))
            )
            sessions.environment = { (ProcessInfo.processInfo.environment, nil) }
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = SessionWindowModel(sessions: sessions)
            model.start(directory: directory, executable: binary.path, arguments: [])
            let owner = try #require(model.owner)
            await owner.startup?.value
            controller = try #require(owner.controller)
        }

        func remove() async {
            model.close()
            await sessions.closeAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func waitUntil(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out", sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        return view.subviews.lazy.compactMap { first(type, in: $0) }.first
    }
}
