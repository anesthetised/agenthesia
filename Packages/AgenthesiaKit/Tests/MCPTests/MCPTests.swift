import Foundation
import JSONRPC
import MCP
import Synchronization
import Testing

private struct Greeting: Decodable, Sendable {
    var name: String
}

private struct Failure: Error, CustomStringConvertible {
    var description: String { "the tool broke" }
}

private let info = MCP.Implementation(name: "agenthesia", version: "1.0")

private let tools = [
    MCP.ServedTool(
        name: "greet",
        description: "Says hello.",
        inputSchema: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]
    ) { (arguments: Greeting) in
        MCP.CallToolResult(content: [.text("Hello, \(arguments.name)")])
    },
    MCP.ServedTool(name: "fail", description: "Always throws.", inputSchema: ["type": "object"]) {
        (_: JSONRPC.Empty) in throw Failure()
    },
]

@Suite struct MCPTests {
    @Test func servesInitializeListAndCallToAClientOverAConnection() async throws {
        let (serverSide, clientSide) = InMemoryTransport.pair()
        let server = Connection(transport: serverSide)
        let client = Connection(transport: clientSide)
        await server.start(handler: MCP.server(info: info, instructions: "Use greet.", tools: tools))
        await client.start(handler: Router())

        let initialized = try await client.request(
            MCP.Method.Initialize.self,
            MCP.InitializeRequest(clientInfo: .init(name: "test", version: "0"))
        )
        try await client.notify(MCP.Method.Initialized.self, JSONRPC.Empty())
        #expect(initialized == MCP.InitializeResult(serverInfo: info, instructions: "Use greet."))
        #expect(try await client.request(MCP.Method.Ping.self, JSONRPC.Empty()) == JSONRPC.Empty())

        let listed = try await client.request(MCP.Method.ListTools.self, MCP.ListToolsRequest())
        #expect(listed.tools.map(\.name) == ["greet", "fail"])
        #expect(listed.tools[0].inputSchema["required"] == ["name"])

        let called = try await client.request(
            MCP.Method.CallTool.self,
            MCP.CallToolRequest(name: "greet", arguments: ["name": "Ada"])
        )
        #expect(called == MCP.CallToolResult(content: [.text("Hello, Ada")]))
        await client.close()
        await server.close()
    }

    @Test func announcesToolsInInitialize() async throws {
        let router = MCP.server(info: info, tools: [])
        let result = try await router.handleRequest(
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "c", "version": "1"],
            ]
        )
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["capabilities"] == ["tools": [:]])
        #expect(result["instructions"] == nil)
    }

    @Test func reportsBadArgumentsAndThrownErrorsAsToolErrors() async throws {
        let router = MCP.server(info: info, tools: tools)
        let invalid: MCP.CallToolResult = try await router.handleRequest(
            method: "tools/call",
            params: ["name": "greet", "arguments": ["name": 1]]
        ).decode()
        #expect(invalid.isError == true)
        #expect(invalid.content.count == 1)

        let missing: MCP.CallToolResult = try await router.handleRequest(
            method: "tools/call",
            params: ["name": "greet"]
        ).decode()
        #expect(missing.isError == true)

        let thrown: MCP.CallToolResult = try await router.handleRequest(
            method: "tools/call",
            params: ["name": "fail"]
        ).decode()
        #expect(thrown == .error("the tool broke"))
    }

    @Test func rejectsUnknownToolsAsProtocolErrors() async {
        let router = MCP.server(info: info, tools: tools)
        await #expect(throws: RPCError.invalidParams("Unknown tool: nope")) {
            try await router.handleRequest(method: "tools/call", params: ["name": "nope"])
        }
    }

    @Test func encodesTextAndBase64ImageContent() throws {
        let content: [MCP.Content] = [.text("hi"), .image(Data([1, 2, 3]), mimeType: "image/png")]
        let json = try JSONValue(encoding: content)
        #expect(json == [["type": "text", "text": "hi"], ["type": "image", "data": "AQID", "mimeType": "image/png"]])
        #expect(try json.decode(as: [MCP.Content].self) == content)
        #expect(throws: DecodingError.self) {
            try (["type": "audio", "data": "AQID"] as JSONValue).decode(as: MCP.Content.self)
        }
    }

    @Test func gatedToolsAreRefusedWithTheMessageWhileTheRefusalHolds() async throws {
        let open = Mutex(false)
        let gated = tools[0].gated { open.withLock { $0 } ? nil : "not now" }
        let router = MCP.server(info: info, tools: [gated])
        let params: JSONValue = ["name": "greet", "arguments": ["name": "Ada"]]
        #expect(
            try await router.handleRequest(method: "tools/call", params: params).decode(as: MCP.CallToolResult.self)
                == .error("not now")
        )
        open.withLock { $0 = true }
        #expect(
            try await router.handleRequest(method: "tools/call", params: params).decode(as: MCP.CallToolResult.self)
                == MCP.CallToolResult(content: [.text("Hello, Ada")])
        )
        #expect(gated.tool == tools[0].tool)
    }
}
