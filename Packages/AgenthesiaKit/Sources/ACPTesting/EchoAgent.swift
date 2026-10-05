public import ACP
public import JSONRPC

/// A reactive ACP agent for tests and manual runs. It echoes prompts and understands a few commands:
///
/// - `read <path>` reads a file through `fs/read_text_file` and echoes it.
/// - `write <path> <text>` asks for permission, then writes through `fs/write_text_file`.
/// - `plan` reports a plan, `think` reports a thought.
/// - `slow` streams slowly, so the turn can be cancelled.
/// - `fail` fails the turn with an internal error.
public final class EchoAgent: Sendable {
    public struct Options: Sendable {
        public var loadSession = true
        public var resumeSession = true
        public var listSessions = true
        public var closeSession = true
        public var deleteSession = true
        /// Whether `session/new` fails with `-32000` until `authenticate` succeeds.
        public var requiresAuthentication = false
        /// Whether sessions expose legacy session modes.
        public var modes = true
        /// Whether sessions expose a model config option.
        public var configOptions = true
        /// Delay between streamed chunks.
        public var chunkDelay: Duration = .zero

        public init() {}
    }

    private let options: Options
    private let state = State()

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Serves the agent side of `transport` until it closes.
    public func serve(_ transport: some MessageTransport) async {
        let connection = Connection(transport: transport)
        await connection.start(handler: router(connection))
        await connection.waitUntilClosed()
    }

    // MARK: - Handlers

    typealias M = ACP.V1.Method

    private func router(_ connection: Connection) -> Router {
        var router = Router()
        let options = options
        let state = state

        router.on(M.Initialize.self) { request in
            await state.setClientCapabilities(request.clientCapabilities ?? .init())
            var authMethods: [ACP.AuthMethod] = [.agent(.init(id: "mock-login", name: "Mock login"))]
            if request.clientCapabilities?.auth?.terminal == true {
                authMethods.append(
                    .terminal(.init(id: "mock-terminal", name: "Mock terminal login", args: ["--login"]))
                )
            }
            return .init(
                protocolVersion: ACP.V1.protocolVersion,
                agentCapabilities: .init(
                    loadSession: options.loadSession,
                    promptCapabilities: .init(image: true, audio: false, embeddedContext: true),
                    mcpCapabilities: .init(http: true, sse: false),
                    sessionCapabilities: .init(
                        list: options.listSessions ? .init() : nil,
                        delete: options.deleteSession ? .init() : nil,
                        resume: options.resumeSession ? .init() : nil,
                        close: options.closeSession ? .init() : nil
                    ),
                    auth: .init(logout: .init())
                ),
                authMethods: authMethods,
                agentInfo: .init(name: "echo-agent", title: "Echo Agent", version: "1.0.0")
            )
        }

        router.on(M.Authenticate.self) { request in
            guard request.methodId == "mock-login" else {
                throw RPCError.invalidParams("Unknown auth method \(request.methodId)")
            }
            await state.setAuthenticated(true)
            return .init()
        }

        router.on(M.Logout.self) { _ in
            await state.setAuthenticated(false)
            return .init()
        }

        router.on(M.NewSession.self) { request in
            if options.requiresAuthentication, await !state.isAuthenticated {
                throw RPCError(code: RPCError.authRequiredCode, message: "Authentication required")
            }
            let id = await state.createSession(cwd: request.cwd)
            return .init(
                sessionId: id,
                modes: options.modes ? Self.modes(current: "ask") : nil,
                configOptions: options.configOptions ? Self.configOptions(model: "small") : nil
            )
        }

        router.on(M.LoadSession.self) { request in
            guard options.loadSession else { throw RPCError.methodNotFound(M.LoadSession.method) }
            guard let history = await state.history(of: request.sessionId) else {
                throw RPCError(code: RPCError.resourceNotFoundCode, message: "Unknown session")
            }
            for update in history {
                try? await connection.notify(M.SessionUpdate.self, .init(sessionId: request.sessionId, update: update))
            }
            return .init(
                modes: options.modes ? Self.modes(current: "ask") : nil,
                configOptions: options.configOptions ? Self.configOptions(model: "small") : nil
            )
        }

        router.on(M.ResumeSession.self) { request in
            guard options.resumeSession else { throw RPCError.methodNotFound(M.ResumeSession.method) }
            guard await state.history(of: request.sessionId) != nil else {
                throw RPCError(code: RPCError.resourceNotFoundCode, message: "Unknown session")
            }
            return .init(
                modes: options.modes ? Self.modes(current: "ask") : nil,
                configOptions: options.configOptions ? Self.configOptions(model: "small") : nil
            )
        }

        router.on(M.ListSessions.self) { request in
            guard options.listSessions else { throw RPCError.methodNotFound(M.ListSessions.method) }
            return .init(sessions: await state.sessions(cwd: request.cwd))
        }

        router.on(M.CloseSession.self) { _ in .init() }

        router.on(M.DeleteSession.self) { request in
            await state.deleteSession(request.sessionId)
            return .init()
        }

        router.on(M.SetMode.self) { request in
            try? await connection.notify(
                M.SessionUpdate.self,
                .init(sessionId: request.sessionId, update: .currentMode(.init(currentModeId: request.modeId)))
            )
            return .init()
        }

        router.on(M.SetConfigOption.self) { request in
            guard request.configId == "model", case .select(let model) = request.value else {
                throw RPCError.invalidParams("Unknown config option \(request.configId)")
            }
            return .init(configOptions: Self.configOptions(model: model))
        }

        router.on(M.Cancel.self) { request in
            await state.cancel(request.sessionId)
        }

        router.on(M.Prompt.self) { request in
            try await Turn(request: request, connection: connection, state: state, options: options).run()
        }

        return router
    }

