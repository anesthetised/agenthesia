// Wire types for ACP v1 method parameters and results.

extension ACP.V1 {
    /// Parameters of `initialize`.
    public struct InitializeRequest: Codable, Hashable, Sendable {
        public var protocolVersion: Int
        public var clientCapabilities: ClientCapabilities?
        public var clientInfo: ACP.Implementation?
        public var meta: Meta?

        public init(
            protocolVersion: Int,
            clientCapabilities: ClientCapabilities? = nil,
            clientInfo: ACP.Implementation? = nil,
            meta: Meta? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.clientCapabilities = clientCapabilities
            self.clientInfo = clientInfo
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case protocolVersion, clientCapabilities, clientInfo
            case meta = "_meta"
        }
    }

    /// Result of `initialize`.
    public struct InitializeResponse: Codable, Hashable, Sendable {
        public var protocolVersion: Int
        public var agentCapabilities: AgentCapabilities?
        public var authMethods: [ACP.AuthMethod]?
        public var agentInfo: ACP.Implementation?
        public var meta: Meta?

        public init(
            protocolVersion: Int,
            agentCapabilities: AgentCapabilities? = nil,
            authMethods: [ACP.AuthMethod]? = nil,
            agentInfo: ACP.Implementation? = nil,
            meta: Meta? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.agentCapabilities = agentCapabilities
            self.authMethods = authMethods
            self.agentInfo = agentInfo
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case protocolVersion, agentCapabilities, authMethods, agentInfo
            case meta = "_meta"
        }
    }

    /// Parameters of `authenticate`.
    public struct AuthenticateRequest: Codable, Hashable, Sendable {
        public var methodId: ACP.AuthMethodID
        public var meta: Meta?

        public init(methodId: ACP.AuthMethodID, meta: Meta? = nil) {
            self.methodId = methodId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case methodId
            case meta = "_meta"
        }
    }

    /// Parameters or result that only carry `_meta`.
    public struct EmptyMessage: Codable, Hashable, Sendable {
        public var meta: Meta?

        public init(meta: Meta? = nil) {
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case meta = "_meta"
        }
    }

    /// A session mode (ACP v1).
    public struct SessionMode: Codable, Hashable, Sendable {
        public var id: ACP.SessionModeID
        public var name: String
        public var description: String?
        public var meta: Meta?

        public init(id: ACP.SessionModeID, name: String, description: String? = nil, meta: Meta? = nil) {
            self.id = id
            self.name = name
            self.description = description
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, description
            case meta = "_meta"
        }
    }

    /// The available session modes and the current one (ACP v1).
    public struct SessionModeState: Codable, Hashable, Sendable {
        public var currentModeId: ACP.SessionModeID
        public var availableModes: [SessionMode]
        public var meta: Meta?

        public init(currentModeId: ACP.SessionModeID, availableModes: [SessionMode], meta: Meta? = nil) {
            self.currentModeId = currentModeId
            self.availableModes = availableModes
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case currentModeId, availableModes
            case meta = "_meta"
        }
    }

    /// Parameters of `session/new`.
    public struct NewSessionRequest: Codable, Hashable, Sendable {
        public var cwd: String
        public var additionalDirectories: [String]?
        public var mcpServers: [ACP.MCPServer]
        public var meta: Meta?

        public init(
            cwd: String,
            additionalDirectories: [String]? = nil,
            mcpServers: [ACP.MCPServer],
            meta: Meta? = nil
        ) {
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case cwd, additionalDirectories, mcpServers
            case meta = "_meta"
        }
    }

    /// Result of `session/new`.
    public struct NewSessionResponse: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var modes: SessionModeState?
        public var configOptions: [ACP.ConfigOption]?
        public var meta: Meta?

