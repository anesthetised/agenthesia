public import ACP
public import Foundation
public import JSONRPC
public import MCP

/// How an agent reaches the app's agenthesia server (ADR-0049): the helper to run and the socket it connects to, with
/// the tokens that name sessions. A session gets a token before its agent is asked to start or reopen it.
public struct MCPEndpoint: Sendable {
    public let tokens: MCPTokens
    /// The `agenthesia-mcp` executable.
    public let helper: String
    public let socket: String

    public init(tokens: MCPTokens, helper: String, socket: String) {
        self.tokens = tokens
        self.helper = helper
        self.socket = socket
    }

    /// The stdio server for `session`, with a new token; the previous ones stay valid until the session is revoked.
    public func server(for session: UUID) -> ACP.MCPServer {
        .stdio(
            ACP.MCPServerStdio(
                name: "agenthesia",
                command: helper,
                env: [
                    ACP.EnvVariable(name: "AGENTHESIA_MCP_SOCKET", value: socket),
                    ACP.EnvVariable(name: "AGENTHESIA_MCP_TOKEN", value: tokens.issue(for: session)),
                ]
            )
        )
    }
}

/// The session behind a connection of the agenthesia server, as its tools see it.
public struct MCPCaller: Sendable {
    public let session: UUID
    private let turnInProgress: @Sendable () async -> Bool

    public init(session: UUID, turnInProgress: @escaping @Sendable () async -> Bool) {
        self.session = session
        self.turnInProgress = turnInProgress
    }

    /// `tool` refused with a clear message unless the calling session has a turn in progress. The tools that start
    /// work (`delegate`, `session_send`, `task_run`) declare it; reading tools work whenever the session is live
    /// (ADR-0049).
    public func requiringTurn(_ tool: MCP.ServedTool) -> MCP.ServedTool {
        let name = tool.tool.name
        return tool.gated { [turnInProgress] in
            await turnInProgress()
                ? nil
                : "\(name) starts work, so it works only while a turn of the calling session is in progress. "
                    + "Call it while you answer a prompt."
        }
    }

    /// Serves `tools` on `transport` until it closes.
    public static func serve(_ transport: any MessageTransport, tools: [MCP.ServedTool]) async {
        let connection = Connection(transport: transport)
        await connection.start(
            handler: MCP.server(info: MCP.Implementation(name: "agenthesia", version: "0.1"), tools: tools)
        )
        await connection.waitUntilClosed()
    }
}

extension SessionManager {
    public typealias MCPToolFactory = @MainActor (MCPCaller) -> MCP.ServedTool

    /// Serves the agenthesia server on one connection of `session`: the registered tools, with the session as caller.
    /// The turn gate reads the session's controller, so it holds while the owner is live (ADR-0049).
    public func serveMCP(session: UUID, over transport: any MessageTransport) async {
        let caller = MCPCaller(session: session) { [weak self] in
            await MainActor.run { self?.owner(of: session)?.controller?.status == .running }
        }
        await MCPCaller.serve(transport, tools: mcpTools.map { $0(caller) })
    }
}
