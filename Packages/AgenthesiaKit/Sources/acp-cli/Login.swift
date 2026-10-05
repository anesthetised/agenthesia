import ACP
import AgentRuntime
import ArgumentParser
import Foundation

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in to an agent: run a terminal auth method here, or call an agent auth method."
    )

    @OptionGroup var agent: AgentOptions

    @Option(help: "The auth method id. Without it, the available methods are listed.")
    var method: String?

    func run() async throws {
        let console = Console.standard()
        let connected = try await ConnectedAgent.launch(
            agent,
            delegate: CLIDelegate(console: console, input: LineReader([String]().async)),
            console: console,
            terminalAuth: true
        )
        guard let method else {
            await console.line(authHelp(connected.profile, command: agent.command, header: "Sign-in methods:"))
            await connected.shutDown()
            return
        }
        guard let chosen = connected.profile.authMethods.first(where: { $0.id == method }) else {
            await connected.shutDown()
            throw CLIError("Unknown auth method \(method).")
        }
        switch chosen {
        case .agent:
            defer { Task { await connected.shutDown() } }
            try await connected.connection.authenticate(methodId: method)
            await console.line("Signed in.")
            await connected.shutDown()
        case .terminal(let terminal):
            await connected.shutDown()
            let status = try Self.runInTerminal(agent.agentCommand, adding: terminal)
            guard status == 0 else { throw ExitCode(status) }
            await console.line("Signed in.")
        case .unknown:
            await connected.shutDown()
            throw CLIError("Auth method \(method) is not supported.")
        }
    }

    /// The agent command with the terminal method's arguments and environment.
    static func command(_ command: AgentCommand, adding method: ACP.TerminalAuthMethod) -> AgentCommand {
        var command = command
        command.arguments += method.args ?? []
        if let env = method.env, !env.isEmpty {
            command.environment = (command.environment ?? ProcessInfo.processInfo.environment)
                .merging(env) { _, new in new }
        }
        return command
    }

    /// Runs the command attached to this terminal and returns its exit status.
    static func runInTerminal(_ base: AgentCommand, adding method: ACP.TerminalAuthMethod) throws -> Int32 {
        let command = command(base, adding: method)
        let process = Process()
        if command.executable.contains("/") {
            process.executableURL = URL(filePath: command.executable)
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [command.executable] + command.arguments
        }
        if let environment = command.environment {
            process.environment = environment
        }
        process.currentDirectoryURL = command.currentDirectory
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
