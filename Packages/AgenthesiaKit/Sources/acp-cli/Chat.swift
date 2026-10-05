import ACP
import ArgumentParser
import Foundation
import JSONRPC

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Chat with an agent. Ctrl-C cancels the running turn; press it again to quit."
    )

    @OptionGroup var agent: AgentOptions

    @Option(help: "Reopen an existing session instead of starting a new one.")
    var resume: String?

    @Option(help: "Authenticate with this agent auth method before starting.")
    var auth: String?

    func run() async throws {
        let console = Console.standard()
        let input = LineReader.standardInput()
        let turns = TurnState()
        let connected = try await ConnectedAgent.launch(
            agent,
            delegate: CLIDelegate(console: console, input: input),
            console: console
        )
        await console.line("Connected to \(connected.name)")

        let interrupts = Interrupts { await turns.interrupt(connected, input: input, console: console) }
        defer { interrupts.stop() }

        do {
            if let auth {
                try await connected.connection.authenticate(methodId: auth)
            }
            let session = try await openSession(connected, console: console)
            await console.line("Session \(session.sessionId) in \(agent.directory.path(percentEncoded: false))")
            if !session.configOptions.isEmpty {
                await console.line("Options: " + Renderer.describe(session.configOptions))
            }
            try await loop(session.sessionId, connected, input: input, console: console, turns: turns)
        } catch let error as RPCError where error.isAuthRequired {
            await console.error(authHelp(connected.profile, command: agent.command))
            await connected.shutDown()
            throw ExitCode(1)
        } catch {
            await connected.shutDown()
            throw error
        }
        await connected.shutDown()
    }

    private func openSession(_ connected: ConnectedAgent, console: Console) async throws -> ACP.SessionState {
        let cwd = agent.directory.path(percentEncoded: false)
        guard let resume else {
            return try await connected.connection.newSession(cwd: cwd, additionalDirectories: [], mcpServers: [])
        }
        switch try await connected.connection.reopenSession(resume, cwd: cwd, additionalDirectories: [], mcpServers: [])
        {
        case .resumed(let state), .loaded(let state):
            return state
        case .unavailable:
            throw CLIError("\(connected.name) can neither resume nor load sessions.")
        }
    }

    private func loop(
        _ sessionId: ACP.SessionID,
        _ connected: ConnectedAgent,
        input: LineReader,
        console: Console,
        turns: TurnState
    ) async throws {
        while true {
            await console.prompt("› ")
            guard let line = await input.next() else { return }
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if text == "/quit" || text == "/exit" { return }
            await turns.begin(sessionId)
            let reason: ACP.StopReason
            do {
                reason = try await connected.connection.prompt([.init(text: text)], in: sessionId)
            } catch let error as RPCError where !error.isAuthRequired {
                await turns.end()
                await console.line("Error \(error.code): \(error.message)")
                continue
            }
            await turns.end()
            await console.endTurn(reason)
        }
    }
}

/// Tracks the running turn, so Ctrl-C can cancel it first and quit second.
actor TurnState {
    private var sessionId: ACP.SessionID?
    private var cancelling = false

    func begin(_ sessionId: ACP.SessionID) {
        self.sessionId = sessionId
        cancelling = false
    }

    func end() {
        sessionId = nil
        cancelling = false
    }

    func interrupt(_ connected: ConnectedAgent, input: LineReader, console: Console) async {
        guard let sessionId, !cancelling else {
            await connected.shutDown()
            Foundation.exit(130)
        }
        cancelling = true
        await console.line("Cancelling… (press Ctrl-C again to quit)")
        await input.interrupt()
        try? await connected.connection.cancel(sessionId)
    }
}

/// Calls a handler on every Ctrl-C instead of terminating the process.
final class Interrupts: Sendable {
    private let source: any DispatchSourceSignal

    init(_ handler: @escaping @Sendable () async -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { Task { await handler() } }
        source.resume()
    }

    func stop() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
