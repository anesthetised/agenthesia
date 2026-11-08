public import ACP
public import AgentRuntime
public import Foundation
import Observation
public import Persistence

/// Registry agents, installed versions and local agents, shown in Settings → Agents and offered by the draft's
/// Agent chip (ADR-0036, ADR-0037, ADR-0040). Installation, updates and removal go through `AgentInstaller`; nothing runs
/// automatically.
@MainActor @Observable
public final class AgentCatalog {
    public static let shared = AgentCatalog(
        registry: AgentRegistry.Client(
            cacheDirectory: AppSupport.directory.appending(path: "Registry")
        ),
        installer: SessionLibrary.shared.installer,
        runtime: NodeRuntime(),
        sessionCount: savedSessionCount
    )

    /// How many saved sessions in the app's history use an installed version; nil when history cannot be read.
    nonisolated private static func savedSessionCount(_ installationID: UUID) async -> Int? {
        try? await SessionLibrary.shared.sessionCount(usingInstallation: installationID)
    }

    public enum NodeStatus: Equatable, Sendable {
        case unknown, checking
        case ready(NodeRuntime.Toolchain)
        case unavailable(String)
    }

    /// A removal waiting for the user's confirmation: the version, and how many saved sessions use it when known.
    public struct RemovalRequest: Equatable, Sendable {
        public let installation: AgentInstallation
        public let sessionCount: Int?
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

    /// An agent the draft offers (ADR-0040): an installed agent's newest version, a local agent or a custom command.
    public enum Choice: Codable, Hashable, Sendable {
        case installed(agentID: String)
        case local(UUID)
        case custom(LocalAgent.Command)
    }

    /// Where the list of local agents is kept.
    public static let localAgentsKey = "localAgents"
    /// Where the agent of the last session started from the draft is kept.
    public static let lastChoiceKey = "lastAgent"
    /// Where each agent's last confirmed mode and model are kept, as the draft's hints (ADR-0040).
    public static let configHintsKey = "configHints"
    /// Where the agents whose last session start met `auth_required` are kept, as each choice's JSON.
    public static let signInNeededKey = "signInNeeded"

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
    /// The agent the last session was started with from the draft; a default, not a setting (ADR-0040).
    public private(set) var lastChoice: Choice?
    /// Each agent's mode and model select options as last confirmed, with their choices and names: the draft's
    /// hints (ADR-0040). Safe to lose; an entry that cannot be decoded is ignored.
    public private(set) var configHints: [Choice: [ACP.ConfigOption]]
    /// The removal the user is asked to confirm; nothing is removed until `confirmRemoval`.
    public private(set) var removalRequest: RemovalRequest?
    /// Agents whose last session start met `auth_required` and that no sign-in or clean start has cleared since: the
    /// only ones whose row offers Sign In… as a button, because ACP cannot tell whether the user is signed in.
    public private(set) var signInNeeded: Set<Choice>
    private var isQuitting = false
    /// The agent the open Settings sign-in belongs to.
    @ObservationIgnored private var signInChoice: Choice?

    @ObservationIgnored private let client: AgentRegistry.Client
    @ObservationIgnored private let installer: AgentInstaller
    @ObservationIgnored private let checkNode: @Sendable (_ refresh: Bool) async throws -> NodeRuntime.Toolchain
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: @Sendable (_ refresh: Bool) async -> [String: String]
    @ObservationIgnored private let probe: @Sendable (AgentCommand) async throws -> ACP.AgentProfile
    @ObservationIgnored private let sessionCount: @Sendable (_ installationID: UUID) async -> Int?

    public convenience init(
        registry: AgentRegistry.Client,
        installer: AgentInstaller,
        runtime: NodeRuntime,
        defaults: UserDefaults = .standard,
        sessionCount: @escaping @Sendable (_ installationID: UUID) async -> Int? = { _ in nil }
    ) {
        self.init(
            registry: registry,
            installer: installer,
            defaults: defaults,
            environment: {
                await ($0 ? ShellEnvironment.shared.refresh() : ShellEnvironment.shared.resolve()).environment
            },
            probe: { try await AgentProbe.run($0) },
            checkNode: { try await runtime.discover(refresh: $0).toolchain },
            sessionCount: sessionCount
        )
    }

    init(
        registry: AgentRegistry.Client,
        installer: AgentInstaller,
        defaults: UserDefaults,
        environment: @escaping @Sendable (_ refresh: Bool) async -> [String: String],
        probe: @escaping @Sendable (AgentCommand) async throws -> ACP.AgentProfile,
        checkNode: @escaping @Sendable (_ refresh: Bool) async throws -> NodeRuntime.Toolchain,
        sessionCount: @escaping @Sendable (_ installationID: UUID) async -> Int? = { _ in nil }
    ) {
        client = registry
        self.sessionCount = sessionCount
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
        lastChoice = defaults.data(forKey: Self.lastChoiceKey).flatMap {
            try? JSONDecoder().decode(Choice.self, from: $0)
        }
        let stored = defaults.dictionary(forKey: Self.configHintsKey) ?? [:]
        configHints = Dictionary(
            stored.compactMap { key, value in
                guard let value = value as? Data,
                    let choice = try? JSONDecoder().decode(Choice.self, from: Data(key.utf8)),
                    let options = try? JSONDecoder().decode([ACP.ConfigOption].self, from: value)
                else { return nil }
                return (choice, options)
            },
            uniquingKeysWith: { first, _ in first }
        )
        signInNeeded = Set(
            (defaults.stringArray(forKey: Self.signInNeededKey) ?? []).compactMap {
                try? JSONDecoder().decode(Choice.self, from: Data($0.utf8))
            }
        )
    }

