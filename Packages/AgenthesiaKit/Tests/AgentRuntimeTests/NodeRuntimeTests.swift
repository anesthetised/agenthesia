import Foundation
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct NodeRuntimeTests {
    @Test func discoversPinnedToolsAndBuildsCommandsIndependentOfProjectDirectory() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let prepared = try await runtime.discover(requirements: .init(node: ">=22", npm: "^10 || ^11"))
        #expect(prepared.toolchain.node == fixture.node.path(percentEncoded: false))
        #expect(prepared.toolchain.npm == fixture.npm.path(percentEncoded: false))
        #expect(prepared.toolchain.nodeVersion == "22.15.0")
        #expect(prepared.toolchain.npmVersion == "10.9.2")
        #expect(
            prepared.environment["PATH"]?.hasPrefix(
                fixture.node.deletingLastPathComponent().path(percentEncoded: false) + ":"
            ) == true
        )
        #expect(prepared.environment["NODE_OPTIONS"] == nil)
        #expect(prepared.environment["NODE_PATH"] == nil)
        #expect(prepared.environment["KEEP"] == "yes")
        let directory = fixture.root.appending(path: "other project")
        let npm = prepared.npmCommand(arguments: ["--version"], directory: directory)
        let agent = prepared.agentCommand(script: fixture.root.appending(path: "agent.js"), directory: directory)
        #expect(npm.executable == fixture.node.path(percentEncoded: false))
        #expect(npm.arguments == [fixture.npm.path(percentEncoded: false), "--version"])
        #expect(agent.executable == npm.executable)
        #expect(npm.environment == agent.environment)
        #expect(agent.currentDirectory == directory)
        let stored = try JSONEncoder().encode(prepared.toolchain)
        let restored = try JSONDecoder().decode(NodeRuntime.Toolchain.self, from: stored)
        #expect(try await runtime.prepare(restored).toolchain == prepared.toolchain)
    }

    @Test func reportsMissingToolsAndDoesNotSearchRelativePathEntries() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.node)
        await #expect(throws: NodeRuntime.Failure.missingNode) { try await fixture.runtime().discover() }
        await #expect(throws: NodeRuntime.Failure.missingNode) {
            try await fixture.runtime(path: ":.:relative").discover()
        }
    }

    @Test func missingNpmAndUnsupportedWrapperHaveActionableErrors() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.root.appending(path: "bin/npm"))
        await #expect(throws: NodeRuntime.Failure.missingNpm) { try await fixture.runtime().discover() }
        try fixture.executable("#!/bin/sh\nexit 0\n", at: fixture.root.appending(path: "bin/npm"))
        await #expect(throws: NodeRuntime.Failure.unsupportedNpm) { try await fixture.runtime().discover() }
        #expect(NodeRuntime.Failure.unsupportedNpm.errorDescription?.contains("Check Again") == true)
    }

    @Test func findsNpmBesideNodeBehindVersionManagerShim() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let shim = fixture.root.appending(path: "shims")
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        for name in ["node", "npm"] {
            try fixture.executable("#!/bin/sh\nexit 0\n", at: shim.appending(path: name))
        }
        let prepared = try await fixture.runtime(path: shim.path(percentEncoded: false)).discover()
        #expect(prepared.toolchain.node == fixture.node.path(percentEncoded: false))
        #expect(prepared.toolchain.npm == fixture.npm.path(percentEncoded: false))
    }

    @Test func refusesRemovedOrChangedPinnedRuntime() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let original = try await fixture.runtime().discover()
        let changed = fixture.runtime(nodeVersion: "24.0.0")
        await #expect(throws: NodeRuntime.Failure.runtimeChanged) { try await changed.prepare(original.toolchain) }
        try FileManager.default.removeItem(at: fixture.node)
        await #expect(throws: NodeRuntime.Failure.missingNode) {
            try await fixture.runtime().prepare(original.toolchain)
        }
    }

    @Test func propagatesTypedProbeFailuresWithoutLeakingOutput() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        for (output, error) in [
            (CommandOutput.timedOut, NodeRuntime.Failure.timedOut(.node)),
            (.tooMuchOutput, .invalidOutput(.node)),
            (.launchFailed, .probeFailed(.node)),
            (.success(Data("secret".utf8), 1), .probeFailed(.node)),
            (.success(Data("secret".utf8), 0), .invalidOutput(.node)),
        ] {
            let runtime = NodeRuntime(environment: fixture.environment, run: { _ in output })
            await #expect(throws: error) { try await runtime.discover() }
            #expect(error.errorDescription?.contains("secret") == false)
        }
    }

    @Test func incompatibleAndInvalidRequirementsAreExplicit() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        await #expect(throws: NodeRuntime.Failure.incompatible(.node, version: "22.15.0", required: ">=24")) {
            try await fixture.runtime(nodeCompatible: false).discover(requirements: .init(node: ">=24"))
        }
        await #expect(throws: NodeRuntime.Failure.incompatible(.npm, version: "10.9.2", required: ">=11")) {
            try await fixture.runtime(npmCompatible: false).discover(requirements: .init(npm: ">=11"))
        }
        await #expect(throws: NodeRuntime.Failure.invalidRequirement(.node)) {
            try await fixture.runtime().discover(requirements: .init(node: "bad\0range"))
        }
        await #expect(throws: NodeRuntime.Failure.invalidRequirement(.npm)) {
            try await fixture.runtime(invalidRequirement: "npm").discover(requirements: .init(npm: "garbage"))
        }
    }

    @Test func validatesNpmAgainstNodeAndDetectsBrokenNpmVersionOutput() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        await #expect(throws: NodeRuntime.Failure.incompatible(.node, version: "22.15.0", required: ">=18")) {
            try await fixture.runtime(toolchainCompatible: false).discover()
        }
        await #expect(throws: NodeRuntime.Failure.invalidOutput(.npm)) {
            try await fixture.runtime(npmOutput: "other-version").discover()
        }
        await #expect(throws: NodeRuntime.Failure.probeFailed(.npm)) {
            try await fixture.runtime(npmStatus: 256).discover()
        }
    }

    @Test func rejectsMalformedNodeProbeAndRuntimeRedirects() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        await #expect(throws: NodeRuntime.Failure.invalidOutput(.node)) {
            try await fixture.runtime(nodeVersion: "garbage").discover()
        }
        let prepared = try await fixture.runtime().discover()
        let other = fixture.root.appending(path: "other-node")
        try FileManager.default.moveItem(at: fixture.node, to: other)
        try FileManager.default.createSymbolicLink(at: fixture.node, withDestinationURL: other)
        await #expect(throws: NodeRuntime.Failure.runtimeChanged) {
            try await fixture.runtime().prepare(prepared.toolchain)
        }
        try FileManager.default.removeItem(at: fixture.npm)
        await #expect(throws: NodeRuntime.Failure.missingNpm) {
            try await fixture.runtime().prepare(prepared.toolchain)
        }
    }

    @Test func checkAgainUsesFreshShellEnvironmentAndRetainsFallbackDiagnostic() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let state = RuntimeEnvironmentState(path: fixture.root.appending(path: "bin").path(percentEncoded: false))
        let resolver = ShellEnvironment(capture: { await state.capture() })
        let runtime = NodeRuntime(environment: resolver, run: fixture.runner())
        await #expect(throws: NodeRuntime.Failure.missingNode) { try await runtime.discover() }
        await state.install()
        await #expect(throws: NodeRuntime.Failure.missingNode) { try await runtime.discover() }
        let checked = try await runtime.discover(refresh: true)
        #expect(checked.toolchain.node == fixture.node.path(percentEncoded: false))
        #expect(checked.shellDiagnostic == "fixture fallback")
    }

    @Test func cancellationDuringProbeWinsOverFailure() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = NodeRuntime(
            environment: fixture.environment,
            run: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .launchFailed
            }
        )
        let task = Task { try await runtime.discover() }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func refusesRuntimeDirectoryThatCannotBePinnedInPath() async throws {
        let fixture = try RuntimeFixture(component: "colon:fixture")
        defer { fixture.remove() }
        let stored = NodeRuntime.Toolchain(
            node: fixture.node.path(percentEncoded: false),
            npm: fixture.npm.path(percentEncoded: false),
            nodeVersion: "22.15.0",
            npmVersion: "10.9.2"
        )
        await #expect(throws: NodeRuntime.Failure.unsupportedNodePath) {
            try await fixture.runtime().prepare(stored)
        }
    }

    @Test(arguments: [false, true])
    func cancellationDuringShellCaptureWinsOverMissingTools(preparing: Bool) async throws {
        let gate = RuntimeCaptureGate()
        let shell = ShellEnvironment(capture: { await gate.capture() })
        let runtime = NodeRuntime(environment: shell)
        let missing = NodeRuntime.Toolchain(
            node: "/missing/node",
            npm: "/missing/npm-cli.js",
            nodeVersion: "22.0.0",
            npmVersion: "10.0.0"
        )
        let task = Task {
            if preparing { return try await runtime.prepare(missing) }
            return try await runtime.discover(refresh: true)
        }
        await gate.waitForCapture()
        task.cancel()
        await gate.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationIsNotAPrerequisiteFailure() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.runtime().discover()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private struct RuntimeFixture: Sendable {
    let root: URL
    var node: URL { root.appending(path: "bin/node") }
    var npm: URL { root.appending(path: "lib/npm/bin/npm-cli.js") }
    var environment: ShellEnvironment {
        ShellEnvironment(capture: {
            .init(
                environment: [
                    "PATH": root.appending(path: "bin").path(percentEncoded: false),
                    "HOME": root.path(percentEncoded: false), "KEEP": "yes",
                    "NODE_OPTIONS": "--require ./project-hook.js", "NODE_PATH": "./project-modules",
                ],
                diagnostic: nil
            )
        })
    }

    init(component: String = "fixture") throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-runtime \(component)-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: npm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try executable("#!/bin/sh\nexit 0\n", at: node)
        try executable("#!/usr/bin/env node\n", at: npm)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/npm"), withDestinationURL: npm)
    }

    func runtime(
        path: String? = nil,
        nodeVersion: String = "22.15.0",
        nodeCompatible: Bool = true,
        npmCompatible: Bool = true,
        invalidRequirement: String? = nil,
        toolchainCompatible: Bool = true,
        npmOutput: String = "10.9.2\n",
        npmStatus: Int32 = 0
    ) -> NodeRuntime {
        let shell =
            path.map { path in
                ShellEnvironment(capture: {
                    .init(environment: ["PATH": path, "HOME": root.path(percentEncoded: false)], diagnostic: nil)
                })
            } ?? environment
        return NodeRuntime(
            environment: shell,
            run: runner(
                nodeVersion: nodeVersion,
                nodeCompatible: nodeCompatible,
                npmCompatible: npmCompatible,
                invalidRequirement: invalidRequirement,
                toolchainCompatible: toolchainCompatible,
                npmOutput: npmOutput,
                npmStatus: npmStatus
            )
        )
    }

    func runner(
        nodeVersion: String = "22.15.0",
        nodeCompatible: Bool = true,
        npmCompatible: Bool = true,
        invalidRequirement: String? = nil,
        toolchainCompatible: Bool = true,
        npmOutput: String = "10.9.2\n",
        npmStatus: Int32 = 0
    ) -> @Sendable (AgentCommand) async -> CommandOutput {
        { command in
            if command.arguments.first == "--eval" {
                if command.arguments[1].contains("const semver") {
                    var object: [String: Any] = [
                        "version": "10.9.2", "nodeRequirement": ">=18", "toolchainCompatible": toolchainCompatible,
                        "nodeCompatible": nodeCompatible, "npmCompatible": npmCompatible,
                    ]
                    if let invalidRequirement { object["invalidRequirement"] = invalidRequirement }
                    return .success(try! JSONSerialization.data(withJSONObject: object), 0)
                }
                let object = ["executable": node.path(percentEncoded: false), "version": nodeVersion]
                return .success(try! JSONEncoder().encode(object), 0)
            }
            return .success(Data(npmOutput.utf8), npmStatus)
        }
    }

    func executable(_ content: String, at url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor RuntimeEnvironmentState {
    let path: String
    var installed = false
    init(path: String) { self.path = path }
    func install() { installed = true }
    func capture() -> ShellEnvironment.Resolution {
        .init(environment: ["PATH": installed ? path : "/missing/agenthesia-tools"], diagnostic: "fixture fallback")
    }
}

private actor RuntimeCaptureGate {
    var continuation: CheckedContinuation<ShellEnvironment.Resolution, Never>?
    func capture() async -> ShellEnvironment.Resolution {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForCapture() async {
        while continuation == nil { await Task.yield() }
    }
    func finish() { continuation?.resume(returning: .init(environment: ["PATH": "/missing"], diagnostic: nil)) }
}
