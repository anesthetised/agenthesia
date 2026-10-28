public import ACP
public import AgentRuntime
public import Foundation
import Observation

/// Registry agents, installed versions and local agents, shown in Settings → Agents and offered by the launch
/// form (ADR-0036, ADR-0037). Installation, updates and removal go through `AgentInstaller`; nothing runs
/// automatically.
@MainActor @Observable
public final class AgentCatalog {
    public static let shared = AgentCatalog(
        registry: AgentRegistry.Client(
            cacheDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Agenthesia/Registry")
        ),
        installer: SessionLibrary.shared.installer,
        runtime: NodeRuntime()
    )

    public enum NodeStatus: Equatable, Sendable {
        case unknown, checking
        case ready(NodeRuntime.Toolchain)
        case unavailable(String)
    }

    public enum Operation: Equatable, Sendable {
        case installing(version: String)
        case removing
    }

    /// The result of an initialize probe (ADR-0037).
    public enum Check: Equatable, Sendable {
        case checking
        case passed(ACP.AgentProfile)
        case failed(String)
    }

    /// Where the list of local agents is kept.
    public static let localAgentsKey = "localAgents"

    public private(set) var registry: AgentRegistry.Snapshot?
    /// Why the registry could not be loaded, or a warning about the catalog shown.
    public private(set) var registryMessage: String?
    /// Why the installed versions could not be read.
    public private(set) var installationsMessage: String?
    public private(set) var isRefreshing = false
    /// Every installed version, newest installation first.
    public private(set) var installations: [AgentInstallation] = []
    public private(set) var node = NodeStatus.unknown
    /// Operations in progress, by registry agent ID.
    public private(set) var operations: [String: Operation] = [:]
    /// The last failure of an operation, by registry agent ID.
    public private(set) var failures: [String: String] = [:]
    /// Agents the user added from discovery or as a custom command, in the order added.
    public private(set) var localAgents: [LocalAgent]
    /// Known commands on the login shell's `PATH`, in table order.
    public private(set) var found: [LocalAgentDiscovery.Found] = []
    /// The latest initialize probe of each command checked.
    public private(set) var checks: [LocalAgent.Command: Check] = [:]
    /// The one sign-in presented in Settings, retained until its processes have stopped (ADR-0038).
    public private(set) var signIn: AgentSignIn?
    private var isQuitting = false

    @ObservationIgnored private let client: AgentRegistry.Client
    @ObservationIgnored private let installer: AgentInstaller
    @ObservationIgnored private let checkNode: @Sendable (_ refresh: Bool) async throws -> NodeRuntime.Toolchain
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: @Sendable (_ refresh: Bool) async -> [String: String]
    @ObservationIgnored private let probe: @Sendable (AgentCommand) async throws -> ACP.AgentProfile

