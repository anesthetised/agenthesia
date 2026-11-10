import ACP
import Foundation
import JSONRPC
import MCP
import Persistence
import Testing

@testable import AgenthesiaCore

/// Sessions pass the agenthesia server to a real MockAgent, which starts the real helper that connects to a real
/// socket served by the manager (ADR-0049).
@MainActor @Suite(.timeLimit(.minutes(1))) struct AgenthesiaMCPTests {
    private struct Work: Decodable, Sendable { var what: String }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agh-mcp-\(UUID().uuidString.prefix(8))")
        let manager: SessionManager
        let socket: MCPSocket

        /// The package's `.build`, where the executables of the tests live.
        private static func executable(_ name: String) throws -> String {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            return try #require(
                [".build/debug/\(name)", ".build/out/Products/Debug/\(name)"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ).path
        }

        @MainActor init() throws {
            try FileManager.default.createDirectory(
                at: directory.appending(path: "project"),
                withIntermediateDirectories: true
            )
            manager = SessionManager(
                library: SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite")),
                worktreesRoot: directory.appending(path: "worktrees"),
                scratchRoot: directory.appending(path: "scratch")
            )
            manager.environment = { (ProcessInfo.processInfo.environment, nil) }
            let manager = manager
            socket = try MCPSocket(
                path: MCPSocket.path(dataFolder: directory),
                tokens: manager.mcpTokens
            ) { session, transport in
                await manager.serveMCP(session: session, over: transport)
            }
            manager.mcp = MCPEndpoint(
                tokens: manager.mcpTokens,
                helper: try Self.executable("agenthesia-mcp"),
                socket: socket.path
            )
            // `peek` reads, `start_work` starts work and so needs a turn in progress.
            manager.mcpTools = [
                { _ in
                    MCP.ServedTool(name: "peek", description: "Reads.", inputSchema: ["type": "object"]) {
                        (_: JSONRPC.Empty) in MCP.CallToolResult(content: [.text("peeked")])
                    }
                },
                { caller in
                    caller.requiringTurn(
                        MCP.ServedTool(
                            name: "start_work",
                            description: "Starts work.",
                            inputSchema: ["type": "object", "properties": ["what": ["type": "string"]]]
                        ) { (work: Work) in
                            MCP.CallToolResult(content: [.text("started \(work.what) for \(caller.session)")])
                        }
                    )
                },
            ]
        }

        func remove() {
            socket.close()
            try? FileManager.default.removeItem(at: directory)
        }

        func mock(_ arguments: [String] = []) throws -> AgentInstallRecord {
            AgentInstallRecord(name: "Mock", executable: try Self.executable("MockAgent"), arguments: arguments)
        }

        @MainActor func start(_ arguments: [String] = []) async throws -> LiveSession {
            let owner = manager.start(directory: directory.appending(path: "project"), agent: try mock(arguments))
            await owner.startup?.value
            return owner
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The token in the `agenthesia` server a session passed to its agent.
    private func token(of owner: LiveSession) throws -> String {
        let controller = try #require(owner.controller)
        guard case .stdio(let server) = try #require(controller.mcpServers.first) else {
            Issue.record("Expected a stdio server")
            return ""
        }
        #expect(server.name == "agenthesia")
        #expect(server.env.map(\.name) == ["AGENTHESIA_MCP_SOCKET", "AGENTHESIA_MCP_TOKEN"])
        return try #require(server.env.first { $0.name == "AGENTHESIA_MCP_TOKEN" }).value
    }

    /// Sends `text` and returns the agent's answer once the turn has ended.
    private func ask(_ owner: LiveSession, _ text: String) async throws -> String {
        let controller = try #require(owner.controller)
        try await waitUntil { controller.status == .idle }
        let before = controller.transcript.items.count
        #expect(await owner.submit(text))
        try await waitUntil {
            controller.status == .idle && controller.transcript.items.count > before
                && controller.transcript.items.last?.message?.role == .assistant
        }
        return try #require(controller.transcript.items.last?.message?.text)
    }

    @Test func aNewSessionPassesTheServerAndItsAgentCallsToolsThroughTheHelper() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try await fixture.start()
        #expect(owner.errorMessage == nil)
        let token = try token(of: owner)
        #expect(fixture.manager.mcpTokens.session(for: token) == owner.sessionID)

        let answer = try await ask(owner, "mcp peek {}")
        #expect(answer.hasPrefix("mcp peek: peeked"))
        let unknown = try await ask(owner, "mcp nothing {}")
        #expect(unknown.hasPrefix("mcp: no server offers nothing"))
        let invalid = try await ask(owner, "mcp peek {nope")
        #expect(invalid.hasPrefix("mcp peek: the arguments are not JSON"))
        await fixture.manager.end(owner)
    }

    @Test func aToolThatStartsWorkRunsInsideATurnAndIsRefusedOutsideOne() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try await fixture.start()
        let id = try #require(owner.sessionID)

        let answer = try await ask(owner, #"mcp start_work {"what":"the build"}"#)
        #expect(answer.hasPrefix("mcp start_work: started the build for \(id)"))

        // The same session, with no turn in progress, over a connection of its own.
        try await waitUntil { owner.controller?.status == .idle }
        let (serverSide, clientSide) = InMemoryTransport.pair()
        let serving = Task { await fixture.manager.serveMCP(session: id, over: serverSide) }
        let client = Connection(transport: clientSide)
        await client.start(handler: Router())
        let call = MCP.CallToolRequest(name: "start_work", arguments: ["what": "x"])
        let refused = try await client.request(MCP.Method.CallTool.self, call)
        #expect(refused.isError == true)
        guard case .text(let message) = try #require(refused.content.first) else { return }
        #expect(message.hasPrefix("start_work starts work"))
        let peeked = try await client.request(MCP.Method.CallTool.self, .init(name: "peek", arguments: [:]))
        #expect(peeked == MCP.CallToolResult(content: [.text("peeked")]))
        await client.close()
        await serving.value
        await fixture.manager.end(owner)
    }

    @Test func aSessionNobodyOwnsIsRefusedToo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (serverSide, clientSide) = InMemoryTransport.pair()
        let serving = Task { await fixture.manager.serveMCP(session: UUID(), over: serverSide) }
        let client = Connection(transport: clientSide)
        await client.start(handler: Router())
        let refused = try await client.request(
            MCP.Method.CallTool.self,
            .init(name: "start_work", arguments: ["what": "x"])
        )
        #expect(refused.isError == true)
        await client.close()
        await serving.value
    }

    /// MockAgent adopts the saved session with `--reopen`; without `--no-resume` the adapter resumes, with it it loads.
    @Test(arguments: [["--reopen"], ["--reopen", "--no-resume"]])
    func continuingIssuesANewTokenAndPassesTheServerInResumeAndLoad(arguments: [String]) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.start(arguments)
        let firstToken = try token(of: first)
        let record = try #require(first.controller).session
        #expect(try await ask(first, "mcp peek {}").hasPrefix("mcp peek: peeked"))

        await fixture.manager.end(first)
        // The token dies with the session's agent.
        #expect(fixture.manager.mcpTokens.session(for: firstToken) == nil)

        let second = try #require(fixture.manager.resume(record))
        await second.startup?.value
        #expect(second.errorMessage == nil)
        let secondToken = try token(of: second)
        #expect(secondToken != firstToken)
        #expect(fixture.manager.mcpTokens.session(for: secondToken) == record.id)
        #expect(try await ask(second, "mcp peek {}").hasPrefix("mcp peek: peeked"))
        await fixture.manager.end(second)
    }

    @Test func noServerIsPassedBeforeTheSocketListens() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.manager.mcp = nil
        let owner = try await fixture.start()
        #expect(owner.controller?.mcpServers.isEmpty == true)
        #expect(try await ask(owner, "mcp peek {}").hasPrefix("mcp: no stdio MCP server was given"))
        await fixture.manager.end(owner)
    }
}
