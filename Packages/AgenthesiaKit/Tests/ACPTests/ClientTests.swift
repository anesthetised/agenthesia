import ACP
import ACPTesting
import Foundation
import JSONRPC
import Synchronization
import Testing

/// A delegate that records session updates and implements nothing else.
final class RecordingDelegate: ACP.V1.ClientDelegate {
    private let updates = Mutex<[ACP.V1.SessionNotification]>([])

    func sessionUpdate(_ notification: ACP.V1.SessionNotification) async {
        updates.withLock { $0.append(notification) }
    }

    var received: [ACP.V1.SessionNotification] { updates.withLock { $0 } }
}

/// A delegate that answers every agent request with fixed values.
final class FullDelegate: ACP.V1.ClientDelegate {
    private let calls = Mutex<[String]>([])

    var all: [String] { calls.withLock { $0 } }

    private func record(_ call: String) {
        calls.withLock { $0.append(call) }
    }

    func requestPermission(_ request: ACP.V1.RequestPermissionRequest) async throws -> ACP.V1.RequestPermissionResponse
    {
        record("permission \(request.toolCall.toolCallId)")
        return .init(outcome: .selected(request.options[0].optionId))
    }

    func readTextFile(_ request: ACP.V1.ReadTextFileRequest) async throws -> ACP.V1.ReadTextFileResponse {
        record("read \(request.path)")
        return .init(content: "text")
    }

    func writeTextFile(_ request: ACP.V1.WriteTextFileRequest) async throws -> ACP.V1.EmptyMessage {
        record("write \(request.path)")
        return .init()
    }

    func createTerminal(_ request: ACP.V1.CreateTerminalRequest) async throws -> ACP.V1.CreateTerminalResponse {
        record("terminal \(request.command)")
        return .init(terminalId: "t1")
    }

