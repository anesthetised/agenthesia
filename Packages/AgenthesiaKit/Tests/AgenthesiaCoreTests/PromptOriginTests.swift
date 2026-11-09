import ACP
import Foundation
import Testing

@testable import AgenthesiaCore
@testable import Persistence

@Suite struct PromptOriginTests {
    private let id = UUID()

    @Test func aLogWrittenBeforeOriginsDecodesAsTheUsers() throws {
        let json = """
            {"promptMessage":{"prompt":{"id":"\(id.uuidString)","content":[{"type":"text","text":"hi"}]},\
            "turnID":"\(id.uuidString)","startsTurn":true,"sentTogether":false}}
            """
        let event = try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        guard case .promptMessage(let prompt, _, _, _) = event else {
            Issue.record("Decoded \(event)")
            return
        }
        #expect(prompt == QueuedPrompt(id: id, content: [.init(text: "hi")]))
        #expect(prompt.origin == .user)
    }

    @Test func theUsersPromptIsStoredAsBefore() throws {
        let data = try JSONEncoder().encode(QueuedPrompt(content: [.init(text: "hi")]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "content"])
    }

    @Test(arguments: [
        QueuedPrompt.Origin.user, .session(id: UUID(), turnID: UUID()), .delegation(taskID: UUID()),
        .delivery(taskID: UUID()), .task(taskID: UUID()),
    ])
    func everyOriginRoundTrips(origin: QueuedPrompt.Origin) throws {
        let prompt = QueuedPrompt(content: [.init(text: "hi")], origin: origin)
        #expect(try JSONDecoder().decode(QueuedPrompt.self, from: JSONEncoder().encode(prompt)) == prompt)
    }

    @Test func eachOriginHasItsLabel() {
        let session = QueuedPrompt.Origin.session(id: id, turnID: id)
        #expect(QueuedPrompt.Origin.user.label(title: "Fix", agent: "Codex") == nil)
        #expect(session.label(title: "Fix the build", agent: "Claude") == "From Fix the build · Claude")
        #expect(session.label(title: nil, agent: "Claude") == "From another session · Claude")
        #expect(session.label(title: nil, agent: nil) == "From another session")
        #expect(QueuedPrompt.Origin.delegation(taskID: id).label(title: nil, agent: nil) == "Delegated task")
        #expect(QueuedPrompt.Origin.delivery(taskID: id).label(title: nil, agent: nil) == "Delegated result")
        #expect(QueuedPrompt.Origin.task(taskID: id).label(title: nil, agent: nil) == "Background task")
    }

    @Test func theAgentSeesAnotherSessionsPromptAsAnAnonymousAgentMessage() {
        let content: [ACP.ContentBlock] = [.init(text: "Run the tests")]
        #expect(QueuedPrompt.Origin.user.wrapped(content) == content)
        let wrapped = QueuedPrompt.Origin.session(id: id, turnID: id).wrapped(content)
        #expect(wrapped.count == 3 && wrapped[1] == content[0])
        let text = QueuedPrompt(content: wrapped).text
        #expect(
            text
                == "The message below comes from another agent session, not from the user.\n<message>\nRun the tests\n</message>"
        )
        #expect(QueuedPrompt(content: QueuedPrompt.Origin.delegation(taskID: id).wrapped(content)).text == text)
        for origin in [QueuedPrompt.Origin.delivery(taskID: id), .task(taskID: id)] {
            let text = QueuedPrompt(content: origin.wrapped(content)).text
            #expect(text.contains("not from the user") && text.hasSuffix("Run the tests\n</message>"))
        }
    }

    @Test func theTranscriptKeepsEachPromptsOriginAndTheTurnsOrigin() throws {
        let origin = QueuedPrompt.Origin.session(id: id, turnID: id)
        let turn = UUID()
        let events: [SessionEvent] = [
            .promptMessage(
                prompt: .init(content: [.init(text: "a")], origin: origin),
                turnID: turn,
                startsTurn: true,
                sentTogether: false
            ),
            .promptMessage(
                prompt: .init(content: [.init(text: "b")]),
                turnID: turn,
                startsTurn: false,
                sentTogether: false
            ),
        ]
        var state = TranscriptState()
        for (index, event) in events.enumerated() {
            try state.apply(StoredEvent(sessionID: id, sequence: Int64(index + 1), event: event.storedEvent()))
        }
        #expect(state.items.map(\.message?.origin) == [origin, .user])
        // A message steered into the turn does not change who started it.
        #expect(state.turnOrigin == origin && state.activeTurn == turn)
        try state.apply(
            StoredEvent(sessionID: id, sequence: 3, event: SessionEvent.prompt(id: UUID(), content: []).storedEvent())
        )
        #expect(state.turnOrigin == .user)
    }

    @Test func aRunningTurnFromAnotherSessionIsTheSidebarReason() {
        #expect(SidebarReason.text(activity: .working, turnOrigin: "From Fix · Claude") == "From Fix · Claude")
        #expect(SidebarReason.text(activity: .working, stopping: true, turnOrigin: "From Fix · Claude") == "Stopping")
        #expect(SidebarReason.text(activity: .done, turnOrigin: "From Fix · Claude") == "Finished")
    }

    @MainActor @Test func aSourceSessionThatIsNotOpenIsAnotherSession() {
        let manager = SessionManager(library: SessionLibrary(databaseURL: URL(filePath: "/dev/null")))
        #expect(manager.originLabel(.user) == nil)
        #expect(manager.originLabel(.session(id: id, turnID: id)) == "From another session")
        #expect(manager.originLabel(.task(taskID: id)) == "Background task")
    }
}
