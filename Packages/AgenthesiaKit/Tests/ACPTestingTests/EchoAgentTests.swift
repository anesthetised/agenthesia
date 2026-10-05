import ACP
import ACPTesting
import Foundation
import JSONRPC
import Synchronization
import Testing

/// A client connected to an `EchoAgent`, recording session updates and answering fs and permission requests.
final class EchoClient: Sendable {
    typealias M = ACP.V1.Method

    let connection: Connection
    private let updates = Locked<[ACP.SessionUpdate]>([])
    let files = Locked<[String: String]>(["/a.txt": "hello"])
    let permissionAnswer = Locked<ACP.PermissionOutcome>(.selected("allow"))

    init(options: EchoAgent.Options = .init()) async {
        let (agentSide, clientSide) = InMemoryTransport.pair()
        let agent = EchoAgent(options: options)
        Task { await agent.serve(agentSide) }
        connection = Connection(transport: clientSide)

        var router = Router()
        let updates = updates
        let files = files
        let permissionAnswer = permissionAnswer
        router.on(M.SessionUpdate.self) { notification in updates.withLock { $0.append(notification.update) } }
        router.on(M.ReadTextFile.self) { request in
            guard let content = files.withLock({ $0[request.path] }) else {
                throw RPCError(code: RPCError.resourceNotFoundCode, message: "No such file")
            }
            return .init(content: content)
        }
        router.on(M.WriteTextFile.self) { request in
            files.withLock { $0[request.path] = request.content }
            return .init()
        }
        router.on(M.RequestPermission.self) { _ in .init(outcome: permissionAnswer.withLock { $0 }) }
        await connection.start(handler: router)
    }

    func initialize(fs: Bool = true, terminalAuth: Bool = false) async throws -> ACP.V1.InitializeResponse {
        try await connection.request(
            M.Initialize.self,
            .init(
                protocolVersion: 1,
                clientCapabilities: .init(
                    fs: .init(readTextFile: fs, writeTextFile: fs),
                    auth: .init(terminal: terminalAuth)
                )
            )
        )
    }

    func newSession(cwd: String = "/project") async throws -> ACP.V1.NewSessionResponse {
        try await connection.request(M.NewSession.self, .init(cwd: cwd, mcpServers: []))
    }

    func prompt(_ text: String, in session: ACP.SessionID) async throws -> ACP.StopReason {
        try await connection.request(M.Prompt.self, .init(sessionId: session, prompt: [.init(text: text)])).stopReason
    }

    var receivedUpdates: [ACP.SessionUpdate] { updates.withLock { $0 } }

    var agentText: String {
        receivedUpdates.compactMap { update -> String? in
            if case .agentMessageChunk(let chunk) = update, case .text(let text) = chunk.content {
                text.text
            } else {
                nil
            }
        }.joined()
    }

    func clearUpdates() {
        updates.withLock { $0.removeAll() }
    }
}

