import ACP
import AgentRuntime
import ArgumentParser
import Foundation
import JSONRPC

@main
struct ACPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acp-cli",
        abstract: "Talk to any Agent Client Protocol agent from the terminal.",
        discussion: """
            The agent command follows `--`, for example:

              acp-cli chat -- npx -y @agentclientprotocol/claude-agent-acp
            """,
        subcommands: [Chat.self, Sessions.self, Login.self],
        defaultSubcommand: Chat.self
    )

    static let clientInfo = ACP.Implementation(name: "acp-cli", title: "Agenthesia ACP CLI", version: "0.1.0")
}

/// Options shared by every command: how to start and observe the agent.
struct AgentOptions: ParsableArguments {
    @Option(help: "The working directory of the session (default: the current directory).")
    var cwd: String?

    @Flag(help: "Print raw ACP traffic to stderr.")
    var trace = false

    @Flag(help: "Print the agent's own log (its stderr).")
    var agentLog = false

    @Argument(parsing: .postTerminator, help: "The agent command, after `--`.")
    var command: [String] = []

    func validate() throws {
        if command.isEmpty {
            throw ValidationError("Give the agent command after `--`, for example: acp-cli chat -- my-agent --acp")
        }
    }

    var directory: URL {
        URL(filePath: cwd ?? FileManager.default.currentDirectoryPath, directoryHint: .isDirectory).standardizedFileURL
    }

    var agentCommand: AgentCommand {
        AgentCommand(executable: command[0], arguments: Array(command.dropFirst()), currentDirectory: directory)
    }
}

/// A launched agent with an initialized ACP connection.
struct ConnectedAgent {
    let process: AgentProcess
    let connection: ACP.V1.AgentConnectionAdapter
    let profile: ACP.AgentProfile

    static func launch(
        _ options: AgentOptions,
        delegate: some ACP.AgentConnectionDelegate,
        console: Console,
        terminalAuth: Bool = false
    ) async throws -> ConnectedAgent {
        let process = try AgentProcess(launching: options.agentCommand)
        let showLog = options.agentLog
        let log = AgentLog()
        Task {
            for await line in process.stderr {
                await log.append(line)
                if showLog {
                    await console.error("agent: \(line)")
                }
            }
        }
        var traffic: Connection.TrafficObserver?
        if options.trace {
            traffic = { direction, data in
                let arrow = direction == .incoming ? "←" : "→"
                FileHandle.standardError.write(Data("\(arrow) ".utf8) + data + Data("\n".utf8))
            }
        }
        let connection = await ACP.V1.AgentConnectionAdapter(
            transport: process.transport,
            delegate: delegate,
            fileSystem: CLIFileSystem(root: options.directory),
            options: .init(terminalAuth: terminalAuth, elicitation: false),
            traffic: traffic
        )
        do {
            let profile = try await connection.initialize(client: ACPCLI.clientInfo)
            return ConnectedAgent(process: process, connection: connection, profile: profile)
        } catch ConnectionError.closed {
            let status = await process.terminate()
            try? await Task.sleep(for: .milliseconds(100))
            throw ValidationError(Self.exitedEarly(status, log: await log.lines))
        } catch {
            await process.terminate()
            throw error
        }
    }

    /// Explains an agent that exited before initialization finished.
    static func exitedEarly(_ status: ExitStatus, log: [String]) -> String {
        var message = "The agent \(status) before it finished initializing."
        if !log.isEmpty {
            message += " Its last output:\n" + log.map { "  " + $0 }.joined(separator: "\n")
        }
        return message
    }

    var name: String {
        guard let info = profile.info else { return "agent" }
        return "\(info.title ?? info.name) \(info.version)"
    }

    func shutDown() async {
        await connection.close()
        await process.terminate()
    }
}

/// The last lines an agent wrote to stderr.
actor AgentLog {
    private(set) var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 10 {
            lines.removeFirst()
        }
    }
}

extension RPCError {
    var isAuthRequired: Bool { code == RPCError.authRequiredCode }
}

/// Lists auth methods with a hint on how to sign in.
func authHelp(
    _ profile: ACP.AgentProfile,
    command: [String],
    header: String = "Authentication required. Sign in with one of:"
) -> String {
    guard !profile.authMethods.isEmpty else { return "The agent requires authentication but offers no method." }
    let methods = profile.authMethods.map { method -> String in
        switch method {
        case .agent(let method): "  \(method.id)  \(method.name)"
        case .terminal(let method): "  \(method.id)  \(method.name) (in the terminal)"
        case .unknown(let raw): "  \(raw["id"]?.stringValue ?? "?")  (unsupported)"
        }
    }
    let example = profile.authMethods.compactMap(\.id).first ?? "<method>"
    return """
        \(header)
        \(methods.joined(separator: "\n"))

        For example: acp-cli login --method \(example) -- \(command.joined(separator: " "))
        """
}
