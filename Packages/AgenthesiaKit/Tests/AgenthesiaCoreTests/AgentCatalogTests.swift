import Foundation
import Testing

@testable import AgentRuntime
@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct AgentCatalogTests {
    @Test func refreshListsTheRegistryAndChecksNodeOnlyWhenAnNpmAgentNeedsIt() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let checks = NodeChecks(results: [.failure(NodeRuntime.Failure.missingNode), .success(fixture.toolchain)])
        let catalog = fixture.catalog(registry: [fixture.binary("1.0.0")], checks: checks)
        await catalog.refresh()
        #expect(catalog.registry?.catalog.agents.map(\.id) == ["fixture"])
        #expect(catalog.registryMessage == nil)
        #expect(!catalog.needsNode)
        #expect(catalog.node == .unknown)
        #expect(await checks.calls.isEmpty)

        let npm = fixture.catalog(registry: [fixture.binary("1.0.0"), fixture.npm()], checks: checks)
        await npm.refresh()
        #expect(npm.needsNode)
        #expect(npm.node == .unavailable(NodeRuntime.Failure.missingNode.localizedDescription))
        await npm.checkAgain()
        #expect(npm.node == .ready(fixture.toolchain))
        // The first check reuses the shell environment; Check Again captures a fresh one.
        #expect(await checks.calls == [false, true])
    }

    @Test func updatesInstallAnotherVersionAndKeepTheOldOne() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let first = try fixture.agent(fixture.binary("1.0.0"))
        let catalog = fixture.catalog(registry: [fixture.binary("1.0.0")])
        await catalog.refresh()
        #expect(!catalog.hasUpdate(first))
        await catalog.install(first)
        #expect(catalog.failures.isEmpty)
        #expect(catalog.operations.isEmpty)
        #expect(catalog.latest.map(\.version) == ["1.0.0"])
        #expect(!catalog.hasUpdate(first))

        let second = try fixture.agent(fixture.binary("2.0.0"))
        #expect(catalog.hasUpdate(second))
        await catalog.install(second)
        #expect(!catalog.hasUpdate(second))
        #expect(catalog.versions(of: "fixture").map(\.version) == ["2.0.0", "1.0.0"])
        #expect(catalog.latest.map(\.version) == ["2.0.0"])
    }

    @Test func removalFailsWhileASessionHoldsTheVersion() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let catalog = fixture.catalog(registry: [])
        await catalog.install(try fixture.agent(fixture.binary("1.0.0")))
        let installation = try #require(catalog.installations.first)
        let lease = try await fixture.installer.acquire(installation, directory: fixture.root)
        await catalog.remove(installation)
        #expect(catalog.failures["fixture"] == AgentInstallation.Failure.installationInUse.localizedDescription)
        #expect(catalog.installations == [installation])
        lease.release()
        await catalog.remove(installation)
        #expect(catalog.failures.isEmpty)
        #expect(catalog.installations.isEmpty)
    }

    @Test func cancellingAnInstallationLeavesNoVersionAndNoFailure() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let gate = DownloadGate()
        let catalog = fixture.catalog(
            registry: [],
            download: { _, _ in
                await gate.pause()
                try Task.checkCancellation()
            }
        )
        let agent = try fixture.agent(fixture.binary("1.0.0"))
        let installing = Task { await catalog.install(agent) }
        await gate.waitUntilPaused()
        #expect(catalog.operations["fixture"] == .installing(version: "1.0.0"))
        catalog.cancel("fixture")
        await gate.resume()
        await installing.value
        #expect(catalog.operations.isEmpty)
        #expect(catalog.failures.isEmpty)
        #expect(catalog.installations.isEmpty)
    }

    @Test func anUnreachableRegistryIsReportedWithoutACatalog() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        let client = AgentRegistry.Client(cacheDirectory: fixture.root.appending(path: "cache")) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let catalog = AgentCatalog(registry: client, installer: fixture.installer) { _ in fixture.toolchain }
        await catalog.refresh()
        #expect(catalog.registry == nil)
        #expect(catalog.registryMessage == AgentRegistry.Failure.networkUnavailable.localizedDescription)
    }
}

private actor NodeChecks {
    var results: [Result<NodeRuntime.Toolchain, any Error>]
    private(set) var calls: [Bool] = []
    init(results: [Result<NodeRuntime.Toolchain, any Error>]) { self.results = results }
    func next(refresh: Bool) throws -> NodeRuntime.Toolchain {
        calls.append(refresh)
        return try results.removeFirst().get()
    }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilPaused() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}

/// A temporary installer whose binary distribution is a one-line script archive.
private struct CatalogFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "agh-catalog-\(UUID())")
    let installer: AgentInstaller
    let toolchain = NodeRuntime.Toolchain(node: "/node", npm: "/npm", nodeVersion: "22.0.0", npmVersion: "10.0.0")
    private let archive: URL

    init() throws {
        archive = root.appending(path: "agent.tar")
        let bin = root.appending(path: "archive/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho fixture\n".utf8).write(to: bin.appending(path: "agent"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bin.appending(path: "agent").path
        )
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cf", archive.path, "-C", root.appending(path: "archive").path, "bin"]
        try tar.run()
        tar.waitUntilExit()
        try #require(tar.terminationStatus == 0)
        installer = Self.installer(root: root, archive: archive)
    }

    private static func installer(
        root: URL,
        archive: URL,
        download: (@Sendable (URL, URL) async throws -> Void)? = nil
    ) -> AgentInstaller {
        AgentInstaller(
            root: root.appending(path: "Agents"),
            environment: ShellEnvironment(capture: { .init(environment: ["PATH": "/usr/bin:/bin"], diagnostic: nil) }),
            download: { url, target in
                try await download?(url, target)
                try FileManager.default.copyItem(at: archive, to: target)
            }
        )
    }

    func catalog(
        registry agents: [[String: Any]],
        checks: NodeChecks = NodeChecks(results: []),
        download: (@Sendable (URL, URL) async throws -> Void)? = nil
    ) -> AgentCatalog {
        let data = try! JSONSerialization.data(withJSONObject: ["version": "1.0.0", "agents": agents])
        let client = AgentRegistry.Client(cacheDirectory: root.appending(path: "cache-\(UUID())")) { _ in
            .init(status: 200, data: data)
        }
        let installer = download.map { Self.installer(root: root, archive: archive, download: $0) } ?? installer
        return AgentCatalog(registry: client, installer: installer) { try await checks.next(refresh: $0) }
    }

    func agent(_ metadata: [String: Any]) throws -> AgentRegistry.Agent {
        try JSONDecoder().decode(AgentRegistry.Agent.self, from: JSONSerialization.data(withJSONObject: metadata))
    }

    func binary(_ version: String) -> [String: Any] {
        [
            "id": "fixture", "name": "Fixture", "version": version, "description": "Test agent",
            "distribution": [
                "binary": [
                    AgentRegistry.Platform.current.rawValue: [
                        "archive": "https://example.com/agent.tar", "cmd": "bin/agent",
                    ]
                ]
            ],
        ]
    }

    func npm() -> [String: Any] {
        [
            "id": "npm-agent", "name": "Npm Agent", "version": "1.0.0", "description": "Test agent",
            "distribution": ["npx": ["package": "npm-agent@1.0.0"]],
        ]
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
