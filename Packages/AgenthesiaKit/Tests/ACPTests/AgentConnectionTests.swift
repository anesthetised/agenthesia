import ACP
import ACPTesting
import Foundation
import JSONRPC
import Synchronization
import Testing

/// Records everything an `AgentConnection` hands to its delegate.
final class AgentDelegate: ACP.AgentConnectionDelegate {
    private let state = Mutex<(updates: [(String, ACP.SessionUpdate)], inputs: [String], completed: [String])>(
        ([], [], [])
    )
    let permission = Mutex<ACP.PermissionOutcome>(.selected("allow"))

    func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID) async {
        state.withLock { $0.updates.append((sessionId, update)) }
    }

    func requestPermission(
        for toolCall: ACP.ToolCallUpdate,
        options: [ACP.PermissionOption],
        in sessionId: ACP.SessionID
    ) async -> ACP.PermissionOutcome {
        permission.withLock { $0 }
    }

    func requestInput(_ request: ACP.ElicitationRequest) async -> ACP.ElicitationResponse {
        state.withLock { $0.inputs.append(request.message) }
        return .init(action: .accept(["name": "Ada"]))
    }

    func inputCompleted(_ elicitationId: ACP.ElicitationID) async {
        state.withLock { $0.completed.append(elicitationId) }
    }

    var updates: [ACP.SessionUpdate] { state.withLock { $0.updates.map(\.1) } }
    var inputs: [String] { state.withLock { $0.inputs } }
    var completed: [String] { state.withLock { $0.completed } }
}

/// The default delegate requirements only.
struct MinimalDelegate: ACP.AgentConnectionDelegate {
    func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID) async {}

    func requestPermission(
        for toolCall: ACP.ToolCallUpdate,
        options: [ACP.PermissionOption],
        in sessionId: ACP.SessionID
    ) async -> ACP.PermissionOutcome { .cancelled }
}

final class MemoryFileSystem: ACP.FileSystemProvider {
    let files = Mutex<[String: String]>(["/a.txt": "hello"])

    func readTextFile(at path: String, line: Int?, limit: Int?, in sessionId: ACP.SessionID) async throws -> String {
        guard let content = files.withLock({ $0[path] }) else { throw RPCError(code: -32002, message: "Not found") }
        return content
    }

    func writeTextFile(at path: String, content: String, in sessionId: ACP.SessionID) async throws {
        files.withLock { $0[path] = content }
    }
}

final class FakeTerminals: ACP.TerminalProvider {
    let calls = Mutex<[String]>([])

    func createTerminal(_ request: ACP.V1.CreateTerminalRequest) async throws -> ACP.TerminalID {
        calls.withLock { $0.append("create \(request.command)") }
        return "t1"
    }

    func output(
        of terminalId: ACP.TerminalID,
        in sessionId: ACP.SessionID
    ) async throws -> ACP.V1.TerminalOutputResponse {
        calls.withLock { $0.append("output") }
        return .init(output: "ok", truncated: false)
    }

    func waitForExit(
        of terminalId: ACP.TerminalID,
        in sessionId: ACP.SessionID
    ) async throws -> ACP.V1.TerminalExitStatus {
        calls.withLock { $0.append("wait") }
        return .init(exitCode: 0)
    }

    func kill(_ terminalId: ACP.TerminalID, in sessionId: ACP.SessionID) async throws {
        calls.withLock { $0.append("kill") }
    }

    func release(_ terminalId: ACP.TerminalID, in sessionId: ACP.SessionID) async throws {
        calls.withLock { $0.append("release") }
    }
}

private let clientInfo = ACP.Implementation(name: "agenthesia-tests", version: "1")

private func connectToEcho(
    delegate: some ACP.AgentConnectionDelegate = AgentDelegate(),
    fileSystem: (any ACP.FileSystemProvider)? = nil,
    options: EchoAgent.Options = .init()
) async -> ACP.V1.AgentConnectionAdapter {
    let (agentSide, clientSide) = InMemoryTransport.pair()
    let agent = EchoAgent(options: options)
    Task { await agent.serve(agentSide) }
    return await ACP.V1.AgentConnectionAdapter(transport: clientSide, delegate: delegate, fileSystem: fileSystem)
}

