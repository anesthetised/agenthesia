import JSONRPC
import Testing

@testable import AgenthesiaCore

struct SessionFailureTests {
    private func failure(_ error: any Error) -> SessionFailure { SessionFailure(String(describing: error)) }

    @Test func aSessionTheAgentForgotOffersANewSession() {
        let unknown = failure(RPCError(code: RPCError.resourceNotFoundCode, message: "Unknown session"))
        #expect(unknown.summary == "The agent no longer has this session.")
        #expect(unknown.details == "RPCError(code: -32002, message: \"Unknown session\", data: nil)")
        #expect(unknown.actions == [.newSession])
        // Another not-found error keeps its own message.
        let file = failure(RPCError(code: RPCError.resourceNotFoundCode, message: "Not found: a.txt"))
        #expect(file.summary == "Not found: a.txt" && file.actions == [.agentLog])
    }

    @Test func signInRequiredIsExplained() {
        let auth = failure(RPCError(code: RPCError.authRequiredCode, message: "Authentication required"))
        #expect(auth.summary == "The agent needs you to sign in." && auth.actions.isEmpty && auth.details != nil)
    }

    @Test func otherAgentErrorsShowTheirMessageAndTheLog() {
        let error = failure(RPCError.internalError("model overloaded"))
        #expect(error.summary == "model overloaded" && error.actions == [.agentLog])
        #expect(error.details == "RPCError(code: -32603, message: \"model overloaded\", data: nil)")
    }

    @Test func aClosedConnectionOffersRetryAndTheLog() {
        let closed = failure(ConnectionError.closed)
        #expect(closed.summary == "The connection to the agent closed.")
        #expect(closed.actions == [.retry, .agentLog] && closed.details == "closed")
    }

    @Test func anExitedAgentOffersRetryAndTheLogWithoutDetails() {
        for text in [
            "The agent exited with code 1. Continue to reconnect.",
            "The agent killed by signal 9. Continue to reconnect.",
        ] {
            let exited = SessionFailure(text)
            #expect(exited.summary == text && exited.details == nil && exited.actions == [.retry, .agentLog])
        }
    }

    @Test func aMissingOrRemovedAgentOffersManageAgents() {
        for text in [
            "Cannot find an executable named “nope”.", "The agent of this session is no longer configured.",
            "The version of Mock this session used is no longer installed. Install it again in Settings → Agents, or start a new session.",
        ] {
            #expect(SessionFailure(text).actions == [.manageAgents] && SessionFailure(text).details == nil)
        }
    }

    @Test func aSessionThatCannotContinueOffersANewSession() {
        for text in [
            "Mock cannot continue saved sessions.", "Merged into main. The session cannot continue.",
            "The working directory “/tmp/x” no longer exists.",
        ] {
            #expect(SessionFailure(text).actions == [.newSession] && SessionFailure(text).details == nil)
        }
    }

    @Test func unknownTextStaysAsItIs() {
        let other = SessionFailure("Something else")
        #expect(other.summary == "Something else" && other.details == nil && other.actions.isEmpty)
    }
}