        public init(
            sessionId: ACP.SessionID,
            modes: SessionModeState? = nil,
            configOptions: [ACP.ConfigOption]? = nil,
            meta: Meta? = nil
        ) {
            self.sessionId = sessionId
            self.modes = modes
            self.configOptions = configOptions
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, modes, configOptions
            case meta = "_meta"
        }
    }

    /// Parameters of `session/load`.
    public struct LoadSessionRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var cwd: String
        public var additionalDirectories: [String]?
        public var mcpServers: [ACP.MCPServer]
        public var meta: Meta?

        public init(
            sessionId: ACP.SessionID,
            cwd: String,
            additionalDirectories: [String]? = nil,
            mcpServers: [ACP.MCPServer],
            meta: Meta? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, cwd, additionalDirectories, mcpServers
            case meta = "_meta"
        }
    }

    /// Parameters of `session/resume`.
    public struct ResumeSessionRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var cwd: String
        public var additionalDirectories: [String]?
        public var mcpServers: [ACP.MCPServer]?
        public var meta: Meta?

        public init(
            sessionId: ACP.SessionID,
            cwd: String,
            additionalDirectories: [String]? = nil,
            mcpServers: [ACP.MCPServer]? = nil,
            meta: Meta? = nil
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.additionalDirectories = additionalDirectories
            self.mcpServers = mcpServers
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, cwd, additionalDirectories, mcpServers
            case meta = "_meta"
        }
    }

    /// Result of `session/load` and `session/resume`.
    public struct SessionStateResponse: Codable, Hashable, Sendable {
        public var modes: SessionModeState?
        public var configOptions: [ACP.ConfigOption]?
        public var meta: Meta?

        public init(
            modes: SessionModeState? = nil,
            configOptions: [ACP.ConfigOption]? = nil,
            meta: Meta? = nil
        ) {
            self.modes = modes
            self.configOptions = configOptions
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case modes, configOptions
            case meta = "_meta"
        }
    }

    /// Parameters of `session/list`.
    public struct ListSessionsRequest: Codable, Hashable, Sendable {
        public var cwd: String?
        public var cursor: String?
        public var meta: Meta?

        public init(cwd: String? = nil, cursor: String? = nil, meta: Meta? = nil) {
            self.cwd = cwd
            self.cursor = cursor
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case cwd, cursor
            case meta = "_meta"
        }
    }

    /// Result of `session/list`.
    public struct ListSessionsResponse: Codable, Hashable, Sendable {
        public var sessions: [ACP.SessionInfo]
        public var nextCursor: String?
        public var meta: Meta?

        public init(sessions: [ACP.SessionInfo], nextCursor: String? = nil, meta: Meta? = nil) {
            self.sessions = sessions
            self.nextCursor = nextCursor
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessions, nextCursor
            case meta = "_meta"
        }
    }

    /// Parameters that only identify a session: `session/delete`, `session/close`, `session/cancel`.
    public struct SessionRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var meta: Meta?

        public init(sessionId: ACP.SessionID, meta: Meta? = nil) {
            self.sessionId = sessionId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId
            case meta = "_meta"
        }
    }

    /// Parameters of `session/set_mode`.
    public struct SetModeRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var modeId: ACP.SessionModeID
        public var meta: Meta?

        public init(sessionId: ACP.SessionID, modeId: ACP.SessionModeID, meta: Meta? = nil) {
            self.sessionId = sessionId
            self.modeId = modeId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, modeId
            case meta = "_meta"
        }
    }

    /// Result of `session/set_config_option`: all options, updated.
    public struct SetConfigOptionResponse: Codable, Hashable, Sendable {
        public var configOptions: [ACP.ConfigOption]
        public var meta: Meta?

        public init(configOptions: [ACP.ConfigOption], meta: Meta? = nil) {
            self.configOptions = configOptions
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case configOptions
            case meta = "_meta"
        }
    }

    /// Parameters of `session/prompt`.
    public struct PromptRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var prompt: [ACP.ContentBlock]
        public var meta: Meta?

        public init(sessionId: ACP.SessionID, prompt: [ACP.ContentBlock], meta: Meta? = nil) {
            self.sessionId = sessionId
            self.prompt = prompt
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, prompt
            case meta = "_meta"
        }
    }

    /// Result of `session/prompt`.
    public struct PromptResponse: Codable, Hashable, Sendable {
        public var stopReason: ACP.StopReason
        public var meta: Meta?

        public init(stopReason: ACP.StopReason, meta: Meta? = nil) {
            self.stopReason = stopReason
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case stopReason
            case meta = "_meta"
        }
    }

    /// Parameters of `session/update`.
    public struct SessionNotification: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var update: ACP.SessionUpdate
        public var meta: Meta?

        public init(sessionId: ACP.SessionID, update: ACP.SessionUpdate, meta: Meta? = nil) {
            self.sessionId = sessionId
            self.update = update
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, update
            case meta = "_meta"
        }
    }

    /// Parameters of `session/request_permission`.
    public struct RequestPermissionRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var toolCall: ACP.ToolCallUpdate
        public var options: [ACP.PermissionOption]
        public var meta: Meta?

        public init(
            sessionId: ACP.SessionID,
            toolCall: ACP.ToolCallUpdate,
            options: [ACP.PermissionOption],
            meta: Meta? = nil
        ) {
            self.sessionId = sessionId
            self.toolCall = toolCall
            self.options = options
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, toolCall, options
            case meta = "_meta"
        }
    }

    /// Result of `session/request_permission`.
    public struct RequestPermissionResponse: Codable, Hashable, Sendable {
        public var outcome: ACP.PermissionOutcome
        public var meta: Meta?

        public init(outcome: ACP.PermissionOutcome, meta: Meta? = nil) {
            self.outcome = outcome
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case outcome
            case meta = "_meta"
        }
    }

    /// Parameters of `fs/read_text_file`. `line` is 1-based.
    public struct ReadTextFileRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var path: String
        public var line: Int?
        public var limit: Int?
        public var meta: Meta?

        public init(
            sessionId: ACP.SessionID,
            path: String,
            line: Int? = nil,
            limit: Int? = nil,
            meta: Meta? = nil
        ) {
            self.sessionId = sessionId
            self.path = path
            self.line = line
            self.limit = limit
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, path, line, limit
            case meta = "_meta"
        }
    }

    /// Result of `fs/read_text_file`.
    public struct ReadTextFileResponse: Codable, Hashable, Sendable {
        public var content: String
        public var meta: Meta?

        public init(content: String, meta: Meta? = nil) {
            self.content = content
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case content
            case meta = "_meta"
        }
    }

    /// Parameters of `fs/write_text_file`.
    public struct WriteTextFileRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var path: String
        public var content: String
        public var meta: Meta?

        public init(sessionId: ACP.SessionID, path: String, content: String, meta: Meta? = nil) {
            self.sessionId = sessionId
            self.path = path
            self.content = content
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, path, content
            case meta = "_meta"
        }
    }

    /// Parameters of `terminal/create`.
    public struct CreateTerminalRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var command: String
        public var args: [String]?
        public var env: [ACP.EnvVariable]?
        public var cwd: String?
        public var outputByteLimit: Int?
        public var meta: Meta?

        public init(
            sessionId: ACP.SessionID,
            command: String,
            args: [String]? = nil,
            env: [ACP.EnvVariable]? = nil,
            cwd: String? = nil,
            outputByteLimit: Int? = nil,
            meta: Meta? = nil
        ) {
            self.sessionId = sessionId
            self.command = command
            self.args = args
            self.env = env
            self.cwd = cwd
            self.outputByteLimit = outputByteLimit
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, command, args, env, cwd, outputByteLimit
            case meta = "_meta"
        }
    }

    /// Result of `terminal/create`.
    public struct CreateTerminalResponse: Codable, Hashable, Sendable {
        public var terminalId: ACP.TerminalID
        public var meta: Meta?

        public init(terminalId: ACP.TerminalID, meta: Meta? = nil) {
            self.terminalId = terminalId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case terminalId
            case meta = "_meta"
        }
    }

    /// Parameters that identify a terminal: `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, `terminal/release`.
    public struct TerminalRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var terminalId: ACP.TerminalID
        public var meta: Meta?

        public init(sessionId: ACP.SessionID, terminalId: ACP.TerminalID, meta: Meta? = nil) {
            self.sessionId = sessionId
            self.terminalId = terminalId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, terminalId
            case meta = "_meta"
        }
    }

    /// How a terminal's process exited. Also the result of `terminal/wait_for_exit`.
    public struct TerminalExitStatus: Codable, Hashable, Sendable {
        public var exitCode: Int?
        public var signal: String?
        public var meta: Meta?

        public init(exitCode: Int? = nil, signal: String? = nil, meta: Meta? = nil) {
            self.exitCode = exitCode
            self.signal = signal
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case exitCode, signal
            case meta = "_meta"
        }
    }

    /// Result of `terminal/output`.
    public struct TerminalOutputResponse: Codable, Hashable, Sendable {
        public var output: String
        public var truncated: Bool
        public var exitStatus: TerminalExitStatus?
        public var meta: Meta?

        public init(output: String, truncated: Bool, exitStatus: TerminalExitStatus? = nil, meta: Meta? = nil) {
            self.output = output
            self.truncated = truncated
            self.exitStatus = exitStatus
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case output, truncated, exitStatus
            case meta = "_meta"
        }
    }
}

extension ACP.V1 {
    /// Parameters of `session/set_config_option`.
    public struct SetConfigOptionRequest: Codable, Hashable, Sendable {
        public var sessionId: ACP.SessionID
        public var configId: ACP.ConfigOptionID
        public var value: ACP.ConfigValue
        public var meta: Meta?

        public init(sessionId: ACP.SessionID, configId: ACP.ConfigOptionID, value: ACP.ConfigValue, meta: Meta? = nil) {
            self.sessionId = sessionId
            self.configId = configId
            self.value = value
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId, configId, value, type
            case meta = "_meta"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            configId = try container.decode(String.self, forKey: .configId)
            meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
            if try container.decodeIfPresent(String.self, forKey: .type) == "boolean" {
                value = .boolean(try container.decode(Bool.self, forKey: .value))
            } else {
                value = .select(try container.decode(String.self, forKey: .value))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(configId, forKey: .configId)
            try container.encodeIfPresent(meta, forKey: .meta)
            switch value {
            case .select(let value):
                try container.encode(value, forKey: .value)
            case .boolean(let value):
                try container.encode("boolean", forKey: .type)
                try container.encode(value, forKey: .value)
            }
        }
    }
}