    static func modes(current: String) -> ACP.V1.SessionModeState {
        .init(
            currentModeId: current,
            availableModes: [.init(id: "ask", name: "Ask"), .init(id: "code", name: "Code")]
        )
    }

    static func configOptions(model: String) -> [ACP.ConfigOption] {
        [
            .init(
                id: "model",
                name: "Model",
                category: .model,
                value: .select(
                    currentValue: model,
                    options: .flat([.init(value: "small", name: "Small"), .init(value: "large", name: "Large")])
                )
            )
        ]
    }
}

// MARK: - State

extension EchoAgent {
    actor State {
        private var clientCapabilities = ACP.V1.ClientCapabilities()
        private(set) var isAuthenticated = false
        private var sessions: [(id: ACP.SessionID, cwd: String, history: [ACP.SessionUpdate])] = []
        private var cancelled: Set<ACP.SessionID> = []
        private var nextSession = 1

        var capabilities: ACP.V1.ClientCapabilities { clientCapabilities }

        func setClientCapabilities(_ capabilities: ACP.V1.ClientCapabilities) {
            clientCapabilities = capabilities
        }

        func setAuthenticated(_ value: Bool) {
            isAuthenticated = value
        }

        func createSession(cwd: String) -> ACP.SessionID {
            let id = "session-\(nextSession)"
            nextSession += 1
            sessions.append((id, cwd, []))
            return id
        }

        func deleteSession(_ id: ACP.SessionID) {
            sessions.removeAll { $0.id == id }
        }

        func history(of id: ACP.SessionID) -> [ACP.SessionUpdate]? {
            sessions.first { $0.id == id }?.history
        }

        func record(_ update: ACP.SessionUpdate, in id: ACP.SessionID) {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[index].history.append(update)
        }

        func sessions(cwd: String?) -> [ACP.SessionInfo] {
            sessions.filter { cwd == nil || $0.cwd == cwd }.map { .init(sessionId: $0.id, cwd: $0.cwd, title: "Echo") }
        }

        func cancel(_ id: ACP.SessionID) {
            cancelled.insert(id)
        }

        /// Returns whether the session was cancelled, and clears the flag.
        func takeCancellation(_ id: ACP.SessionID) -> Bool {
            cancelled.remove(id) != nil
        }

        func isCancelled(_ id: ACP.SessionID) -> Bool {
            cancelled.contains(id)
        }
    }
}

// MARK: - Turn

extension EchoAgent {
    /// One prompt turn.
    struct Turn {
        let request: ACP.V1.PromptRequest
        let connection: Connection
        let state: State
        let options: Options

        var sessionID: ACP.SessionID { request.sessionId }

