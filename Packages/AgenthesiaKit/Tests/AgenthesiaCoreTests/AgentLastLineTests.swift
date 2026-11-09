import ACP
import Foundation
import JSONRPC
import Testing

@testable import AgenthesiaCore
@testable import Persistence

/// The agent's last line on a board card (ADR-0046).
@Suite struct AgentLastLineTests {
    private struct Transcript {
        var state = TranscriptState()
        private var sequence: Int64 = 0
        private let id = UUID()

        mutating func apply(_ update: ACP.SessionUpdate) throws {
            let payload = try JSONEncoder().encode(
                Message.notification(
                    method: "session/update",
                    params: try JSONValue(encoding: ACP.V1.SessionNotification(sessionId: "s", update: update))
                )
            )
            sequence += 1
            try state.apply(
                StoredEvent(
                    sessionID: id,
                    sequence: sequence,
                    event: NewEvent(kind: SessionEvent.updateKind, payload: payload)
                )
            )
        }

        mutating func say(_ text: String, as role: TranscriptState.Role = .assistant, id: String) throws {
            let chunk = ACP.ContentChunk(content: .init(text: text), messageId: id)
            switch role {
            case .assistant: try apply(.agentMessageChunk(chunk))
            case .user: try apply(.userMessageChunk(chunk))
            case .thought: try apply(.agentThoughtChunk(chunk))
            }
        }

        mutating func call(_ id: String, _ title: String, _ status: ACP.ToolCallStatus?) throws {
            try apply(.toolCall(.init(toolCallId: id, title: title, status: status)))
        }
    }

    @Test func nothingSaidHasNoLine() throws {
        var transcript = Transcript()
        #expect(transcript.state.agentLastLine == nil)
        try transcript.say("Fix the build", as: .user, id: "u")
        try transcript.say("Thinking", as: .thought, id: "t")
        #expect(transcript.state.agentLastLine == nil)
    }

    @Test func theFirstLineOfTheLastAssistantMessage() throws {
        var transcript = Transcript()
        try transcript.say("Earlier answer", id: "a")
        try transcript.say("\n\n  Tests   pass now.\nSecond line", id: "b")
        try transcript.say("Thanks", as: .user, id: "u")
        #expect(transcript.state.agentLastLine == "Tests pass now.")
    }

    @Test func aRunningToolCallAfterTheMessageNamesItsTitle() throws {
        var transcript = Transcript()
        try transcript.say("Running the tests", id: "a")
        try transcript.call("run", "swift test", .inProgress)
        #expect(transcript.state.agentLastLine == "swift test")
        try transcript.apply(.toolCallUpdate(.init(toolCallId: "run", status: .completed)))
        // Finished, the call gives way to the message before it.
        #expect(transcript.state.agentLastLine == "Running the tests")
        try transcript.call("pending", "Read notes.md", .pending)
        #expect(transcript.state.agentLastLine == "Read notes.md")
        try transcript.call("failed", "Fetch", .failed)
        #expect(transcript.state.agentLastLine == "Read notes.md")
    }

    @Test func aMessageAfterARunningCallWinsAndUntitledCallsAreSkipped() throws {
        var transcript = Transcript()
        try transcript.call("run", "swift build", nil)
        #expect(transcript.state.agentLastLine == "swift build")
        try transcript.say("While that builds", id: "a")
        #expect(transcript.state.agentLastLine == "While that builds")
        try transcript.call("blank", "  \n ", .inProgress)
        #expect(transcript.state.agentLastLine == "While that builds")
    }

    @Test func aLongLineIsCutLikeAReason() throws {
        var transcript = Transcript()
        try transcript.say(String(repeating: "a", count: 300), id: "a")
        #expect(transcript.state.agentLastLine?.count == SidebarReason.titleLimit)
    }
}
