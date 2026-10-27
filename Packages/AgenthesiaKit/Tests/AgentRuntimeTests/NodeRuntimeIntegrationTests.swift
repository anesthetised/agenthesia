import Foundation
import Testing

@testable import AgentRuntime

/// Optional host integration, like the installed-fish check in ShellEnvironmentTests.
/// Fixture tests cover prerequisite behavior even on machines without Node/npm.
@Suite(.timeLimit(.minutes(1))) struct NodeRuntimeIntegrationTests {
    @Test func installedNodeAndNpmUseRealSemverAndIgnoreProjectShims() async throws {
        let inherited = ProcessInfo.processInfo.environment
        let paths =
            (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/node") }),
            paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/npm") })
        else { return }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-runtime-integration-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = ShellEnvironment(capture: {
            .init(
                environment: ["PATH": paths.joined(separator: ":"), "HOME": root.path(percentEncoded: false)],
                diagnostic: nil
            )
        })
        let runtime = NodeRuntime(environment: shell)
        let checked = try await runtime.discover()
        let version = checked.toolchain.nodeVersion
        let major = try #require(Int(version.split(separator: ".")[0]))
        let requirements = NodeRuntime.Requirements(
            node: "^\(major).0.0 || >=999.0.0",
            npm: checked.toolchain.npmVersion
        )
        #expect(try await runtime.prepare(checked.toolchain, requirements: requirements).toolchain == checked.toolchain)
        await #expect(throws: NodeRuntime.Failure.incompatible(.node, version: version, required: ">=999")) {
            try await runtime.discover(requirements: .init(node: ">=999"))
        }
        await #expect(throws: NodeRuntime.Failure.invalidRequirement(.node)) {
            try await runtime.discover(requirements: .init(node: "not a range"))
        }
        // cwd contains its own node and npm. Explicit paths and the pinned PATH must win.
        for name in ["node", "npm"] {
            let file = root.appending(path: name)
            try "#!/bin/sh\nexit 91\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: file.path(percentEncoded: false)
            )
        }
        let script = root.appending(path: "agent entry.js")
        try
            #"console.log(JSON.stringify({node: process.execPath, child: require('node:child_process').execFileSync('node', ['-p', 'process.execPath'], {encoding:'utf8'}).trim()}))"#
            .write(to: script, atomically: true, encoding: .utf8)
        let output = await CommandOutput.capture(checked.agentCommand(script: script, directory: root))
        guard case .success(let bytes, 0) = output else { Issue.record("Agent command failed: \(output)"); return }
        let value = try JSONDecoder().decode([String: String].self, from: bytes)
        #expect(value["node"] == checked.toolchain.node)
        #expect(value["child"] == checked.toolchain.node)
        #expect(
            await CommandOutput.capture(checked.npmCommand(arguments: ["--version"], directory: root))
                == .success(Data((checked.toolchain.npmVersion + "\n").utf8), 0)
        )
        // Missing engines impose no constraint, unlike an explicitly declared "*" range.
        let npmRoot = root.appending(path: "prerelease npm")
        let cli = npmRoot.appending(path: "bin/npm-cli.js")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"name":"npm","version":"11.0.0-beta.1","bin":{"npm":"bin/npm-cli.js"},"engines":{"node":"*"}}"#
            .write(to: npmRoot.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "#!/usr/bin/env node\nconsole.log('11.0.0-beta.1')\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path(percentEncoded: false))
        let installedModules = URL(filePath: checked.toolchain.npm).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "node_modules")
        try FileManager.default.createSymbolicLink(
            at: npmRoot.appending(path: "node_modules"),
            withDestinationURL: installedModules
        )
        let bin = root.appending(path: "prerelease-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appending(path: "node"),
            withDestinationURL: URL(filePath: checked.toolchain.node)
        )
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "npm"), withDestinationURL: cli)
        let prerelease = NodeRuntime(
            environment: ShellEnvironment(capture: {
                .init(
                    environment: ["PATH": bin.path(percentEncoded: false), "HOME": root.path(percentEncoded: false)],
                    diagnostic: nil
                )
            })
        )
        #expect(try await prerelease.discover().toolchain.npmVersion == "11.0.0-beta.1")
        await #expect(throws: NodeRuntime.Failure.incompatible(.npm, version: "11.0.0-beta.1", required: "*")) {
            try await prerelease.discover(requirements: .init(npm: "*"))
        }
    }
}
