public import Foundation

extension ACP {
    /// How a message reaches an agent that is in the middle of a turn (ADR-0010).
    public enum SteeringStrategy: Sendable, Hashable {
        /// Cancel the running turn, then send the message as a new prompt.
        case interruptAndSend
        /// Insert the message into the running turn without interrupting it.
        case inject
    }

    /// What the client learned about an agent during initialization.
    public struct AgentProfile: Sendable, Hashable {
        public var protocolVersion: Int
        public var info: Implementation?
        public var authMethods: [AuthMethod]
        public var canLoadSessions: Bool
        public var canResumeSessions: Bool
        public var canListSessions: Bool
        public var canCloseSessions: Bool
        public var canDeleteSessions: Bool
        public var acceptsAdditionalDirectories: Bool
        public var canLogout: Bool
        public var acceptsImages: Bool
        public var acceptsAudio: Bool
        public var acceptsEmbeddedContext: Bool
        public var acceptsHTTPMCPServers: Bool
        public var acceptsSSEMCPServers: Bool
        public var steering: SteeringStrategy

        public init(
            protocolVersion: Int,
            info: Implementation? = nil,
            authMethods: [AuthMethod] = [],
            canLoadSessions: Bool = false,
            canResumeSessions: Bool = false,
            canListSessions: Bool = false,
            canCloseSessions: Bool = false,
            canDeleteSessions: Bool = false,
            acceptsAdditionalDirectories: Bool = false,
            canLogout: Bool = false,
            acceptsImages: Bool = false,
            acceptsAudio: Bool = false,
            acceptsEmbeddedContext: Bool = false,
            acceptsHTTPMCPServers: Bool = false,
            acceptsSSEMCPServers: Bool = false,
            steering: SteeringStrategy = .interruptAndSend
        ) {
            self.protocolVersion = protocolVersion
            self.info = info
            self.authMethods = authMethods
            self.canLoadSessions = canLoadSessions
            self.canResumeSessions = canResumeSessions
            self.canListSessions = canListSessions
            self.canCloseSessions = canCloseSessions
            self.canDeleteSessions = canDeleteSessions
            self.acceptsAdditionalDirectories = acceptsAdditionalDirectories
            self.canLogout = canLogout
            self.acceptsImages = acceptsImages
            self.acceptsAudio = acceptsAudio
            self.acceptsEmbeddedContext = acceptsEmbeddedContext
            self.acceptsHTTPMCPServers = acceptsHTTPMCPServers
            self.acceptsSSEMCPServers = acceptsSSEMCPServers
            self.steering = steering
        }
    }

    /// A session as seen right after creating or reopening it.
    public struct SessionState: Sendable, Hashable {
        public var sessionId: SessionID
        /// The session's settings, including the session mode when the agent uses ACP v1 modes.
        public var configOptions: [ConfigOption]

        public init(sessionId: SessionID, configOptions: [ConfigOption]) {
            self.sessionId = sessionId
            self.configOptions = configOptions
        }
    }

    /// The result of reopening an existing session.
    public enum ReopenedSession: Sendable, Hashable {
        /// Reattached without replaying history.
        case resumed(SessionState)
        /// Reloaded; the replayed history was not forwarded, the client's own log is authoritative.
        case loaded(SessionState)
        /// The agent can neither resume nor load sessions: the session is read-only.
        case unavailable
    }

    /// A connection to an agent, independent of the ACP version (ADR-0003).
    ///
    /// It covers the methods ACP v1 and v2 share. Everything version-specific lives in the adapters.
    public protocol AgentConnection: Sendable {
        func initialize(client: Implementation) async throws -> AgentProfile
        func authenticate(methodId: AuthMethodID) async throws
        func logout() async throws
        func newSession(
            cwd: String,
            additionalDirectories: [String],
            mcpServers: [MCPServer]
        ) async throws -> SessionState
        /// Reattaches to an existing session: resumes it if possible, otherwise loads it.
        func reopenSession(
            _ sessionId: SessionID,
            cwd: String,
            additionalDirectories: [String],
            mcpServers: [MCPServer]
        ) async throws -> ReopenedSession
        /// All sessions, following pagination.
        func listSessions(cwd: String?) async throws -> [SessionInfo]
        func closeSession(_ sessionId: SessionID) async throws
        func deleteSession(_ sessionId: SessionID) async throws
        /// Runs a prompt turn and returns why it ended.
        func prompt(_ content: [ContentBlock], in sessionId: SessionID) async throws -> StopReason
        func cancel(_ sessionId: SessionID) async throws
        /// Changes a setting and returns all settings of the session.
        func setConfigOption(
            _ configId: ConfigOptionID,
            to value: ConfigValue,
            in sessionId: SessionID
        ) async throws -> [ConfigOption]
        func close() async
    }

    /// Receives what an agent sends or asks for, independent of the ACP version.
    public protocol AgentConnectionDelegate: Sendable {
        func sessionUpdate(_ update: SessionUpdate, in sessionId: SessionID) async
        /// `update` is normalized by the adapter; `rawNotification` is the unchanged wire notification.
        func sessionUpdate(_ update: SessionUpdate, in sessionId: SessionID, rawNotification: Data) async
        /// Asks the user to approve a tool call. Return `.cancelled` if the turn was cancelled meanwhile.
        func requestPermission(
            for toolCall: ToolCallUpdate,
            options: [PermissionOption],
            in sessionId: SessionID
        ) async -> PermissionOutcome
        /// Asks the user for structured input.
        func requestInput(_ request: ElicitationRequest) async -> ElicitationResponse
        /// A URL elicitation finished.
        func inputCompleted(_ elicitationId: ElicitationID) async
    }

    /// Serves file reads and writes for agents (ACP v1 `fs/*`).
    public protocol FileSystemProvider: Sendable {
        /// Reads a text file. `line` is 1-based; `limit` is a number of lines.
        func readTextFile(at path: String, line: Int?, limit: Int?, in sessionId: SessionID) async throws -> String
        func writeTextFile(at path: String, content: String, in sessionId: SessionID) async throws
    }

    /// Runs commands for agents (ACP v1 `terminal/*`).
    public protocol TerminalProvider: Sendable {
        func createTerminal(_ request: V1.CreateTerminalRequest) async throws -> TerminalID
        func output(of terminalId: TerminalID, in sessionId: SessionID) async throws -> V1.TerminalOutputResponse
        func waitForExit(of terminalId: TerminalID, in sessionId: SessionID) async throws -> V1.TerminalExitStatus
        func kill(_ terminalId: TerminalID, in sessionId: SessionID) async throws
        func release(_ terminalId: TerminalID, in sessionId: SessionID) async throws
    }
}

extension ACP.AgentConnectionDelegate {
    public func sessionUpdate(
        _ update: ACP.SessionUpdate,
        in sessionId: ACP.SessionID,
        rawNotification: Data
    ) async {
        await sessionUpdate(update, in: sessionId)
    }

    public func requestInput(_ request: ACP.ElicitationRequest) async -> ACP.ElicitationResponse {
        .init(action: .decline)
    }

    public func inputCompleted(_ elicitationId: ACP.ElicitationID) async {}
}
