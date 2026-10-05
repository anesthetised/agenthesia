import ACP
import ArgumentParser
import Foundation

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the agent's sessions for the working directory.")

    @OptionGroup var agent: AgentOptions

    @Flag(help: "List sessions of every directory.")
    var all = false

    func run() async throws {
        let console = Console.standard()
        let connected = try await ConnectedAgent.launch(
            agent,
            delegate: CLIDelegate(console: console, input: LineReader([String]().async)),
            console: console
        )
        defer { Task { await connected.shutDown() } }
        guard connected.profile.canListSessions else {
            await connected.shutDown()
            throw ValidationError("\(connected.name) cannot list sessions.")
        }
        let sessions = try await connected.connection.listSessions(
            cwd: all ? nil : agent.directory.path(percentEncoded: false)
        )
        for line in Self.format(sessions) {
            await console.line(line)
        }
        await connected.shutDown()
    }

    static func format(_ sessions: [ACP.SessionInfo]) -> [String] {
        guard !sessions.isEmpty else { return ["No sessions."] }
        return sessions.map { session in
            [session.sessionId, session.updatedAt ?? "-", session.title ?? "(untitled)", session.cwd]
                .joined(separator: "  ")
        }
    }
}

extension Array where Element: Sendable {
    /// The elements as an async sequence.
    var async: AsyncStream<Element> {
        AsyncStream { continuation in
            for element in self {
                continuation.yield(element)
            }
            continuation.finish()
        }
    }
}
