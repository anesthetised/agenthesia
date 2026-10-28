/// Known ACP commands and ordinary agent CLIs, found on `PATH` without running them (ADR-0037).
public enum LocalAgentDiscovery {
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// The command name looked up on `PATH`.
        public let executable: String
        /// The arguments that start ACP over stdio; empty for a CLI that needs an adapter.
        public let arguments: [String]
        /// The registry agent this command belongs to.
        public let registryID: String
        /// For an ordinary CLI: the registry agent that adapts it to ACP.
        public let adapterID: String?

        public init(name: String, executable: String, arguments: [String], registryID: String, adapterID: String? = nil)
        {
            self.name = name
            self.executable = executable
            self.arguments = arguments
            self.registryID = registryID
            self.adapterID = adapterID
        }
    }

    public struct Found: Equatable, Sendable, Identifiable {
        public let entry: Entry
        /// The first match on `PATH`, not resolved through symlinks.
        public let path: String
        public var id: String { path }
    }

    /// Commands and flags as the ACP Registry lists them, by the command name their packages install.
    public static let known: [Entry] = [
        Entry(name: "Amp", executable: "amp-acp", arguments: [], registryID: "amp-acp"),
        Entry(name: "Auggie CLI", executable: "auggie", arguments: ["--acp"], registryID: "auggie"),
        Entry(name: "Claude Agent", executable: "claude-agent-acp", arguments: [], registryID: "claude-acp"),
        Entry(name: "Cline", executable: "cline", arguments: ["--acp"], registryID: "cline"),
        Entry(name: "Codex", executable: "codex-acp", arguments: [], registryID: "codex-acp"),
        Entry(name: "Copilot", executable: "copilot", arguments: ["--acp"], registryID: "github-copilot-cli"),
        Entry(name: "Cursor", executable: "cursor-agent", arguments: ["acp"], registryID: "cursor"),
        Entry(name: "Devin", executable: "devin", arguments: ["acp"], registryID: "devin"),
        Entry(
            name: "Factory Droid",
            executable: "droid",
            arguments: ["exec", "--output-format", "acp-daemon"],
            registryID: "factory-droid"
        ),
        Entry(name: "Gemini CLI", executable: "gemini", arguments: ["--acp"], registryID: "gemini"),
        Entry(name: "goose", executable: "goose", arguments: ["acp"], registryID: "goose"),
        Entry(name: "Kilo", executable: "kilo", arguments: ["acp"], registryID: "kilo"),
        Entry(name: "Kimi CLI", executable: "kimi", arguments: ["acp"], registryID: "kimi"),
        Entry(name: "Mistral Vibe", executable: "vibe-acp", arguments: [], registryID: "mistral-vibe"),
        Entry(name: "OpenCode", executable: "opencode", arguments: ["acp"], registryID: "opencode"),
        Entry(name: "Qwen Code", executable: "qwen", arguments: ["--acp"], registryID: "qwen-code"),
        Entry(name: "Stakpak", executable: "stakpak", arguments: ["acp"], registryID: "stakpak"),
        Entry(name: "VT Code", executable: "vtcode", arguments: ["acp"], registryID: "vtcode"),
        Entry(
            name: "Claude Code",
            executable: "claude",
            arguments: [],
            registryID: "claude-acp",
            adapterID: "claude-acp"
        ),
        Entry(name: "Codex CLI", executable: "codex", arguments: [], registryID: "codex-acp", adapterID: "codex-acp"),
    ]

    /// The entries whose command is an executable file in an absolute `PATH` directory, in table order.
    public static func discover(path: String?, entries: [Entry] = known) -> [Found] {
        entries.compactMap { entry in
            NodeRuntime.find(entry.executable, in: ["PATH": path ?? ""]).map { Found(entry: entry, path: $0) }
        }
    }
}