    /// The newest installed version of each agent, by name: what the draft offers.
    public var latest: [AgentInstallation] {
        var seen = Set<String>()
        return installations.filter { seen.insert($0.agentID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// What the Agent chip lists: installed agents (newest version each), then local agents.
    public var choices: [Choice] {
        latest.map { .installed(agentID: $0.agentID) } + localAgents.map { .local($0.id) }
    }

    /// The last agent while it is still offered, else the first in the list.
    public var defaultChoice: Choice? {
        if let lastChoice, record(for: lastChoice) != nil { return lastChoice }
        return choices.first
    }

    /// The history row a session with this agent records; nil once the agent is no longer installed or listed.
    public func record(for choice: Choice) -> AgentInstallRecord? {
        switch choice {
        case .installed(let agentID):
            latest.first { $0.agentID == agentID }.map(AgentInstallRecord.init(installation:))
        case .local(let id):
            localAgents.first { $0.id == id }.map {
                AgentInstallRecord(name: $0.name, executable: $0.command.executable, arguments: $0.command.arguments)
            }
        case .custom(let command): Self.record(custom: command)
        }
    }

    /// A custom command is named after its executable.
    public static func record(custom command: LocalAgent.Command) -> AgentInstallRecord {
        AgentInstallRecord(
            name: URL(filePath: command.executable).lastPathComponent,
            executable: command.executable,
            arguments: command.arguments
        )
    }

    /// The name the Agent chip shows: an installed agent with its version.
    public func name(of choice: Choice) -> String? {
        if case .installed(let agentID) = choice, let installed = latest.first(where: { $0.agentID == agentID }) {
            return "\(installed.name) \(installed.version)"
        }
        return record(for: choice)?.name
    }

    /// Remembers the agent a session was started with across launches.
    public func remember(_ choice: Choice) {
        lastChoice = choice
        defaults.set(try? JSONEncoder().encode(choice), forKey: Self.lastChoiceKey)
    }

    /// Keeps the mode, model and effort select options of a confirmed list as the agent's hints; a list without them
    /// removes the entry. One JSON value per agent, keyed by the choice's JSON.
    public func rememberHints(_ options: [ACP.ConfigOption], for choice: Choice) {
        let hints = options.filter {
            guard case .select = $0.value else { return false }
            return $0.category == .mode || $0.category == .model || $0.category == .thoughtLevel
        }
        guard configHints[choice] != (hints.isEmpty ? nil : hints) else { return }
        configHints[choice] = hints.isEmpty ? nil : hints
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let stored = configHints.compactMap { choice, options -> (String, Data)? in
            guard let key = try? encoder.encode(choice), let value = try? encoder.encode(options) else { return nil }
            return (String(decoding: key, as: UTF8.self), value)
        }
        defaults.set(Dictionary(stored, uniquingKeysWith: { first, _ in first }), forKey: Self.configHintsKey)
    }

    /// The same for a session's agent: an installed version counts as its agent, a command as the local agent that
    /// runs it, else as a custom command. A version that is no longer installed keeps nothing.
    public func rememberHints(_ options: [ACP.ConfigOption], for agent: AgentInstallRecord) {
        if let choice = choice(for: agent) { rememberHints(options, for: choice) }
    }

    private func choice(for agent: AgentInstallRecord) -> Choice? {
        if let id = agent.installationID {
            return installations.first { $0.id == id }.map { .installed(agentID: $0.agentID) }
        }
        let command = LocalAgent.Command(executable: agent.executable, arguments: agent.arguments)
        return localAgents.first { $0.command == command }.map { .local($0.id) } ?? .custom(command)
    }

    /// Records that a session start of this agent did (`needed`) or did not meet `auth_required`; a sign-in that
    /// succeeded counts as the latter.
    public func setSignInNeeded(_ needed: Bool, for choice: Choice) {
        guard needed != signInNeeded.contains(choice) else { return }
        if needed { signInNeeded.insert(choice) } else { signInNeeded.remove(choice) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let stored = signInNeeded.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        defaults.set(stored.sorted(), forKey: Self.signInNeededKey)
    }

    /// The same for a session's agent, as with its hints.
    public func setSignInNeeded(_ needed: Bool, for agent: AgentInstallRecord) {
        if let choice = choice(for: agent) { setSignInNeeded(needed, for: choice) }
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
        signInChoice = .installed(agentID: installation.agentID)
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
        signInChoice = .local(agent.id)
        return flow
    }

    /// A late dismissal of an older sheet must not dismiss its successor.
    public func closeSignIn(_ flow: AgentSignIn) async {
        if flow.state == .completed, signIn === flow, let signInChoice { setSignInNeeded(false, for: signInChoice) }
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

    /// Reads the installed versions again, e.g. when the draft appears.
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

    /// Asks to remove a version: counts the saved sessions that use it and waits for `confirmRemoval` or
    /// `cancelRemoval`.
    public func requestRemoval(of installation: AgentInstallation) async {
        let count = await sessionCount(installation.id)
        removalRequest = RemovalRequest(installation: installation, sessionCount: count)
    }

    /// Removes the version of a request the user confirmed. The dialog's dismissal may cancel the request first, so
    /// the removal does not depend on it still being pending.
    public func confirmRemoval(_ request: RemovalRequest) async {
        removalRequest = nil
        await remove(request.installation)
    }

    public func cancelRemoval() {
        removalRequest = nil
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
