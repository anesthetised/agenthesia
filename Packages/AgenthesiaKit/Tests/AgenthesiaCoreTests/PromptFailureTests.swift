import JSONRPC
import Testing

@testable import AgenthesiaCore

struct PromptFailureTests {
    @Test func extractsTheMessageOfARealStoredDescription() {
        let error = RPCError(code: -32603, message: "Internal error: model overloaded", data: .string("retry"))
        let stored = String(describing: error)
        #expect(stored.hasPrefix("RPCError(code: -32603, message: \""))
        #expect(PromptFailure.summary(stored) == "Internal error: model overloaded")
        #expect(PromptFailure.summary(String(describing: RPCError.internalError())) == "Internal error")
    }

    @Test func unescapesQuotesBackslashesNewlinesAndUnicode() {
        let message = "Unknown model \"gpt-9\"\nPath C:\\tmp\\x\ttab 🌍 é"
        let stored = String(describing: RPCError(code: -32602, message: message, data: .object(["a": .string("\"}")])))
        #expect(PromptFailure.summary(stored) == message)
        #expect(
            PromptFailure.summary(#"RPCError(code: 1, message: "snow \u{2603} \u{1F600}", data: nil)"#) == "snow ☃ 😀"
        )
    }

    @Test func leavesOtherTextUnchanged() {
        for text in [
            "", "Interrupted: Agenthesia stopped during this turn.", "The connection closed", "RPCError(code: 1)",
            #"RPCError(code: 1, message: "unterminated"#, #"RPCError(code: 1, message: "bad \u{zz}", data: nil)"#,
            #"RPCError(code: 1, message: "bad \u{110000}", data: nil)"#,
            #"RPCError(code: 1, message: "bad \u2603", data: nil)"#,
            #"RPCError(code: 1, message: "trailing \"#,
        ] {
            #expect(PromptFailure.summary(text) == text)
        }
    }
}
