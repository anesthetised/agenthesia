import ACP
import AgenthesiaCore
import Foundation

/// `chat --agenthesia-mcp`: the agenthesia server of the app (ADR-0049), served by this process for the one session,
/// so the CLI stays a neutral driver unless asked. The `agenthesia-mcp` helper is expected beside `acp-cli`.
struct AgenthesiaMCP {
    private let socket: MCPSocket
    private let endpoint: MCPEndpoint
    private let session = UUID()

    init() throws {
        let helper = (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appending(path: "agenthesia-mcp").path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw CLIError("Cannot find \(helper). Build it first: swift build --product agenthesia-mcp")
        }
        let tokens = MCPTokens()
        // ponytail: no tools exist yet; each M13 tool adds itself to the list served here.
        socket = try MCPSocket(
            path: MCPSocket.path(dataFolder: URL(filePath: "/acp-cli/\(UUID())")),
            tokens: tokens
        ) { _, transport in
            await MCPCaller.serve(transport, tools: [])
        }
        endpoint = MCPEndpoint(tokens: tokens, helper: helper, socket: socket.path)
    }

    /// The server to pass in `session/new` or `session/resume`, with a token for this chat.
    var server: ACP.MCPServer { endpoint.server(for: session) }

    func close() { socket.close() }
}
