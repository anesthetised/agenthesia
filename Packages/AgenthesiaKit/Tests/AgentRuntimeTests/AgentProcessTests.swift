import ACP
import ACPTesting
import AgentRuntime
import Foundation
import JSONRPC
import Testing

@Suite(.timeLimit(.minutes(1))) struct AgentProcessTests {
    @Test func talksOverStdinAndStdout() async throws {
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/cat"))
        #expect(await process.isRunning)
        #expect(process.processIdentifier > 0)
        try await process.transport.send(Data(#"{"hello":1}"#.utf8))
        var messages = process.transport.messages.makeAsyncIterator()
        #expect(try await messages.next() == Data(#"{"hello":1}"#.utf8))
        await process.transport.close()
        #expect(await process.waitForExit() == .exited(0))
        #expect(await !process.isRunning)
    }

    @Test func resolvesExecutablesFromThePath() async throws {
        let process = try AgentProcess(
            launching: AgentCommand(
                executable: "sh",
                arguments: ["-c", "echo $AGENT_TEST"],
                environment: ["PATH": "/bin:/usr/bin", "AGENT_TEST": "from env"]
            )
        )
        var messages = process.transport.messages.makeAsyncIterator()
        #expect(try await messages.next().map { String(decoding: $0, as: UTF8.self) } == "from env")
        #expect(await process.waitForExit() == .exited(0))
    }

    @Test func inheritsTheEnvironmentByDefault() async throws {
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "echo $PATH"]))
        var messages = process.transport.messages.makeAsyncIterator()
        let path = try await messages.next().map { String(decoding: $0, as: UTF8.self) }
        #expect(path == ProcessInfo.processInfo.environment["PATH"])
    }

    @Test func runsInTheGivenDirectory() async throws {
        let directory = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory).resolvingSymlinksInPath()
        let process = try AgentProcess(
            launching: AgentCommand(executable: "/bin/pwd", currentDirectory: directory)
        )
        var messages = process.transport.messages.makeAsyncIterator()
        let output = try await messages.next().map { String(decoding: $0, as: UTF8.self) }
        let resolved = output.map { URL(filePath: $0, directoryHint: .isDirectory).resolvingSymlinksInPath().path() }
        #expect(resolved == directory.path())
    }

    @Test func streamsStderrLines() async throws {
        let process = try AgentProcess(
            launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "echo one >&2; printf 'two\\nthree' >&2"])
        )
        var lines: [String] = []
        for await line in process.stderr {
            lines.append(line)
        }
        #expect(lines == ["one", "two", "three"])
    }

    @Test func reportsExitCodes() async throws {
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "exit 3"]))
        #expect(await process.waitForExit() == .exited(3))
        #expect(ExitStatus.exited(3).description == "exited with code 3")
        let missing = try AgentProcess(launching: AgentCommand(executable: "definitely-not-a-command-agenthesia"))
        #expect(await missing.waitForExit() == .exited(127))
    }

    @Test func failsToLaunchMissingExecutables() {
        #expect(throws: (any Error).self) {
            try AgentProcess(launching: AgentCommand(executable: "/nonexistent/agent"))
        }
    }

    @Test func terminatesWithSigterm() async throws {
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sleep", arguments: ["30"]))
        #expect(await process.terminate() == .signaled(SIGTERM))
        #expect(await process.terminate() == .signaled(SIGTERM))
        #expect(ExitStatus.signaled(SIGTERM).description == "killed by signal 15")
    }

    @Test func escalatesToSigkill() async throws {
        let process = try AgentProcess(
            launching: AgentCommand(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do sleep 0.1; done"]
            )
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(await process.terminate(gracePeriod: .milliseconds(200)) == .signaled(SIGKILL))
    }

    @Test(.enabled(if: MockAgentBinary.url != nil, "MockAgent has not been built"))
    func drivesTheMockAgentProcessEndToEnd() async throws {
        let binary = try #require(MockAgentBinary.url)
        let environment = childEnvironment()
        let process = try AgentProcess(
            launching: AgentCommand(executable: binary.path(percentEncoded: false), environment: environment)
        )
        struct Delegate: ACP.AgentConnectionDelegate {
            func sessionUpdate(_ update: ACP.SessionUpdate, in sessionId: ACP.SessionID) async {}
            func requestPermission(
                for toolCall: ACP.ToolCallUpdate,
                options: [ACP.PermissionOption],
                in sessionId: ACP.SessionID
            ) async -> ACP.PermissionOutcome { .cancelled }
        }
        let connection = await ACP.V1.AgentConnectionAdapter(transport: process.transport, delegate: Delegate())
        let profile = try await connection.initialize(client: .init(name: "tests", version: "1"))
        #expect(profile.info?.name == "echo-agent")
        let session = try await connection.newSession(cwd: "/tmp", additionalDirectories: [], mcpServers: [])
        #expect(try await connection.prompt([.init(text: "hi")], in: session.sessionId) == .endTurn)
        await connection.close()
        #expect(await process.waitForExit() == .exited(0))
    }
}

@Suite(.timeLimit(.minutes(1)), .enabled(if: MockAgentBinary.url != nil, "MockAgent has not been built"))
struct MockAgentScenarioTests {
    private func launch(_ scenario: Scenario) throws -> AgentProcess {
        let file = FileManager.default.temporaryDirectory.appending(path: "scenario-\(UUID().uuidString).json")
        try JSONEncoder().encode(scenario).write(to: file)
        let binary = try #require(MockAgentBinary.url).path(percentEncoded: false)
        return try AgentProcess(
            launching: AgentCommand(
                executable: binary,
                arguments: ["--scenario", file.path(percentEncoded: false)],
                environment: childEnvironment()
            )
        )
    }

    @Test func playsAScenarioAndExitsCleanly() async throws {
        let process = try launch(
            Scenario([.expectRequest(method: "initialize", response: .result(["protocolVersion": 1]))])
        )
        let connection = Connection(transport: process.transport)
        await connection.start(handler: Router())
        #expect(
            try await connection.request(method: "initialize", params: ["protocolVersion": 1]) == ["protocolVersion": 1]
        )
        #expect(await process.waitForExit() == .exited(0))
    }

    @Test func exitsWithAnErrorOnDeviation() async throws {
        let process = try launch(Scenario([.expectNotification(method: "session/cancel")]))
        let connection = Connection(transport: process.transport)
        await connection.start(handler: Router())
        try await connection.notify(method: "something/else", params: nil)
        var log: [String] = []
        for await line in process.stderr {
            log.append(line)
        }
        #expect(await process.waitForExit() == .exited(1))
        #expect(log.contains { $0.contains("session/cancel") })
    }
}

/// The MockAgent executable built next to the tests, if any.
enum MockAgentBinary {
    static let url: URL? = {
        let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let candidates =
            Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().appending(path: "MockAgent") } + [
                packageRoot.appending(path: ".build/debug/MockAgent"),
                packageRoot.appending(path: ".build/out/Products/Debug/MockAgent"),
            ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }()
}

/// The environment for instrumented child processes: they write coverage profiles next to the test
/// runner's when coverage is enabled, and to a temporary directory otherwise, never to the working directory.
func childEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if environment["LLVM_PROFILE_FILE"] == nil {
        environment["LLVM_PROFILE_FILE"] = FileManager.default.temporaryDirectory
            .appending(path: "agenthesia-child-%p.profraw").path(percentEncoded: false)
    }
    return environment
}