@Suite(.timeLimit(.minutes(1))) struct EchoAgentTests {
    @Test func initializesWithCapabilities() async throws {
        var options = EchoAgent.Options()
        options.loadSession = false
        options.listSessions = false
        let client = await EchoClient(options: options)
        let response = try await client.initialize(terminalAuth: true)
        #expect(response.protocolVersion == 1)
        #expect(response.agentCapabilities?.loadSession == false)
        #expect(response.agentCapabilities?.sessionCapabilities?.list == nil)
        #expect(response.agentCapabilities?.sessionCapabilities?.resume != nil)
        #expect(response.authMethods?.map(\.id) == ["mock-login", "mock-terminal"])
        #expect(response.agentInfo?.name == "echo-agent")
    }

    @Test func echoesPrompts() async throws {
        let client = await EchoClient()
        _ = try await client.initialize()
        let session = try await client.newSession()
        #expect(session.modes?.currentModeId == "ask")
        #expect(session.configOptions?.first?.id == "model")
        #expect(try await client.prompt("hello world", in: session.sessionId) == .endTurn)
        #expect(client.agentText == "Echo: hello world")
    }

    @Test func readsAndWritesThroughTheClient() async throws {
        let client = await EchoClient()
        _ = try await client.initialize()
        let session = try await client.newSession().sessionId

        #expect(try await client.prompt("read /a.txt", in: session) == .endTurn)
        let readUpdate = client.receivedUpdates.first {
            if case .toolCallUpdate(let update) = $0 { update.status == .completed } else { false }
        }
        #expect(readUpdate != nil)

        #expect(try await client.prompt("read /missing", in: session) == .endTurn)
        #expect(
            client.receivedUpdates.contains {
                if case .toolCallUpdate(let u) = $0 { u.status == .failed } else { false }
            }
        )

        #expect(try await client.prompt("write /b.txt new", in: session) == .endTurn)
        #expect(client.files.withLock { $0["/b.txt"] } == "new")

        client.permissionAnswer.withLock { $0 = .selected("reject") }
        #expect(try await client.prompt("write /c.txt nope", in: session) == .endTurn)
        #expect(client.files.withLock { $0["/c.txt"] } == nil)

        client.permissionAnswer.withLock { $0 = .cancelled }
        #expect(try await client.prompt("write /d.txt nope", in: session) == .cancelled)
    }

    @Test func failsFileToolsWithoutCapability() async throws {
        let client = await EchoClient()
        _ = try await client.initialize(fs: false)
        let session = try await client.newSession().sessionId
        #expect(try await client.prompt("read /a.txt", in: session) == .endTurn)
        #expect(try await client.prompt("write /b.txt x", in: session) == .endTurn)
        #expect(client.files.withLock { $0["/b.txt"] } == nil)
    }

    @Test func reportsPlansThoughtsAndFailures() async throws {
        let client = await EchoClient()
        _ = try await client.initialize()
        let session = try await client.newSession().sessionId
        _ = try await client.prompt("plan", in: session)
        _ = try await client.prompt("think", in: session)
        #expect(client.receivedUpdates.contains { if case .plan = $0 { true } else { false } })
        #expect(client.receivedUpdates.contains { if case .agentThoughtChunk = $0 { true } else { false } })
        await #expect(throws: RPCError.self) { try await client.prompt("fail", in: session) }
    }

    @Test func cancelsSlowTurns() async throws {
        let client = await EchoClient()
        _ = try await client.initialize()
        let session = try await client.newSession().sessionId
        let turn = Task { try await client.prompt("slow", in: session) }
        while client.agentText.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await client.connection.notify(ACP.V1.Method.Cancel.self, .init(sessionId: session))
        #expect(try await turn.value == .cancelled)
    }

    @Test func requiresAuthenticationWhenConfigured() async throws {
        var options = EchoAgent.Options()
        options.requiresAuthentication = true
        let client = await EchoClient(options: options)
        _ = try await client.initialize()
        do {
            _ = try await client.newSession()
            Issue.record("Expected auth required")
        } catch let error as RPCError {
            #expect(error.code == RPCError.authRequiredCode)
        }
        await #expect(throws: RPCError.self) {
            try await client.connection.request(ACP.V1.Method.Authenticate.self, .init(methodId: "nope"))
        }
        _ = try await client.connection.request(ACP.V1.Method.Authenticate.self, .init(methodId: "mock-login"))
        _ = try await client.newSession()
        _ = try await client.connection.request(ACP.V1.Method.Logout.self, .init())
        await #expect(throws: RPCError.self) { try await client.newSession() }
    }

    @Test func managesSessions() async throws {
        let client = await EchoClient()
        _ = try await client.initialize()
        let first = try await client.newSession(cwd: "/one").sessionId
        let second = try await client.newSession(cwd: "/two").sessionId
        _ = try await client.prompt("hi", in: first)
        client.clearUpdates()

        typealias M = ACP.V1.Method
        let all = try await client.connection.request(M.ListSessions.self, .init())
        #expect(all.sessions.map(\.sessionId) == [first, second])
        let filtered = try await client.connection.request(M.ListSessions.self, .init(cwd: "/two"))
        #expect(filtered.sessions.map(\.sessionId) == [second])

        let loaded = try await client.connection.request(
            M.LoadSession.self,
            .init(sessionId: first, cwd: "/one", mcpServers: [])
        )
        #expect(loaded.modes != nil)
        #expect(client.agentText == "Echo: hi")
        #expect(client.receivedUpdates.contains { if case .userMessageChunk = $0 { true } else { false } })

        _ = try await client.connection.request(M.ResumeSession.self, .init(sessionId: first, cwd: "/one"))
        await #expect(throws: RPCError.self) {
            try await client.connection.request(M.ResumeSession.self, .init(sessionId: "nope", cwd: "/"))
        }
        await #expect(throws: RPCError.self) {
            try await client.connection.request(M.LoadSession.self, .init(sessionId: "nope", cwd: "/", mcpServers: []))
        }

        _ = try await client.connection.request(M.SetMode.self, .init(sessionId: first, modeId: "code"))
        let options = try await client.connection.request(
            M.SetConfigOption.self,
            .init(sessionId: first, configId: "model", value: .select("large"))
        )
        #expect(
            options.configOptions.first?.value
                == .select(
                    currentValue: "large",
                    options: .flat([.init(value: "small", name: "Small"), .init(value: "large", name: "Large")])
                )
        )
        await #expect(throws: RPCError.self) {
            try await client.connection.request(
                M.SetConfigOption.self,
                .init(sessionId: first, configId: "x", value: .boolean(true))
            )
        }

        _ = try await client.connection.request(M.CloseSession.self, .init(sessionId: second))
        _ = try await client.connection.request(M.DeleteSession.self, .init(sessionId: second))
        #expect(try await client.connection.request(M.ListSessions.self, .init()).sessions.count == 1)
    }

    @Test func rejectsUnsupportedSessionMethods() async throws {
        var options = EchoAgent.Options()
        options.loadSession = false
        options.resumeSession = false
        options.listSessions = false
        options.modes = false
        options.configOptions = false
        let client = await EchoClient(options: options)
        _ = try await client.initialize()
        let session = try await client.newSession()
        #expect(session.modes == nil)
        #expect(session.configOptions == nil)
        typealias M = ACP.V1.Method
        await #expect(throws: RPCError.self) {
            try await client.connection.request(
                M.LoadSession.self,
                .init(sessionId: session.sessionId, cwd: "/", mcpServers: [])
            )
        }
        await #expect(throws: RPCError.self) {
            try await client.connection.request(M.ResumeSession.self, .init(sessionId: session.sessionId, cwd: "/"))
        }
        await #expect(throws: RPCError.self) { try await client.connection.request(M.ListSessions.self, .init()) }
    }
}

/// A reference to a mutex-protected value, so closures can share it.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}
