import Foundation
import Persistence
import Testing

@testable import AgentRuntime
@testable import AgenthesiaCore

/// Sessions of registry installations launch through their lease (ADR-0036).
@MainActor @Suite(.timeLimit(.minutes(1))) struct InstalledAgentSessionTests {
    @Test func installedVersionLaunchesThroughItsLeaseAndKeepsItsHistoryRow() async throws {
        let fixture = try InstalledMockFixture()
        defer { fixture.remove() }
        let installation = try await fixture.installer.install(fixture.agent(version: "1.0.0"))
        let owner = LiveSession(library: fixture.library)
        await owner.start(directory: fixture.project, agent: AgentInstallRecord(installation: installation))
        let controller = try #require(owner.controller)
        #expect(owner.errorMessage == nil)
        #expect(controller.status == .idle)
        await owner.send("hello")
        #expect(controller.transcript.items.last?.message?.text == "Echo: hello")
        // The running session keeps its version in place.
        await #expect(throws: AgentInstallation.Failure.installationInUse) {
            try await fixture.installer.remove(installation)
        }
        await owner.close()
        let rows = try await fixture.library.store().agentInstalls()
        #expect(rows.map(\.installationID) == [installation.id])
        #expect(rows.first?.name == "Mock")
        #expect(try await fixture.library.history().first?.agentInstallID == rows.first?.id)
        try await fixture.installer.remove(installation)
    }

    @Test func parallelStartsShareOneRowAndContinueNamesARemovedVersion() async throws {
        let fixture = try InstalledMockFixture()
        defer { fixture.remove() }
        let installation = try await fixture.installer.install(fixture.agent(version: "1.0.0"))
        let owners = [LiveSession(library: fixture.library), LiveSession(library: fixture.library)]
        async let first: Void = owners[0].start(
            directory: fixture.project,
            agent: AgentInstallRecord(installation: installation)
        )
        async let second: Void = owners[1].start(
            directory: fixture.project,
            agent: AgentInstallRecord(installation: installation)
        )
        _ = await (first, second)
        #expect(owners.map(\.errorMessage) == [nil, nil])
        #expect(owners.compactMap(\.controller?.status) == [.idle, .idle])
        #expect(try await fixture.library.store().agentInstalls().count == 1)
        for owner in owners { await owner.close() }
        try await fixture.installer.remove(installation)

        let saved = try #require(try await fixture.library.history().first)
        let resumed = LiveSession(library: fixture.library)
        await resumed.resume(saved)
        #expect(resumed.controller == nil)
        #expect(resumed.errorMessage?.contains("version of Mock this session used is no longer installed") == true)
        await resumed.close()
    }

    @Test func aFailedLaunchReleasesTheLease() async throws {
        let fixture = try InstalledMockFixture()
        defer { fixture.remove() }
        let installation = try await fixture.installer.install(fixture.agent(version: "1.0.0"))
        let owner = LiveSession(library: fixture.library)
        // A missing project directory fails after the lease was taken.
        await owner.start(
            directory: fixture.project.appending(path: "missing"),
            agent: AgentInstallRecord(installation: installation)
        )
        #expect(owner.errorMessage != nil)
        try await fixture.installer.remove(installation)
        await owner.close()
    }
}

/// A temporary installer whose binary distribution is the bundled MockAgent.
struct InstalledMockFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "agh-installed-\(UUID())")
    let installer: AgentInstaller
    let library: SessionLibrary
    var project: URL { root.appending(path: "project") }

    init() throws {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        let bin = root.appending(path: "archive/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "project"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: bin.appending(path: "mock-agent"))
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = [
            "-cf", root.appending(path: "mock.tar").path, "-C", root.appending(path: "archive").path, "bin",
        ]
        try tar.run()
        tar.waitUntilExit()
        try #require(tar.terminationStatus == 0)
        let archive = root.appending(path: "mock.tar")
        let environment = ProcessInfo.processInfo.environment
        installer = AgentInstaller(
            root: root.appending(path: "Agents"),
            environment: ShellEnvironment(capture: { .init(environment: environment, diagnostic: nil) }),
            download: { _, target in try FileManager.default.copyItem(at: archive, to: target) }
        )
        library = SessionLibrary(databaseURL: root.appending(path: "data/history.sqlite"), installer: installer)
    }

    func agent(version: String) throws -> AgentRegistry.Agent {
        let metadata: [String: Any] = [
            "id": "mock", "name": "Mock", "version": version, "description": "Echo agent",
            "license": "GPL-3.0",
            "distribution": [
                "binary": [
                    AgentRegistry.Platform.current.rawValue: [
                        "archive": "https://example.com/mock.tar", "cmd": "bin/mock-agent",
                    ]
                ]
            ],
        ]
        return try JSONDecoder().decode(
            AgentRegistry.Agent.self,
            from: JSONSerialization.data(withJSONObject: metadata)
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
