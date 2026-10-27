public import AgentRuntime
public import Foundation
import Observation

/// Registry agents and installed versions, shown in Settings → Agents and offered by the launch form
/// (ADR-0036). Installation, updates and removal go through `AgentInstaller`; nothing runs automatically.
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

    @ObservationIgnored private let client: AgentRegistry.Client
    @ObservationIgnored private let installer: AgentInstaller
    @ObservationIgnored private let checkNode: @Sendable (_ refresh: Bool) async throws -> NodeRuntime.Toolchain
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    public nonisolated convenience init(registry: AgentRegistry.Client, installer: AgentInstaller, runtime: NodeRuntime)
    {
        self.init(registry: registry, installer: installer) { try await runtime.discover(refresh: $0).toolchain }
    }

    nonisolated init(
        registry: AgentRegistry.Client,
        installer: AgentInstaller,
        checkNode: @escaping @Sendable (_ refresh: Bool) async throws -> NodeRuntime.Toolchain
    ) {
        client = registry
        self.installer = installer
        self.checkNode = checkNode
    }

    /// The newest installed version of each agent, by name: what the launch form offers.
    public var latest: [AgentInstallation] {
        var seen = Set<String>()
        return installations.filter { seen.insert($0.agentID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    /// Loads the installed versions, then the registry, then checks Node.js if an npm agent needs it.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await reloadInstallations()
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
