import CryptoKit
import Foundation
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct AgentInstallerTests {
    @Test func replacingThePayloadWithASymlinkCannotLaunchAnExternalCommand() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let store = installer(fixture)
        let installation = try await store.install(agent())
        let payload = fixture.root.appending(path: "Agents/fixture/1.0.0/payload")
        let external = fixture.root.appending(path: "external")
        try FileManager.default.moveItem(at: payload, to: external)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: external)
        await #expect(throws: AgentInstallation.Failure.unownedPath) {
            try await store.acquire(installation, directory: fixture.root)
        }
        try await store.remove(installation)
        #expect(FileManager.default.fileExists(atPath: external.appending(path: "bin/agent").path))
    }

    @Test func cancellationAndConcurrentOperationsPreserveThePreviousVersion() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let store = installer(fixture)
        let first = try await store.install(agent())
        let gate = InstallationDownloadGate()
        let updating = AgentInstaller(
            root: fixture.root.appending(path: "Agents"),
            download: { _, _ in
                await gate.pause()
                throw AgentInstallation.Failure.downloadFailed
            }
        )
        let next = try agent(version: "2.0.0")
        let task = Task { try await updating.install(next) }
        await gate.waitUntilPaused()
        // A download in progress does not block listing, launching or installing the same version elsewhere.
        #expect(try await store.installations() == [first])
        let lease = try await store.acquire(first, directory: fixture.root)
        lease.release()
        let installed = try await store.install(next)
        task.cancel()
        await gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.installations() == [first, installed])
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "Agents").path)
        #expect(!names.contains(where: { $0.hasPrefix(".staging-") }))
    }

    @Test func parallelLaunchesShareTheInstallationWhileTheShellResolves() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let installation = try await installer(fixture).install(agent())
        let gate = InstallationDownloadGate()
        let resolving = AgentInstaller(
            root: fixture.root.appending(path: "Agents"),
            environment: ShellEnvironment(capture: {
                await gate.pause()
                return .init(environment: ["PATH": "/usr/bin:/bin"], diagnostic: nil)
            }),
            download: { _, _ in }
        )
        let first = Task { try await resolving.acquire(installation, directory: fixture.root) }
        await gate.waitUntilPaused()
        let second = Task { try await resolving.acquire(installation, directory: fixture.root) }
        // The second launch waits for the same shell capture instead of failing on the operation lock.
        for _ in 0..<100 { await Task.yield() }
        await gate.resume()
        let leases = try await [first.value, second.value]
        #expect(leases.map(\.installation) == [installation, installation])
        await #expect(throws: AgentInstallation.Failure.installationInUse) {
            try await installer(fixture).remove(installation)
        }
        leases.forEach { $0.release() }
        try await installer(fixture).remove(installation)
    }

    @Test func unmarkedRootsCannotBeAdopted() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let root = fixture.root.appending(path: "Agents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ownerFile = root.appending(path: "keep")
        try Data("owner data".utf8).write(to: ownerFile)
        await #expect(throws: AgentInstallation.Failure.unownedPath) { try await installer(fixture).install(agent()) }
        #expect(try String(contentsOf: ownerFile, encoding: .utf8) == "owner data")
    }

    @Test func installsBinaryVersionsAndLeasesKeepTheOldVersionInUse() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let installer = installer(fixture)
        let first = try await installer.install(agent())
        #expect(first.version == "1.0.0")
        #expect(first.toolchain == nil)
        let lease = try await installer.acquire(first, directory: fixture.root)
        defer { lease.release() }
        #expect(lease.command.arguments == ["--acp", "a b"])
        #expect(lease.command.environment?["FIXTURE"] == "yes")
        #expect(await CommandOutput.capture(lease.command) == .success(Data("fixture\n".utf8), 0))
        let second = try await installer.install(agent(version: "2.0.0"))
        #expect(try await installer.installations().map(\.version) == ["1.0.0", "2.0.0"])
        await #expect(throws: AgentInstallation.Failure.installationInUse) { try await installer.remove(first) }
        try await installer.remove(second)
        #expect(try await installer.installations() == [first])
        // A second store instance still observes leases held by this one.
        let other = self.installer(fixture)
        await #expect(throws: AgentInstallation.Failure.installationInUse) { try await other.remove(first) }
        withExtendedLifetime(lease) {}
    }

    @Test func releaseAllowsRemovalAndReopeningReadsMetadata() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let installer = installer(fixture)
        let installation = try await installer.install(agent())
        let lease = try await installer.acquire(installation, directory: fixture.root)
        lease.release()
        lease.release()
        #expect(try await self.installer(fixture).installations() == [installation])
        try await installer.remove(installation)
        #expect(try await installer.installations().isEmpty)
    }

    @Test func checksumFailureAndFailedUpdatesPreserveWorkingVersions() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let installer = installer(fixture)
        let first = try await installer.install(agent())
        await #expect(throws: AgentInstallation.Failure.checksumMismatch) {
            try await installer.install(agent(version: "2.0.0", checksum: String(repeating: "0", count: 64)))
        }
        #expect(try await installer.installations() == [first])
        await #expect(throws: AgentInstallation.Failure.alreadyInstalled) { try await installer.install(agent()) }
        let hash = SHA256.hash(data: try Data(contentsOf: fixture.archive)).map { String(format: "%02x", $0) }.joined()
        #expect(try await installer.install(agent(version: "2.0.0", checksum: hash)).version == "2.0.0")
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.appending(path: "Agents/fixture").path
        )
        #expect(names.sorted() == ["1.0.0", "2.0.0"])
    }

    @Test func rejectsUnownedDirectoriesAndSymlinkedInstallations() async throws {
        let fixture = try ArchiveFixture()
        defer { fixture.remove() }
        let installer = installer(fixture)
        let installation = try await installer.install(agent())
        let directory = fixture.root.appending(path: "Agents/fixture/1.0.0")
        let kept = fixture.root.appending(path: "kept")
        try FileManager.default.moveItem(at: directory, to: kept)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: kept)
        await #expect(throws: AgentInstallation.Failure.unownedPath) { try await installer.remove(installation) }
        #expect(FileManager.default.fileExists(atPath: kept.appending(path: "installation.json").path))
    }

    private func installer(_ fixture: ArchiveFixture) -> AgentInstaller {
        AgentInstaller(
            root: fixture.root.appending(path: "Agents"),
            environment: ShellEnvironment(capture: {
                .init(environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path], diagnostic: nil)
            }),
            download: { _, target in try FileManager.default.copyItem(at: fixture.archive, to: target) }
        )
    }

    private func agent(version: String = "1.0.0", checksum: String? = nil) throws -> AgentRegistry.Agent {
        var binary: [String: Any] = [
            "archive": "https://example.com/agent.tar", "cmd": "bin/agent", "args": ["--acp", "a b"],
            "env": ["FIXTURE": "yes"],
        ]
        if let checksum { binary["sha256"] = checksum }
        let metadata: [String: Any] = [
            "id": "fixture", "name": "Fixture", "version": version, "description": "Test agent",
            "distribution": ["binary": [AgentRegistry.Platform.current.rawValue: binary]],
        ]
        return try JSONDecoder().decode(
            AgentRegistry.Agent.self,
            from: JSONSerialization.data(withJSONObject: metadata)
        )
    }
}

private actor InstallationDownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilPaused() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