    func terminalOutput(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.TerminalOutputResponse {
        record("output \(request.terminalId)")
        return .init(output: "out", truncated: false)
    }

    func waitForTerminalExit(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.TerminalExitStatus {
        record("wait \(request.terminalId)")
        return .init(exitCode: 0)
    }

    func killTerminal(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.EmptyMessage {
        record("kill \(request.terminalId)")
        return .init()
    }

    func releaseTerminal(_ request: ACP.V1.TerminalRequest) async throws -> ACP.V1.EmptyMessage {
        record("release \(request.terminalId)")
        return .init()
    }

    func createElicitation(_ request: ACP.ElicitationRequest) async throws -> ACP.ElicitationResponse {
        record("elicit \(request.message)")
        return .init(action: .decline)
    }

    func completeElicitation(_ notification: ACP.ElicitationComplete) async {
        record("complete \(notification.elicitationId)")
    }
}

private func connectToEcho(
    _ delegate: some ACP.V1.ClientDelegate = RecordingDelegate(),
    options: EchoAgent.Options = .init()
) async -> ACP.V1.Client {
    let (agentSide, clientSide) = InMemoryTransport.pair()
    let agent = EchoAgent(options: options)
    Task { await agent.serve(agentSide) }
    return await ACP.V1.Client(transport: clientSide, delegate: delegate)
}

private func play(
    _ steps: [Scenario.Step],
    delegate: some ACP.V1.ClientDelegate = RecordingDelegate()
) async -> (ACP.V1.Client, Task<ScenarioAgent.Mismatch?, Never>) {
    let (agentSide, clientSide) = InMemoryTransport.pair()
    let agent = ScenarioAgent(scenario: Scenario(steps), transport: agentSide)
    let run = Task { await agent.run() }
    return (await ACP.V1.Client(transport: clientSide, delegate: delegate), run)
}

@Suite(.timeLimit(.minutes(1))) struct ClientTests {
    @Test func runsAFullSessionAgainstTheEchoAgent() async throws {
        let delegate = RecordingDelegate()
        let client = await connectToEcho(delegate)
        let initialized = try await client.initialize(
            capabilities: .init(),
            info: .init(name: "agenthesia", version: "0.1.0")
        )
        #expect(initialized.agentInfo?.name == "echo-agent")
        try await client.authenticate(methodId: "mock-login")

        let session = try await client.newSession(.init(cwd: "/p", mcpServers: []))
        #expect(try await client.prompt([.init(text: "hi")], in: session.sessionId).stopReason == .endTurn)
        #expect(delegate.received.count == 2)
        #expect(delegate.received.allSatisfy { $0.sessionId == session.sessionId })

        try await client.setMode("code", in: session.sessionId)
        let options = try await client.setConfigOption("model", to: .select("large"), in: session.sessionId)
        #expect(options.count == 1)

        let listed = try await client.listSessions(.init())
        #expect(listed.sessions.map(\.sessionId) == [session.sessionId])
        _ = try await client.resumeSession(.init(sessionId: session.sessionId, cwd: "/p"))
        let before = delegate.received.count
        _ = try await client.loadSession(.init(sessionId: session.sessionId, cwd: "/p", mcpServers: []))
        #expect(delegate.received.count > before)

        try await client.closeSession(session.sessionId)
        try await client.deleteSession(session.sessionId)
        try await client.logout()
        await client.close()
        await client.waitUntilClosed()
    }

    @Test func cancelsTurns() async throws {
        let client = await connectToEcho()
        _ = try await client.initialize(capabilities: .init())
        let session = try await client.newSession(.init(cwd: "/p", mcpServers: []))
        let turn = Task { try await client.prompt([.init(text: "slow")], in: session.sessionId) }
        try await Task.sleep(for: .milliseconds(50))
        try await client.cancel(session.sessionId)
        #expect(try await turn.value.stopReason == .cancelled)
    }

    @Test func rejectsOtherProtocolVersions() async throws {
        let (client, run) = await play([.expectRequest(method: "initialize", response: .result(["protocolVersion": 2]))]
        )
        await #expect(throws: ACP.V1.ClientError.unsupportedProtocolVersion(2)) {
            try await client.initialize(capabilities: .init())
        }
        #expect(await run.value == nil)
    }

    @Test func sendsTheDocumentedParameters() async throws {
        let (client, run) = await play([
            .expectRequest(
                method: "initialize",
                params: [
                    "protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": true]],
                    "clientInfo": ["name": "a"],
                ],
                response: .result(["protocolVersion": 1])
            ),
            .expectRequest(method: "authenticate", params: ["methodId": "m"], response: .result([:])),
            .expectRequest(
                method: "session/new",
                params: ["cwd": "/p", "mcpServers": [], "additionalDirectories": ["/q"]],
                response: .result(["sessionId": "s"])
            ),
            .expectRequest(
                method: "session/set_config_option",
                params: ["sessionId": "s", "configId": "web", "type": "boolean", "value": true],
                response: .result(["configOptions": []])
            ),
            .expectRequest(
                method: "session/set_mode",
                params: ["sessionId": "s", "modeId": "code"],
                response: .result([:])
            ),
            .expectRequest(
                method: "session/prompt",
                params: ["sessionId": "s", "prompt": [["type": "text", "text": "go"]]],
                response: nil,
                deferAs: "prompt"
            ),
            .expectNotification(method: "session/cancel", params: ["sessionId": "s"]),
            .respond(to: "prompt", response: .result(["stopReason": "cancelled"])),
            .expectRequest(
                method: "session/list",
                params: ["cwd": "/p", "cursor": "c"],
                response: .result(["sessions": []])
            ),
            .expectRequest(method: "session/close", params: ["sessionId": "s"], response: .result([:])),
            .expectRequest(method: "session/delete", params: ["sessionId": "s"], response: .result([:])),
            .expectRequest(method: "logout", response: .result([:])),
        ])
        _ = try await client.initialize(
            capabilities: .init(fs: .init(readTextFile: true)),
            info: .init(name: "a", version: "1")
        )
        try await client.authenticate(methodId: "m")
        _ = try await client.newSession(.init(cwd: "/p", additionalDirectories: ["/q"], mcpServers: []))
        _ = try await client.setConfigOption("web", to: .boolean(true), in: "s")
        try await client.setMode("code", in: "s")
        let turn = Task { try await client.prompt([.init(text: "go")], in: "s") }
        try await Task.sleep(for: .milliseconds(20))
        try await client.cancel("s")
        #expect(try await turn.value.stopReason == .cancelled)
        _ = try await client.listSessions(.init(cwd: "/p", cursor: "c"))
        try await client.closeSession("s")
        try await client.deleteSession("s")
        try await client.logout()
        #expect(await run.value == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ClientDelegateTests {
    private static let terminal: JSONValue = ["sessionId": "s", "terminalId": "t1"]

    private static let requests: [(method: String, params: JSONValue, result: JSONValue)] = [
        (
            "session/request_permission",
            [
                "sessionId": "s", "toolCall": ["toolCallId": "c"],
                "options": [["optionId": "ok", "name": "OK", "kind": "allow_once"]],
            ],
            ["outcome": ["outcome": "selected", "optionId": "ok"]]
        ),
        ("fs/read_text_file", ["sessionId": "s", "path": "/a"], ["content": "text"]),
        ("fs/write_text_file", ["sessionId": "s", "path": "/a", "content": "x"], [:]),
        ("terminal/create", ["sessionId": "s", "command": "ls"], ["terminalId": "t1"]),
        ("terminal/output", terminal, ["output": "out", "truncated": false]),
        ("terminal/wait_for_exit", terminal, ["exitCode": 0]),
        ("terminal/kill", terminal, [:]),
        ("terminal/release", terminal, [:]),
        (
            "elicitation/create", ["sessionId": "s", "message": "Name?", "mode": "form", "requestedSchema": [:]],
            ["action": "decline"]
        ),
    ]

    @Test func defaultsRejectEveryRequestAndIgnoreNotifications() async throws {
        var steps: [Scenario.Step] = [
            .sendNotification(method: "elicitation/complete", params: ["elicitationId": "e"]),
            .sendNotification(
                method: "session/update",
                params: ["sessionId": "s", "update": ["sessionUpdate": "plan", "entries": []]]
            ),
        ]
        for request in Self.requests {
            steps.append(
                .sendRequest(
                    method: request.method,
                    params: request.params,
                    expect: .error(.methodNotFound(request.method))
                )
            )
        }
        struct Silent: ACP.V1.ClientDelegate {}
        let (_, run) = await play(steps, delegate: Silent())
        #expect(await run.value == nil)
    }

    @Test func dispatchesEveryRequestToTheDelegate() async throws {
        var steps: [Scenario.Step] = Self.requests.map {
            .sendRequest(method: $0.method, params: $0.params, expect: .result($0.result))
        }
        steps.append(.sendNotification(method: "elicitation/complete", params: ["elicitationId": "e"]))
        steps.append(
            .sendRequest(method: "fs/read_text_file", params: ["path": "/barrier"], expect: .error(.invalidParams()))
        )
        let delegate = FullDelegate()
        let (_, run) = await play(steps, delegate: delegate)
        #expect(await run.value == nil)
        #expect(
            delegate.all == [
                "permission c", "read /a", "write /a", "terminal ls", "output t1", "wait t1", "kill t1", "release t1",
                "elicit Name?", "complete e",
            ]
        )
    }
}