private func play(
    _ steps: [Scenario.Step],
    delegate: some ACP.AgentConnectionDelegate = AgentDelegate(),
    fileSystem: (any ACP.FileSystemProvider)? = nil,
    terminals: (any ACP.TerminalProvider)? = nil,
    options: ACP.V1.AgentConnectionAdapter.Options = .init()
) async -> (ACP.V1.AgentConnectionAdapter, Task<ScenarioAgent.Mismatch?, Never>) {
    let (agentSide, clientSide) = InMemoryTransport.pair()
    let agent = ScenarioAgent(scenario: Scenario(steps), transport: agentSide)
    let run = Task { await agent.run() }
    let connection = await ACP.V1.AgentConnectionAdapter(
        transport: clientSide,
        delegate: delegate,
        fileSystem: fileSystem,
        terminals: terminals,
        options: options
    )
    return (connection, run)
}

private let initialized: Scenario.Step = .expectRequest(
    method: "initialize",
    response: .result(["protocolVersion": 1, "agentCapabilities": ["loadSession": true]])
)

@Suite(.timeLimit(.minutes(1))) struct AgentConnectionTests {
    @Test func buildsTheAgentProfile() async throws {
        let connection = await connectToEcho()
        let profile = try await connection.initialize(client: clientInfo)
        #expect(profile.protocolVersion == 1)
        #expect(profile.info?.name == "echo-agent")
        #expect(profile.authMethods.compactMap(\.id) == ["mock-login"])
        #expect(profile.canLoadSessions && profile.canResumeSessions && profile.canListSessions)
        #expect(profile.canCloseSessions && profile.canDeleteSessions && profile.canLogout)
        #expect(!profile.acceptsAdditionalDirectories)
        #expect(profile.acceptsImages && !profile.acceptsAudio && profile.acceptsEmbeddedContext)
        #expect(profile.acceptsHTTPMCPServers && !profile.acceptsSSEMCPServers)
        #expect(profile.steering == .interruptAndSend)
    }

    @Test func advertisesCapabilitiesFromProviders() async throws {
        let (minimal, minimalRun) = await play(
            [
                .expectRequest(
                    method: "initialize",
                    params: [
                        "clientInfo": ["name": "agenthesia-tests"],
                        "clientCapabilities": [
                            "terminal": false, "auth": ["terminal": false], "elicitation": ["form": [:]],
                            "session": ["configOptions": ["boolean": [:]]],
                        ],
                    ],
                    response: .result(["protocolVersion": 1])
                )
            ]
        )
        let profile = try await minimal.initialize(client: clientInfo)
        #expect(!profile.canLoadSessions && !profile.canResumeSessions)
        #expect(await minimalRun.value == nil)
        #expect(minimal.capabilities.fs == nil)

        let (full, fullRun) = await play(
            [
                .expectRequest(
                    method: "initialize",
                    params: [
                        "clientCapabilities": [
                            "fs": ["readTextFile": true, "writeTextFile": true], "terminal": true,
                            "auth": ["terminal": true],
                        ]
                    ],
                    response: .result(["protocolVersion": 1])
                )
            ],
            fileSystem: MemoryFileSystem(),
            terminals: FakeTerminals(),
            options: .init(terminalAuth: true, elicitation: false)
        )
        _ = try await full.initialize(client: clientInfo)
        #expect(await fullRun.value == nil)
        #expect(full.capabilities.elicitation == nil)
    }

    @Test func exposesSessionModesAsAConfigOption() async throws {
        let delegate = AgentDelegate()
        let connection = await connectToEcho(delegate: delegate)
        _ = try await connection.initialize(client: clientInfo)
        let session = try await connection.newSession(cwd: "/p", additionalDirectories: [], mcpServers: [])
        #expect(session.configOptions.map(\.id) == [ACP.V1.AgentConnectionAdapter.modeOptionID, "model"])
        #expect(session.configOptions.first?.category == .mode)

        let options = try await connection.setConfigOption(
            ACP.V1.AgentConnectionAdapter.modeOptionID,
            to: .select("code"),
            in: session.sessionId
        )
        guard case .select("code", _) = options.first?.value else {
            Issue.record("Mode not updated: \(options)")
            return
        }
        // The agent's current_mode_update reaches the delegate as config options.
        #expect(
            delegate.updates.contains {
                if case .configOptions(let update) = $0 {
                    update.configOptions.first?.value == options.first?.value
                } else {
                    false
                }
            }
        )
        #expect(!delegate.updates.contains { if case .currentMode = $0 { true } else { false } })

        await #expect(throws: RPCError.self) {
            try await connection.setConfigOption(
                ACP.V1.AgentConnectionAdapter.modeOptionID,
                to: .boolean(true),
                in: session.sessionId
            )
        }

        let model = try await connection.setConfigOption("model", to: .select("large"), in: session.sessionId)
        #expect(model.count == 2)
        #expect(
            model.last?.value
                == .select(
                    currentValue: "large",
                    options: .flat([.init(value: "small", name: "Small"), .init(value: "large", name: "Large")])
                )
        )
    }

    @Test func prefersTheAgentsOwnModeOption() async throws {
        let modeOption: JSONValue = [
            "id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "a",
            "options": [["value": "a", "name": "A"]],
        ]
        let delegate = AgentDelegate()
        let (connection, run) = await play(
            [
                initialized,
                .expectRequest(
                    method: "session/new",
                    response: .result([
                        "sessionId": "s",
                        "modes": ["currentModeId": "x", "availableModes": [["id": "x", "name": "X"]]],
                        "configOptions": [modeOption],
                    ])
                ),
                .sendNotification(
                    method: "session/update",
                    params: [
                        "sessionId": "s", "update": ["sessionUpdate": "current_mode_update", "currentModeId": "x"],
                    ]
                ),
                .sendNotification(
                    method: "session/update",
                    params: [
                        "sessionId": "s",
                        "update": ["sessionUpdate": "config_option_update", "configOptions": [modeOption]],
                    ]
                ),
                .sendRequest(
                    method: "fs/read_text_file",
                    params: ["sessionId": "s", "path": "/barrier"],
                    expect: .error(.methodNotFound("x"))
                ),
            ],
            delegate: delegate
        )
        _ = try await connection.initialize(client: clientInfo)
        let session = try await connection.newSession(cwd: "/p", additionalDirectories: ["/q"], mcpServers: [])
        #expect(session.configOptions.map(\.id) == ["mode"])
        #expect(await run.value == nil)
        // Without a synthesized mode option, mode updates pass through untouched.
        #expect(delegate.updates.contains { if case .currentMode = $0 { true } else { false } })
        #expect(
            delegate.updates.contains {
                if case .configOptions(let u) = $0 { u.configOptions.map(\.id) == ["mode"] } else { false }
            }
        )
    }

    @Test func resumesSessionsWhenPossible() async throws {
        let delegate = AgentDelegate()
        let connection = await connectToEcho(delegate: delegate)
        _ = try await connection.initialize(client: clientInfo)
        let session = try await connection.newSession(cwd: "/p", additionalDirectories: [], mcpServers: [])
        _ = try await connection.prompt([.init(text: "hi")], in: session.sessionId)
        let before = delegate.updates.count
        guard
            case .resumed(let state) = try await connection.reopenSession(
                session.sessionId,
                cwd: "/p",
                additionalDirectories: [],
                mcpServers: []
            )
        else {
            Issue.record("Expected resume")
            return
        }
        #expect(state.sessionId == session.sessionId)
        #expect(delegate.updates.count == before)
    }

    @Test func loadsSessionsWithoutForwardingTheReplay() async throws {
        var options = EchoAgent.Options()
        options.resumeSession = false
        let delegate = AgentDelegate()
        let connection = await connectToEcho(delegate: delegate, options: options)
        _ = try await connection.initialize(client: clientInfo)
        let session = try await connection.newSession(cwd: "/p", additionalDirectories: [], mcpServers: [])
        _ = try await connection.prompt([.init(text: "hi")], in: session.sessionId)
        let before = delegate.updates.count
        guard
            case .loaded = try await connection.reopenSession(
                session.sessionId,
                cwd: "/p",
                additionalDirectories: [],
                mcpServers: []
            )
        else {
            Issue.record("Expected load")
            return
        }
        #expect(delegate.updates.count == before)
        // Updates after the load are forwarded again.
        _ = try await connection.prompt([.init(text: "again")], in: session.sessionId)
        #expect(delegate.updates.count > before)

        await #expect(throws: RPCError.self) {
            try await connection.reopenSession("missing", cwd: "/p", additionalDirectories: [], mcpServers: [])
        }
        _ = try await connection.prompt([.init(text: "still forwarded")], in: session.sessionId)
        #expect(delegate.updates.count > before + 2)
    }

    @Test func reportsSessionsThatCannotBeReopened() async throws {
        var options = EchoAgent.Options()
        options.resumeSession = false
        options.loadSession = false
        let connection = await connectToEcho(options: options)
        _ = try await connection.initialize(client: clientInfo)
        #expect(
            try await connection.reopenSession("s", cwd: "/p", additionalDirectories: [], mcpServers: [])
                == .unavailable
        )
    }

    @Test func followsListPagination() async throws {
        let (connection, run) = await play([
            .expectRequest(
                method: "initialize",
                response: .result(["protocolVersion": 1, "agentCapabilities": ["sessionCapabilities": ["resume": [:]]]])
            ),
            .expectRequest(
                method: "session/list",
                params: ["cwd": "/p"],
                response: .result(["sessions": [["sessionId": "a", "cwd": "/p"]], "nextCursor": "page2"])
            ),
            .expectRequest(
                method: "session/list",
                params: ["cwd": "/p", "cursor": "page2"],
                response: .result(["sessions": [["sessionId": "b", "cwd": "/p"]]])
            ),
            .expectRequest(
                method: "session/resume",
                params: ["sessionId": "a", "additionalDirectories": ["/q"]],
                response: .error(RPCError(code: -32002, message: "gone"))
            ),
        ])
        _ = try await connection.initialize(client: clientInfo)
        #expect(try await connection.listSessions(cwd: "/p").map(\.sessionId) == ["a", "b"])
        await #expect(throws: RPCError.self) {
            try await connection.reopenSession("a", cwd: "/p", additionalDirectories: ["/q"], mcpServers: [])
        }
        #expect(await run.value == nil)
    }

    @Test func passesThroughSessionLifecycle() async throws {
        var options = EchoAgent.Options()
        options.requiresAuthentication = true
        let delegate = AgentDelegate()
        let connection = await connectToEcho(delegate: delegate, options: options)
        _ = try await connection.initialize(client: clientInfo)
        await #expect(throws: RPCError.self) {
            try await connection.newSession(cwd: "/p", additionalDirectories: [], mcpServers: [])
        }
        try await connection.authenticate(methodId: "mock-login")
        let session = try await connection.newSession(cwd: "/p", additionalDirectories: [], mcpServers: [])
        #expect(try await connection.prompt([.init(text: "hello")], in: session.sessionId) == .endTurn)
        #expect(delegate.updates.contains { if case .agentMessageChunk = $0 { true } else { false } })

        let turn = Task { try await connection.prompt([.init(text: "slow")], in: session.sessionId) }
        try await Task.sleep(for: .milliseconds(50))
        try await connection.cancel(session.sessionId)
        #expect(try await turn.value == .cancelled)

        #expect(try await connection.listSessions(cwd: nil).count == 1)
        try await connection.closeSession(session.sessionId)
        try await connection.deleteSession(session.sessionId)
        #expect(try await connection.listSessions(cwd: nil).isEmpty)
        try await connection.logout()
        await connection.close()
    }

    @Test func servesFilesAndPermissionsThroughProviders() async throws {
        let delegate = AgentDelegate()
        let files = MemoryFileSystem()
        let connection = await connectToEcho(delegate: delegate, fileSystem: files)
        _ = try await connection.initialize(client: clientInfo)
        let session = try await connection.newSession(cwd: "/p", additionalDirectories: [], mcpServers: [])
        _ = try await connection.prompt([.init(text: "read /a.txt")], in: session.sessionId)
        #expect(
            delegate.updates.contains {
                if case .toolCallUpdate(let update) = $0, update.status == .completed,
                    case .content(let block)? = update.content?.first
                {
                    block.content == .init(text: "hello")
                } else {
                    false
                }
            }
        )
        _ = try await connection.prompt([.init(text: "write /b.txt fresh")], in: session.sessionId)
        #expect(files.files.withLock { $0["/b.txt"] } == "fresh")
        delegate.permission.withLock { $0 = .selected("reject") }
        _ = try await connection.prompt([.init(text: "write /c.txt no")], in: session.sessionId)
        #expect(files.files.withLock { $0["/c.txt"] } == nil)
    }

    @Test func servesTerminalsAndElicitation() async throws {
        let delegate = AgentDelegate()
        let terminals = FakeTerminals()
        let terminal: JSONValue = ["sessionId": "s", "terminalId": "t1"]
        let (_, run) = await play(
            [
                .sendRequest(
                    method: "terminal/create",
                    params: ["sessionId": "s", "command": "ls"],
                    expect: .result(["terminalId": "t1"])
                ),
                .sendRequest(method: "terminal/output", params: terminal, expect: .result(["output": "ok"])),
                .sendRequest(method: "terminal/wait_for_exit", params: terminal, expect: .result(["exitCode": 0])),
                .sendRequest(method: "terminal/kill", params: terminal, expect: .result([:])),
                .sendRequest(method: "terminal/release", params: terminal, expect: .result([:])),
                .sendRequest(
                    method: "elicitation/create",
                    params: ["sessionId": "s", "message": "Name?", "mode": "form", "requestedSchema": [:]],
                    expect: .result(["action": "accept", "content": ["name": "Ada"]])
                ),
                .sendNotification(method: "elicitation/complete", params: ["elicitationId": "e1"]),
                .sendRequest(
                    method: "fs/read_text_file",
                    params: ["sessionId": "s", "path": "/a"],
                    expect: .error(.methodNotFound("x"))
                ),
                .sendRequest(
                    method: "fs/write_text_file",
                    params: ["sessionId": "s", "path": "/a", "content": ""],
                    expect: .error(.methodNotFound("x"))
                ),
            ],
            delegate: delegate,
            terminals: terminals
        )
        #expect(await run.value == nil)
        #expect(terminals.calls.withLock { $0 } == ["create ls", "output", "wait", "kill", "release"])
        #expect(delegate.inputs == ["Name?"])
        #expect(delegate.completed == ["e1"])
    }

    @Test func rejectsWhatIsNotProvided() async throws {
        let terminal: JSONValue = ["sessionId": "s", "terminalId": "t1"]
        let (_, run) = await play(
            [
                .sendRequest(
                    method: "terminal/create",
                    params: ["sessionId": "s", "command": "ls"],
                    expect: .error(.methodNotFound("x"))
                ),
                .sendRequest(method: "terminal/output", params: terminal, expect: .error(.methodNotFound("x"))),
                .sendRequest(method: "terminal/wait_for_exit", params: terminal, expect: .error(.methodNotFound("x"))),
                .sendRequest(method: "terminal/kill", params: terminal, expect: .error(.methodNotFound("x"))),
                .sendRequest(method: "terminal/release", params: terminal, expect: .error(.methodNotFound("x"))),
                .sendRequest(
                    method: "elicitation/create",
                    params: ["sessionId": "s", "message": "Name?", "mode": "form", "requestedSchema": [:]],
                    expect: .error(.methodNotFound("x"))
                ),
                .sendRequest(
                    method: "session/request_permission",
                    params: ["sessionId": "s", "toolCall": ["toolCallId": "c"], "options": []],
                    expect: .result(["outcome": ["outcome": "cancelled"]])
                ),
            ],
            delegate: MinimalDelegate(),
            options: .init(elicitation: false)
        )
        #expect(await run.value == nil)
    }

    @Test func defaultDelegateDeclinesInput() async {
        let response = await MinimalDelegate().requestInput(
            .init(message: "m", mode: .form(.init()), scope: .request(.int(1)))
        )
        #expect(response.action == .decline)
        await MinimalDelegate().inputCompleted("e")
    }
}
