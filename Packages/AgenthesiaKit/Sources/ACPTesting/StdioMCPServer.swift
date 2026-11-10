import ACP
import Foundation
import JSONRPC
import MCP

/// A stdio MCP server the client gave the agent, started the way agents start them (command, arguments and exactly
/// the `env` given), with the client side of MCP: the handshake runs at the first use, as agents connect lazily.
actor StdioMCPServer {
    private let process = Process()
    private let connection: Connection
    private var initialized = false

    init(_ server: ACP.MCPServerStdio) throws {
        let (input, output) = (Pipe(), Pipe())
        process.executableURL = URL(filePath: server.command)
        process.arguments = server.args
        process.environment = Dictionary(server.env.map { ($0.name, $0.value) }) { $1 }
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        connection = Connection(
            transport: FileHandleTransport(
                reading: output.fileHandleForReading,
                writing: input.fileHandleForWriting
            )
        )
    }

    func tools() async throws -> [MCP.Tool] {
        try await ready().request(MCP.Method.ListTools.self, .init()).tools
    }

    func call(_ tool: String, arguments: JSONValue) async throws -> MCP.CallToolResult {
        try await ready().request(MCP.Method.CallTool.self, .init(name: tool, arguments: arguments))
    }

    /// Closes the connection, which ends the server, and stops it should it not.
    func stop() async {
        await connection.close()
        if process.isRunning { process.terminate() }
    }

    private func ready() async throws -> Connection {
        guard !initialized else { return connection }
        await connection.start(handler: Router())
        _ = try await connection.request(
            MCP.Method.Initialize.self,
            .init(clientInfo: .init(name: "MockAgent", version: "1.0.0"))
        )
        try await connection.notify(MCP.Method.Initialized.self, .init())
        initialized = true
        return connection
    }
}
