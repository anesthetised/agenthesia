import JSONRPC

/// A session error as a short sentence, what to do about it, and the raw text for Details. Classified from the stored
/// text, like `PromptFailure`, so errors from the agent, the launch and the connection read the same way.
public struct SessionFailure: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case agentLog, newSession, manageAgents }

    public let summary: String
    /// The raw text, when the summary replaces it.
    public let details: String?
    public let actions: [Action]

    public init(_ stored: String) {
        let message = PromptFailure.summary(stored)
        let summary: String
        let actions: [Action]
        switch stored {
        case _
        where stored.hasPrefix("RPCError(code: \(RPCError.resourceNotFoundCode),") && message == "Unknown session":
            (summary, actions) = ("The agent no longer has this session.", [.newSession])
        case _ where stored.hasPrefix("RPCError(code: \(RPCError.authRequiredCode),"):
            (summary, actions) = ("The agent needs you to sign in.", [])
        case _ where message != stored:
            (summary, actions) = (message, [.agentLog])
        case "closed":
            (summary, actions) = ("The connection to the agent closed.", [.agentLog])
        case _ where stored.hasPrefix("The agent exited") || stored.hasPrefix("The agent killed"):
            (summary, actions) = (stored, [.agentLog])
        case _
        where stored.hasPrefix("Cannot find an executable") || stored.hasSuffix("is no longer configured.")
            || stored.contains("is no longer installed."):
            (summary, actions) = (stored, [.manageAgents])
        case _
        where stored.hasSuffix("cannot continue saved sessions.") || stored.hasSuffix("session cannot continue.")
            || stored.hasSuffix("no longer exists."):
            (summary, actions) = (stored, [.newSession])
        default:
            (summary, actions) = (stored, [])
        }
        self.summary = summary
        self.actions = actions
        self.details = summary == stored ? nil : stored
    }
}
