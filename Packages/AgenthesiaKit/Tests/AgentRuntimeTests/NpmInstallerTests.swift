import Foundation
import Synchronization
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct NpmInstallerTests {
    @Test func pinsPackageAndRuntimeRetainsLockfileAndLaunchesWithoutNpx() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let commands = InstallationCommandLog()
        let installer = installer(fixture, commands: commands)
        let installation = try await installer.install(agent())
        #expect(installation.toolchain?.node == fixture.node.path)
        let payload = fixture.root.appending(path: "Agents/npm-fixture/1.0.0/payload")
        let manifest =
            try JSONSerialization.jsonObject(with: Data(contentsOf: payload.appending(path: "package.json")))
            as? [String: Any]
        #expect(manifest?["dependencies"] as? [String: String] == ["@fixture/agent": "1.0.0"])
        #expect(FileManager.default.fileExists(atPath: payload.appending(path: "package-lock.json").path))
        let lease = try await installer.acquire(installation, directory: fixture.root)
        defer { lease.release() }
        #expect(lease.command.executable == fixture.node.path)
        #expect(
            lease.command.arguments == [payload.appending(path: "node_modules/@fixture/agent/entry.js").path, "--acp"]
        )
        #expect(lease.command.environment?["FIXTURE"] == "yes")
        #expect(lease.command.environment?["NODE_OPTIONS"] == nil)
        let captured = commands.values.withLock { $0 }
        #expect(captured.count == 2)
        #expect(captured[0].arguments.contains("@fixture/agent@1.0.0"))
        #expect(captured[1].arguments.contains("--ignore-scripts=true"))
        #expect(captured[1].arguments.contains("--global=false"))
        #expect(captured.allSatisfy { $0.executable == fixture.node.path && $0.arguments.first == fixture.npm.path })
    }

    @Test func removedRuntimeRefusesLaterLaunch() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let installer = installer(fixture)
        let installation = try await installer.install(agent())
        try FileManager.default.removeItem(at: fixture.node)
        await #expect(throws: NodeRuntime.Failure.missingNode) {
            try await installer.acquire(installation, directory: fixture.root)
        }
        // A failed acquire must release its file lock immediately.
        try await installer.remove(installation)
    }

    @Test(arguments: ["../../escape.js", "/tmp/escape.js", "entry\u{0}.js"])
    func rejectsUnsafePackageBins(_ bin: String) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let installer = installer(fixture, bin: bin)
        await #expect(throws: AgentInstallation.Failure.invalidPackage) { try await installer.install(agent()) }
        #expect(try await installer.installations().isEmpty)
    }

    @Test func failedNpmAndMissingEntryNeverPublishAnInstallation() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        for missingEntry in [false, true] {
            let installer = installer(fixture, fail: !missingEntry, missingEntry: missingEntry)
            await #expect(throws: AgentInstallation.Failure.npmFailed) { try await installer.install(agent()) }
            #expect(try await installer.installations().isEmpty)
        }
    }

    private func installer(
        _ fixture: RuntimeFixture,
        commands: InstallationCommandLog = InstallationCommandLog(),
        bin: String = "entry.js",
        fail: Bool = false,
        missingEntry: Bool = false
    ) -> AgentInstaller {
        AgentInstaller(
            root: fixture.root.appending(path: "Agents"),
            environment: fixture.environment,
            runtime: fixture.runtime(),
            download: { _, _ in Issue.record("npm installation must not use the binary downloader") },
            run: { command in
                commands.values.withLock { $0.append(command) }
                do {
                    let metadata: [String: Any] = [
                        "name": "@fixture/agent", "version": "1.0.0", "engines": ["node": ">=20"],
                        "bin": ["agent": bin],
                    ]
                    let data = try JSONSerialization.data(withJSONObject: metadata)
                    if command.arguments.contains("view") { return .success(data, 0) }
                    if fail { return .success(Data(), 1 << 8) }
                    let payload = try #require(command.currentDirectory)
                    let package = payload.appending(path: "node_modules/@fixture/agent")
                    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                    try data.write(to: package.appending(path: "package.json"))
                    if !missingEntry {
                        try Data("console.log('fixture')".utf8).write(to: package.appending(path: "entry.js"))
                    }
                    let lock: [String: Any] = [
                        "lockfileVersion": 3,
                        "packages": [
                            "": ["dependencies": ["@fixture/agent": "1.0.0"]],
                            "node_modules/@fixture/agent": ["version": "1.0.0", "integrity": "sha512-fixture"],
                        ],
                    ]
                    try JSONSerialization.data(withJSONObject: lock).write(
                        to: payload.appending(path: "package-lock.json")
                    )
                    return .success(Data(), 0)
                } catch {
                    Issue.record(error)
                    return .launchFailed
                }
            }
        )
    }

    private func agent() throws -> AgentRegistry.Agent {
        try JSONDecoder().decode(
            AgentRegistry.Agent.self,
            from: Data(
                #"{"id":"npm-fixture","name":"Fixture","version":"1.0.0","description":"Test agent","distribution":{"npx":{"package":"@fixture/agent","args":["--acp"],"env":{"FIXTURE":"yes"}}}}"#
                    .utf8
            )
        )
    }
}

private final class InstallationCommandLog: Sendable {
    let values = Mutex<[AgentCommand]>([])
}
