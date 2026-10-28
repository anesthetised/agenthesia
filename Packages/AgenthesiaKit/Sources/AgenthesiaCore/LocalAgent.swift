public import AgentRuntime
public import Foundation

/// A command the user added in Settings → Agents, found on `PATH` or entered by hand (ADR-0037). Agenthesia
/// does not own its files: it is neither versioned nor leased.
public struct LocalAgent: Codable, Equatable, Identifiable, Sendable {
    public struct Command: Codable, Hashable, Sendable {
        public let executable: String
        public let arguments: [String]

        public init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    public let id: UUID
    public let name: String
    public let command: Command
    /// The registry agent of a found command; `nil` for a custom one.
    public let registryID: String?

    public init(id: UUID = UUID(), name: String, command: Command, registryID: String?) {
        self.id = id
        self.name = name
        self.command = command
        self.registryID = registryID
    }
}

extension LocalAgentDiscovery.Found {
    public var command: LocalAgent.Command { .init(executable: path, arguments: entry.arguments) }
}
