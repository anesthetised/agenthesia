public import JSONRPC

extension ACP.V1 {
    /// Implements the version-agnostic `AgentConnection` on top of ACP v1.
    ///
    /// Everything v1-only stays here: `fs/*` and `terminal/*` are served by the injected providers, session
    /// modes are exposed as a config option with category `mode`, and `session/load` replays are suppressed.
    public final class AgentConnectionAdapter: ACP.AgentConnection {
        public struct Options: Sendable {
            /// Whether the client can run terminal auth methods.
            public var terminalAuth = false
            /// Whether the client renders elicitation forms.
            public var elicitation = true

            public init(terminalAuth: Bool = false, elicitation: Bool = true) {
                self.terminalAuth = terminalAuth
                self.elicitation = elicitation
            }
        }

        /// The id of the config option that represents ACP v1 session modes.
        public static let modeOptionID: ACP.ConfigOptionID = "agenthesia.session-mode"

        private let client: Client
        private let state: State
        private let fileSystem: (any ACP.FileSystemProvider)?
        private let terminals: (any ACP.TerminalProvider)?
        private let options: Options

        public init(
            transport: some MessageTransport,
            delegate: some ACP.AgentConnectionDelegate,
            fileSystem: (any ACP.FileSystemProvider)? = nil,
            terminals: (any ACP.TerminalProvider)? = nil,
            options: Options = Options(),
            traffic: Connection.TrafficObserver? = nil
        ) async {
            let state = State()
            self.state = state
            self.fileSystem = fileSystem
            self.terminals = terminals
            self.options = options
            let bridge = Bridge(
                state: state,
                delegate: delegate,
                fileSystem: fileSystem,
                terminals: terminals,
                elicitation: options.elicitation
            )
            client = await Client(transport: transport, delegate: bridge, traffic: traffic)
        }

        public func initialize(client info: ACP.Implementation) async throws -> ACP.AgentProfile {
            let response = try await client.initialize(capabilities: capabilities, info: info)
            let agent = response.agentCapabilities ?? .init()
            let sessions = agent.sessionCapabilities
            let profile = ACP.AgentProfile(
                protocolVersion: response.protocolVersion,
                info: response.agentInfo,
                authMethods: response.authMethods ?? [],
                canLoadSessions: agent.loadSession ?? false,
                canResumeSessions: sessions?.resume != nil,
                canListSessions: sessions?.list != nil,
                canCloseSessions: sessions?.close != nil,
                canDeleteSessions: sessions?.delete != nil,
                acceptsAdditionalDirectories: sessions?.additionalDirectories != nil,
                canLogout: agent.auth?.logout != nil,
                acceptsImages: agent.promptCapabilities?.image ?? false,
                acceptsAudio: agent.promptCapabilities?.audio ?? false,
                acceptsEmbeddedContext: agent.promptCapabilities?.embeddedContext ?? false,
                acceptsHTTPMCPServers: agent.mcpCapabilities?.http ?? false,
                acceptsSSEMCPServers: agent.mcpCapabilities?.sse ?? false,
                steering: .interruptAndSend
            )
            await state.setProfile(profile)
            return profile
        }

        /// The capabilities this client advertises, derived from the injected providers and options.
        public var capabilities: ClientCapabilities {
            ClientCapabilities(
                fs: fileSystem.map { _ in FileSystemCapabilities(readTextFile: true, writeTextFile: true) },
                terminal: terminals != nil,
                session: .init(configOptions: .init(boolean: .init())),
                auth: .init(terminal: options.terminalAuth),
                elicitation: options.elicitation ? .init(form: .init()) : nil
            )
        }

        public func authenticate(methodId: ACP.AuthMethodID) async throws {
            try await client.authenticate(methodId: methodId)
        }

        public func logout() async throws {
            try await client.logout()
        }

        public func newSession(
            cwd: String,
            additionalDirectories: [String],
            mcpServers: [ACP.MCPServer]
        ) async throws -> ACP.SessionState {
            let response = try await client.newSession(
                .init(cwd: cwd, additionalDirectories: additionalDirectories.nilIfEmpty, mcpServers: mcpServers)
            )
            let options = await state.register(
                response.sessionId,
                modes: response.modes,
                options: response.configOptions
            )
            return .init(sessionId: response.sessionId, configOptions: options)
        }

