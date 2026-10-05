public import JSONRPC

extension ACP.V1 {
    public enum ClientError: Error, Equatable, Sendable {
        /// The agent answered `initialize` with a protocol version this client does not speak.
        case unsupportedProtocolVersion(Int)
    }

    /// A typed ACP v1 client over a JSON-RPC connection to an agent.
    public final class Client: Sendable {
        public let connection: Connection

        /// Connects to the agent on `transport`. Requests from the agent go to `delegate`.
        public init(
            transport: some MessageTransport,
            delegate: some ClientDelegate,
            traffic: Connection.TrafficObserver? = nil
        ) async {
            connection = Connection(transport: transport, traffic: traffic)
            await connection.start(handler: ACP.V1.router(for: delegate))
        }

        /// Negotiates the protocol version and exchanges capabilities.
        ///
        /// Throws `ClientError.unsupportedProtocolVersion` if the agent does not speak ACP v1.
        public func initialize(
            capabilities: ClientCapabilities,
            info: ACP.Implementation? = nil
        ) async throws -> InitializeResponse {
            let response = try await connection.request(
                Method.Initialize.self,
                .init(protocolVersion: protocolVersion, clientCapabilities: capabilities, clientInfo: info)
            )
            guard response.protocolVersion == protocolVersion else {
                throw ClientError.unsupportedProtocolVersion(response.protocolVersion)
            }
            return response
        }

        public func authenticate(methodId: ACP.AuthMethodID) async throws {
            _ = try await connection.request(Method.Authenticate.self, .init(methodId: methodId))
        }

        public func logout() async throws {
            _ = try await connection.request(Method.Logout.self, .init())
        }

        public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
            try await connection.request(Method.NewSession.self, request)
        }

        /// Loads a session. The agent replays its history as `session/update` notifications before responding.
        public func loadSession(_ request: LoadSessionRequest) async throws -> SessionStateResponse {
            try await connection.request(Method.LoadSession.self, request)
        }

        public func resumeSession(_ request: ResumeSessionRequest) async throws -> SessionStateResponse {
            try await connection.request(Method.ResumeSession.self, request)
        }

        public func listSessions(_ request: ListSessionsRequest) async throws -> ListSessionsResponse {
            try await connection.request(Method.ListSessions.self, request)
        }

        public func closeSession(_ sessionId: ACP.SessionID) async throws {
            _ = try await connection.request(Method.CloseSession.self, .init(sessionId: sessionId))
        }

        public func deleteSession(_ sessionId: ACP.SessionID) async throws {
            _ = try await connection.request(Method.DeleteSession.self, .init(sessionId: sessionId))
        }

        public func setMode(_ modeId: ACP.SessionModeID, in sessionId: ACP.SessionID) async throws {
            _ = try await connection.request(Method.SetMode.self, .init(sessionId: sessionId, modeId: modeId))
        }

        public func setConfigOption(
            _ configId: ACP.ConfigOptionID,
            to value: ACP.ConfigValue,
            in sessionId: ACP.SessionID
        ) async throws -> [ACP.ConfigOption] {
            try await connection.request(
                Method.SetConfigOption.self,
                .init(sessionId: sessionId, configId: configId, value: value)
            ).configOptions
        }

        /// Runs a prompt turn and returns why it ended.
        public func prompt(_ prompt: [ACP.ContentBlock], in sessionId: ACP.SessionID) async throws -> PromptResponse {
            try await connection.request(Method.Prompt.self, .init(sessionId: sessionId, prompt: prompt))
        }

        /// Asks the agent to stop the current turn. The pending `prompt` then returns `cancelled`.
        public func cancel(_ sessionId: ACP.SessionID) async throws {
            try await connection.notify(Method.Cancel.self, .init(sessionId: sessionId))
        }

        public func close() async {
            await connection.close()
        }

        public func waitUntilClosed() async {
            await connection.waitUntilClosed()
        }
    }
}