    public convenience init(
        registry: AgentRegistry.Client,
        installer: AgentInstaller,
        runtime: NodeRuntime,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            registry: registry,
            installer: installer,
            defaults: defaults,
            environment: {
                await ($0 ? ShellEnvironment.shared.refresh() : ShellEnvironment.shared.resolve()).environment
            },
            probe: { try await AgentProbe.run($0) },
            checkNode: { try await runtime.discover(refresh: $0).toolchain }
        )
    }

    init(
        registry: AgentRegistry.Client,
        installer: AgentInstaller,
        defaults: UserDefaults,
        environment: @escaping @Sendable (_ refresh: Bool) async -> [String: String],
        probe: @escaping @Sendable (AgentCommand) async throws -> ACP.AgentProfile,
        checkNode: @escaping @Sendable (_ refresh: Bool) async throws -> NodeRuntime.Toolchain
    ) {
        client = registry
        self.installer = installer
        self.defaults = defaults
        self.environment = environment
        self.probe = probe
        self.checkNode = checkNode
        localAgents =
            defaults.data(forKey: Self.localAgentsKey).flatMap {
                try? JSONDecoder().decode([LocalAgent].self, from: $0)
            }
            ?? []
    }

    /// The newest installed version of each agent, by name: what the launch form offers.
    public var latest: [AgentInstallation] {
        var seen = Set<String>()
        return installations.filter { seen.insert($0.agentID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Pins the selected version; an update cannot change the command during sign-in.
    @discardableResult public func beginSignIn(_ installation: AgentInstallation) -> AgentSignIn? {
        guard signIn == nil, !isQuitting, installations.contains(where: { $0.id == installation.id }) else {
            return nil
        }
        let installer = installer
        let flow = AgentSignIn(name: "\(installation.name) \(installation.version)") { directory in
            let lease = try await installer.acquire(installation, directory: directory)
            return (lease.command, lease)
        }
        signIn = flow
        return flow
    }

    @discardableResult public func beginSignIn(_ agent: LocalAgent) -> AgentSignIn? {
        guard signIn == nil, !isQuitting, localAgents.contains(agent) else { return nil }
        let environment = environment
        let flow = AgentSignIn(name: agent.name) { directory in
            let command = AgentCommand(
                executable: agent.command.executable,
                arguments: agent.command.arguments,
                environment: await environment(false),
                currentDirectory: directory
            )
            return (command, nil)
        }
        signIn = flow
        return flow
    }

    /// A late dismissal of an older sheet must not dismiss its successor.
    public func closeSignIn(_ flow: AgentSignIn) async {
        await flow.close()
        if signIn === flow { signIn = nil }
    }

    /// Prevents a new flow while application termination waits for other session work.
    public func closeSignInForQuit() async {
        isQuitting = true
        if let signIn { await closeSignIn(signIn) }
    }

    /// Installed versions of an agent, newest installation first.
    public func versions(of agentID: String) -> [AgentInstallation] {
        installations.filter { $0.agentID == agentID }
    }

    /// The registry offers a version that is not installed, and an older one is.
    public func hasUpdate(_ agent: AgentRegistry.Agent) -> Bool {
        let installed = versions(of: agent.id)
        return !installed.isEmpty && !installed.contains { $0.version == agent.version }
    }

    /// Whether Node.js and npm matter: an npm agent is offered or installed.
    public var needsNode: Bool {
        installations.contains { $0.toolchain != nil }
            || registry?.catalog.agents.contains {
                if case .npm = $0.installation() { true } else { false }
            } == true
    }

    /// Found ACP commands that are not local agents yet.
    public var addable: [LocalAgentDiscovery.Found] {
        found.filter { item in item.entry.adapterID == nil && !localAgents.contains { $0.command == item.command } }
    }

    /// Ordinary CLIs whose ACP adapter is neither installed, found nor added.
    public var suggestions: [LocalAgentDiscovery.Found] {
        found.filter { item in
            guard let adapter = item.entry.adapterID else { return false }
            return versions(of: adapter).isEmpty
                && !found.contains { $0.entry.adapterID == nil && $0.entry.registryID == adapter }
                && !localAgents.contains { $0.registryID == adapter }
        }
    }

    /// Loads the installed versions and local commands, then the registry, then checks Node.js if an npm
    /// agent needs it.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await reloadInstallations()
        await discover(refresh: false)
        do {
            let snapshot = try await client.refresh()
            registry = snapshot
            registryMessage = snapshot.warning?.localizedDescription
        } catch is CancellationError {
            return
        } catch {
            registryMessage = error.localizedDescription
        }
        if node == .unknown, needsNode { await checkRuntime(refresh: false) }
    }

    /// Reads the installed versions again, e.g. when the launch form appears.
    public func reloadInstallations() async {
        do {
            installations = try await installer.installations().sorted { $0.installedAt > $1.installedAt }
            installationsMessage = nil
        } catch {
            installationsMessage = error.localizedDescription
        }
    }

    /// Looks for known commands on the login shell's `PATH` without running them; `refresh` captures the
    /// login shell again, e.g. after the user installed an agent.
    public func discover(refresh: Bool) async {
        let path = await environment(refresh)["PATH"]
        found = LocalAgentDiscovery.discover(path: path)
    }

    /// Adds a found command as a local agent.
    public func add(_ found: LocalAgentDiscovery.Found) {
        add(LocalAgent(name: found.entry.name, command: found.command, registryID: found.entry.registryID))
    }

    /// Adds any command as a local agent.
    public func addCustom(name: String, executable: String, arguments: [String]) {
        add(LocalAgent(name: name, command: .init(executable: executable, arguments: arguments), registryID: nil))
    }

    private func add(_ agent: LocalAgent) {
        guard !localAgents.contains(where: { $0.command == agent.command }) else { return }
        save(localAgents + [agent])
    }

    /// Removes a local agent from the list; its sessions keep their own record of the command.
    public func remove(_ agent: LocalAgent) {
        save(localAgents.filter { $0.id != agent.id })
    }

    private func save(_ agents: [LocalAgent]) {
        localAgents = agents
        defaults.set(try? JSONEncoder().encode(agents), forKey: Self.localAgentsKey)
    }

    /// Runs the command briefly to ask whether it speaks ACP, with the login shell's environment.
    public func check(_ command: LocalAgent.Command) async {
        guard checks[command] != .checking else { return }
        checks[command] = .checking
        let agent = AgentCommand(
            executable: command.executable,
            arguments: command.arguments,
            environment: await environment(false)
        )
        do {
            checks[command] = .passed(try await probe(agent))
        } catch is CancellationError {
            checks[command] = nil
        } catch {
            checks[command] = .failed(error.localizedDescription)
        }
    }

    /// Captures a fresh login-shell environment and checks Node.js and npm again (ADR-0034).
    public func checkAgain() async {
        await checkRuntime(refresh: true)
    }

    private func checkRuntime(refresh: Bool) async {
        node = .checking
        do {
            node = .ready(try await checkNode(refresh))
        } catch is CancellationError {
            node = .unknown
        } catch {
            node = .unavailable(error.localizedDescription)
        }
    }

    /// Installs the registry's current version. An update is the same: the older version stays installed.
    public func install(_ agent: AgentRegistry.Agent) async {
        guard operations[agent.id] == nil else { return }
        let installer = installer
        await run(.installing(version: agent.version), for: agent.id) {
            _ = try await installer.install(agent)
        }
    }

    /// Removes an installed version that no session runs.
    public func remove(_ installation: AgentInstallation) async {
        guard operations[installation.agentID] == nil else { return }
        let installer = installer
        await run(.removing, for: installation.agentID) { try await installer.remove(installation) }
    }

    /// Stops an installation in progress; its partial files are removed and installed versions are kept.
    public func cancel(_ agentID: String) {
        tasks[agentID]?.cancel()
    }

    private func run(
        _ operation: Operation,
        for agentID: String,
        _ body: @escaping @Sendable () async throws -> Void
    ) async {
        operations[agentID] = operation
        failures[agentID] = nil
        let task = Task {
            do {
                try await body()
            } catch is CancellationError {
            } catch {
                self.failures[agentID] = error.localizedDescription
            }
        }
        tasks[agentID] = task
        await task.value
        tasks[agentID] = nil
        operations[agentID] = nil
        await reloadInstallations()
    }
}