        public func reopenSession(
            _ sessionId: ACP.SessionID,
            cwd: String,
            additionalDirectories: [String],
            mcpServers: [ACP.MCPServer]
        ) async throws -> ACP.ReopenedSession {
            let profile = await state.profile
            if profile?.canResumeSessions == true {
                let response = try await client.resumeSession(
                    .init(
                        sessionId: sessionId,
                        cwd: cwd,
                        additionalDirectories: additionalDirectories.nilIfEmpty,
                        mcpServers: mcpServers
                    )
                )
                let options = await state.register(sessionId, modes: response.modes, options: response.configOptions)
                return .resumed(.init(sessionId: sessionId, configOptions: options))
            }
            if profile?.canLoadSessions == true {
                await state.suppress(sessionId, true)
                let response: SessionStateResponse
                do {
                    response = try await client.loadSession(
                        .init(
                            sessionId: sessionId,
                            cwd: cwd,
                            additionalDirectories: additionalDirectories.nilIfEmpty,
                            mcpServers: mcpServers
                        )
                    )
                } catch {
                    await state.suppress(sessionId, false)
                    throw error
                }
                await state.suppress(sessionId, false)
                let options = await state.register(sessionId, modes: response.modes, options: response.configOptions)
                return .loaded(.init(sessionId: sessionId, configOptions: options))
            }
            return .unavailable
        }

        public func listSessions(cwd: String?) async throws -> [ACP.SessionInfo] {
            var sessions: [ACP.SessionInfo] = []
            var cursor: String?
            repeat {
                let page = try await client.listSessions(.init(cwd: cwd, cursor: cursor))
                sessions += page.sessions
                cursor = page.nextCursor
            } while cursor != nil
            return sessions
        }

        public func closeSession(_ sessionId: ACP.SessionID) async throws {
            try await client.closeSession(sessionId)
            await state.forget(sessionId)
        }

        public func deleteSession(_ sessionId: ACP.SessionID) async throws {
            try await client.deleteSession(sessionId)
            await state.forget(sessionId)
        }

        public func prompt(_ content: [ACP.ContentBlock], in sessionId: ACP.SessionID) async throws -> ACP.StopReason {
            try await client.prompt(content, in: sessionId).stopReason
        }

        public func cancel(_ sessionId: ACP.SessionID) async throws {
            try await client.cancel(sessionId)
        }

        public func setConfigOption(
            _ configId: ACP.ConfigOptionID,
            to value: ACP.ConfigValue,
            in sessionId: ACP.SessionID
        ) async throws -> [ACP.ConfigOption] {
            if configId == Self.modeOptionID {
                guard case .select(let modeId) = value else {
                    throw RPCError.invalidParams("The session mode takes a select value")
                }
                try await client.setMode(modeId, in: sessionId)
                return await state.setCurrentMode(modeId, in: sessionId)
            }
            let options = try await client.setConfigOption(configId, to: value, in: sessionId)
            return await state.setAgentOptions(options, in: sessionId)
        }

        public func close() async {
            await client.close()
        }
    }
}

extension Array {
    fileprivate var nilIfEmpty: Self? { isEmpty ? nil : self }
}

// MARK: - Session state

extension ACP.V1.AgentConnectionAdapter {
    actor State {
        private struct Session {
            var modes: ACP.V1.SessionModeState?
            var agentOptions: [ACP.ConfigOption]

            /// The agent's options plus a synthesized mode option, unless the agent already has one.
            var effectiveOptions: [ACP.ConfigOption] {
                guard let modes, !agentOptions.contains(where: { $0.category == .mode }) else {
                    return agentOptions
                }
                let mode = ACP.ConfigOption(
                    id: ACP.V1.AgentConnectionAdapter.modeOptionID,
                    name: "Mode",
                    category: .mode,
                    value: .select(
                        currentValue: modes.currentModeId,
                        options: .flat(
                            modes.availableModes.map { .init(value: $0.id, name: $0.name, description: $0.description) }
                        )
                    )
                )
                return [mode] + agentOptions
            }
        }

        private(set) var profile: ACP.AgentProfile?
        private var sessions: [ACP.SessionID: Session] = [:]
        private var suppressed: Set<ACP.SessionID> = []

        func setProfile(_ profile: ACP.AgentProfile) {
            self.profile = profile
        }

        func register(
            _ sessionId: ACP.SessionID,
            modes: ACP.V1.SessionModeState?,
            options: [ACP.ConfigOption]?
        ) -> [ACP.ConfigOption] {
            let session = Session(modes: modes, agentOptions: options ?? [])
            sessions[sessionId] = session
            return session.effectiveOptions
        }

        func forget(_ sessionId: ACP.SessionID) {
            sessions[sessionId] = nil
        }

        func suppress(_ sessionId: ACP.SessionID, _ suppress: Bool) {
            if suppress {
                suppressed.insert(sessionId)
            } else {
                suppressed.remove(sessionId)
            }
        }

        func isSuppressed(_ sessionId: ACP.SessionID) -> Bool {
            suppressed.contains(sessionId)
        }

        func setAgentOptions(_ options: [ACP.ConfigOption], in sessionId: ACP.SessionID) -> [ACP.ConfigOption] {
            sessions[sessionId, default: Session(agentOptions: [])].agentOptions = options
            return sessions[sessionId]?.effectiveOptions ?? options
        }

        func setCurrentMode(_ modeId: ACP.SessionModeID, in sessionId: ACP.SessionID) -> [ACP.ConfigOption] {
            sessions[sessionId]?.modes?.currentModeId = modeId
            return sessions[sessionId]?.effectiveOptions ?? []
        }

        /// Whether the session's modes are shown as a synthesized config option.
        func mapsModes(of sessionId: ACP.SessionID) -> Bool {
            sessions[sessionId]?.effectiveOptions.contains { $0.id == ACP.V1.AgentConnectionAdapter.modeOptionID }
                ?? false
        }
    }