        func run() async throws -> ACP.V1.PromptResponse {
            _ = await state.takeCancellation(sessionID)
            let text = request.prompt.compactMap { block -> String? in
                if case .text(let content) = block { content.text } else { nil }
            }.joined(separator: " ")
            await state.record(.userMessageChunk(.init(content: .init(text: text))), in: sessionID)

            let words = text.split(separator: " ", maxSplits: 2).map(String.init)
            switch words.first {
            case "read" where words.count >= 2:
                try await read(path: words[1])
            case "write" where words.count >= 3:
                if try await write(path: words[1], content: words[2]) == .cancelled {
                    return .init(stopReason: .cancelled)
                }
            case "plan":
                await send(
                    .plan(
                        .init(entries: [
                            .init(content: "Understand the request", priority: .high, status: .completed),
                            .init(content: "Echo it back", priority: .medium, status: .inProgress),
                        ])
                    )
                )
            case "think":
                await send(.agentThoughtChunk(.init(content: .init(text: "Thinking about \(text)"))))
            case "fail":
                throw RPCError.internalError("Echo agent failed on purpose")
            default:
                break
            }

            let chunks = words.first == "slow" ? Array(repeating: "…", count: 50) : ["Echo: ", text]
            let delay = words.first == "slow" ? .milliseconds(100) : options.chunkDelay
            for chunk in chunks {
                if await state.takeCancellation(sessionID) {
                    return .init(stopReason: .cancelled)
                }
                await send(.agentMessageChunk(.init(content: .init(text: chunk))))
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                }
            }
            if await state.takeCancellation(sessionID) {
                return .init(stopReason: .cancelled)
            }
            return .init(stopReason: .endTurn)
        }

        private func send(_ update: ACP.SessionUpdate) async {
            await state.record(update, in: sessionID)
            try? await connection.notify(ACP.V1.Method.SessionUpdate.self, .init(sessionId: sessionID, update: update))
        }

        private func read(path: String) async throws {
            let id = "read-\(path)"
            await send(
                .toolCall(
                    .init(
                        toolCallId: id,
                        title: "Read \(path)",
                        kind: .read,
                        status: .inProgress,
                        locations: [.init(path: path)]
                    )
                )
            )
            guard await state.capabilities.fs?.readTextFile == true else {
                await send(.toolCallUpdate(.init(toolCallId: id, status: .failed)))
                return
            }
            do {
                let result = try await connection.request(
                    ACP.V1.Method.ReadTextFile.self,
                    .init(sessionId: sessionID, path: path)
                )
                await send(
                    .toolCallUpdate(
                        .init(
                            toolCallId: id,
                            status: .completed,
                            content: [.content(.init(content: .init(text: result.content)))]
                        )
                    )
                )
            } catch {
                await send(.toolCallUpdate(.init(toolCallId: id, status: .failed)))
            }
        }

        private func write(path: String, content: String) async throws -> ACP.PermissionOutcome {
            let id = "write-\(path)"
            let diff = ACP.ToolCallContent.diff(.init(path: path, oldText: nil, newText: content))
            await send(
                .toolCall(.init(toolCallId: id, title: "Write \(path)", kind: .edit, status: .pending, content: [diff]))
            )
            let response = try await connection.request(
                ACP.V1.Method.RequestPermission.self,
                .init(
                    sessionId: sessionID,
                    toolCall: .init(toolCallId: id),
                    options: [
                        .init(optionId: "allow", name: "Allow", kind: .allowOnce),
                        .init(optionId: "reject", name: "Reject", kind: .rejectOnce),
                    ]
                )
            )
            switch response.outcome {
            case .selected("allow"):
                let writable = await state.capabilities.fs?.writeTextFile == true
                let written: Bool
                if writable {
                    written =
                        (try? await connection.request(
                            ACP.V1.Method.WriteTextFile.self,
                            .init(sessionId: sessionID, path: path, content: content)
                        )) != nil
                } else {
                    written = false
                }
                await send(.toolCallUpdate(.init(toolCallId: id, status: written ? .completed : .failed)))
            case .cancelled:
                await send(.toolCallUpdate(.init(toolCallId: id, status: .failed)))
            default:
                await send(.toolCallUpdate(.init(toolCallId: id, status: .failed)))
            }
            return response.outcome
        }
    }
}
