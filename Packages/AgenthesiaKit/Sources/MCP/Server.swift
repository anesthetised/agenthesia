public import JSONRPC

extension MCP {
    /// A tool together with the handler that runs it.
    public struct ServedTool: Sendable {
        public let tool: Tool
        let call: @Sendable (JSONValue?) async -> CallToolResult

        /// Arguments that fail to decode, and errors the handler throws, become an `isError` result.
        public init<Arguments: Decodable & Sendable>(
            name: String,
            description: String,
            inputSchema: JSONValue,
            _ handler: @escaping @Sendable (Arguments) async throws -> CallToolResult
        ) {
            tool = Tool(name: name, description: description, inputSchema: inputSchema)
            call = { arguments in
                let decoded: Arguments
                do {
                    decoded = try (arguments ?? [:]).decode(as: Arguments.self)
                } catch {
                    return .error("Invalid arguments for \(name): \(error)")
                }
                do {
                    return try await handler(decoded)
                } catch {
                    return .error(String(describing: error))
                }
            }
        }
    }

    /// A `Router` that serves `initialize`, `ping`, `tools/list` and `tools/call` for `tools`.
    ///
    /// Start a `Connection` with it. `notifications/initialized` needs no handler: the router ignores
    /// notifications it does not know. A call to an unknown tool is a protocol error (`-32602`).
    public static func server(info: Implementation, instructions: String? = nil, tools: [ServedTool]) -> Router {
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.name, $0) })
        let listed = tools.map(\.tool)
        var router = Router()
        router.on(Method.Initialize.self) { _ in
            InitializeResult(serverInfo: info, instructions: instructions)
        }
        router.on(Method.Ping.self) { _ in JSONRPC.Empty() }
        router.on(Method.ListTools.self) { _ in ListToolsResult(tools: listed) }
        router.on(Method.CallTool.self) { request in
            guard let served = byName[request.name] else {
                throw RPCError.invalidParams("Unknown tool: \(request.name)")
            }
            return await served.call(request.arguments)
        }
        return router
    }
}