    /// Bridges ACP v1 agent requests to the version-agnostic delegate and providers.
    struct Bridge: ACP.V1.ClientDelegate {
        let state: State
        let delegate: any ACP.AgentConnectionDelegate
        let fileSystem: (any ACP.FileSystemProvider)?
        let terminals: (any ACP.TerminalProvider)?
        let elicitation: Bool

        func sessionUpdate(_ notification: ACP.V1.SessionNotification) async {
            let sessionId = notification.sessionId
            guard await !state.isSuppressed(sessionId) else { return }
            switch notification.update {
            case .currentMode(let update) where await state.mapsModes(of: sessionId):
                let options = await state.setCurrentMode(update.currentModeId, in: sessionId)
                await delegate.sessionUpdate(.configOptions(.init(configOptions: options)), in: sessionId)
            case .configOptions(let update):
                let options = await state.setAgentOptions(update.configOptions, in: sessionId)
                await delegate.sessionUpdate(
                    .configOptions(.init(configOptions: options, meta: update.meta)),
                    in: sessionId
                )
            case let update:
                await delegate.sessionUpdate(update, in: sessionId)
            }
        }

        func requestPermission(
            _ request: ACP.V1.RequestPermissionRequest
        ) async throws -> ACP.V1.RequestPermissionResponse {
            .init(
                outcome: await delegate.requestPermission(
                    for: request.toolCall,
                    options: request.options,
                    in: request.sessionId
                )
            )
        }

        func readTextFile(_ request: ACP.V1.ReadTextFileRequest) async throws -> ACP.V1.ReadTextFileResponse {
            guard let fileSystem else { throw RPCError.methodNotFound(ACP.V1.Method.ReadTextFile.method) }
            return .init(
                content: try await fileSystem.readTextFile(
                    at: request.path,
                    line: request.line,
                    limit: request.limit,
                    in: request.sessionId
                )
            )
        }

        func writeTextFile(_ request: ACP.V1.WriteTextFileRequest) async throws -> ACP.V1.EmptyMessage {
            guard let fileSystem else { throw RPCError.methodNotFound(ACP.V1.Method.WriteTextFile.method) }
            try await fileSystem.writeTextFile(at: request.path, content: request.content, in: request.sessionId)
            return .init()
        }

        func createTerminal(_ request: ACP.V1.CreateTerminalRequest) async throws -> ACP.V1.CreateTerminalResponse {
            .init(terminalId: try await requireTerminals(ACP.V1.Method.CreateTerminal.method).createTerminal(request))
        }

        func terminalOutput(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.TerminalOutputResponse {
            try await requireTerminals(ACP.V1.Method.TerminalOutput.method)
                .output(of: request.terminalId, in: request.sessionId)
        }

        func waitForTerminalExit(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.TerminalExitStatus {
            try await requireTerminals(ACP.V1.Method.WaitForTerminalExit.method)
                .waitForExit(of: request.terminalId, in: request.sessionId)
        }

        func killTerminal(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.EmptyMessage {
            try await requireTerminals(ACP.V1.Method.KillTerminal.method).kill(
                request.terminalId,
                in: request.sessionId
            )
            return .init()
        }

        func releaseTerminal(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.EmptyMessage {
            try await requireTerminals(ACP.V1.Method.ReleaseTerminal.method)
                .release(request.terminalId, in: request.sessionId)
            return .init()
        }

        func createElicitation(_ request: ACP.ElicitationRequest) async throws -> ACP.ElicitationResponse {
            guard elicitation else { throw RPCError.methodNotFound(ACP.V1.Method.CreateElicitation.method) }
            return await delegate.requestInput(request)
        }

        func completeElicitation(_ notification: ACP.ElicitationComplete) async {
            await delegate.inputCompleted(notification.elicitationId)
        }

        private func requireTerminals(_ method: String) throws -> any ACP.TerminalProvider {
            guard let terminals else { throw RPCError.methodNotFound(method) }
            return terminals
        }
    }
}
