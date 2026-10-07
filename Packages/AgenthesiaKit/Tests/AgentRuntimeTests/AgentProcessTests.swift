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
                arguments: ["-c", "trap '' TERM; echo ready; while :; do sleep 0.1; done"]
            )
        )
        var messages = process.transport.messages.makeAsyncIterator()
        #expect(try await messages.next() == Data("ready".utf8))
        let start = ContinuousClock.now
        let short = Task { await process.terminate(gracePeriod: .milliseconds(200)) }
        try await Task.sleep(for: .milliseconds(20))
        let long = Task { await process.terminate(gracePeriod: .seconds(2)) }
        #expect(await short.value == .signaled(SIGKILL))
        #expect(await long.value == .signaled(SIGKILL))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func childHasItsOwnProcessGroup() async throws {
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sleep", arguments: ["30"]))
        let pid = process.processIdentifier
        #expect(getpgid(pid) == pid)
        #expect(getpgrp() != pid)
        _ = await process.terminate(gracePeriod: .milliseconds(50))
    }

    @Test func terminatesDescendantsAfterLeaderExits() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-child-\(UUID().uuidString).pid"
        )
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
            trap 'exit 0' TERM
            /bin/sh -c 'trap "" TERM; echo $$ > "\(pidFile.path(percentEncoded: false))"; while :; do /bin/sleep 1; done' &
            while :; do /bin/sleep 1; done
            """
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        let child: Int32
        do { child = try await waitForChildPID(at: pidFile) } catch {
            _ = await process.terminate(gracePeriod: .milliseconds(50))
            throw error
        }
        defer { kill(child, SIGKILL) }
        #expect(getpgid(child) == process.processIdentifier)
        #expect(await process.terminate(gracePeriod: .milliseconds(150)) == .exited(0))
        #expect(try await waitUntilInactive(child))
    }

    @Test func naturalLeaderExitCleansDescendantAfterFinalStdout() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-natural-\(UUID().uuidString).pid"
        )
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
            /bin/sh -c 'trap "exit 0" TERM; echo $$ > "\(pidFile.path(percentEncoded: false))"; while :; do /bin/sleep 1; done' &
            attempt=0
            while [ ! -s "\(pidFile.path(percentEncoded: false))" ] && [ "$attempt" -lt 100 ]; do
                /bin/sleep 0.01
                attempt=$((attempt + 1))
            done
            echo final
            """
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        let child: Int32
        do { child = try await waitForChildPID(at: pidFile) } catch {
            _ = await process.terminate(gracePeriod: .milliseconds(50))
            throw error
        }
        defer { kill(child, SIGKILL) }
        var messages = process.transport.messages.makeAsyncIterator()
        #expect(try await messages.next() == Data("final".utf8))
        #expect(await process.waitForExit() == .exited(0))
        #expect(try await waitUntilInactive(child))
        #expect(await process.terminate(gracePeriod: .milliseconds(50)) == .exited(0))
    }

    @Test func laterTerminationShortensNaturalExitCleanupDeadline() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-shortened-\(UUID().uuidString).pid"
        )
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
            /bin/sh -c 'trap "" TERM; echo $$ > "\(pidFile.path(percentEncoded: false))"; while :; do /bin/sleep 1; done' &
            attempt=0
            while [ ! -s "\(pidFile.path(percentEncoded: false))" ] && [ "$attempt" -lt 100 ]; do
                /bin/sleep 0.01
                attempt=$((attempt + 1))
            done
            echo ready
            """
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        let child: Int32
        do { child = try await waitForChildPID(at: pidFile) } catch {
            _ = await process.terminate(gracePeriod: .milliseconds(50))
            throw error
        }
        defer { kill(child, SIGKILL) }
        var messages = process.transport.messages.makeAsyncIterator()
        #expect(try await messages.next() == Data("ready".utf8))
        #expect(await process.waitForExit() == .exited(0))
        let long = Task { await process.terminate(gracePeriod: .seconds(3)) }
        let start = ContinuousClock.now
        #expect(await process.terminate(gracePeriod: .milliseconds(100)) == .exited(0))
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await long.value == .exited(0))
        #expect(try await waitUntilInactive(child))
    }

    @Test func cancellationDoesNotInterruptSharedTermination() async throws {
        let process = try AgentProcess(
            launching: AgentCommand(
                executable: "/bin/sh",
                arguments: ["-c", "trap 'sleep 0.1; exit 0' TERM; echo ready; while :; do sleep 0.05; done"]
            )
        )
        var messages = process.transport.messages.makeAsyncIterator()
        #expect(try await messages.next() == Data("ready".utf8))
        let first = Task { await process.terminate(gracePeriod: .seconds(1)) }
        first.cancel()
        let second = Task { await process.terminate(gracePeriod: .seconds(1)) }
        let firstStatus = await first.value
        #expect(firstStatus == .exited(0))
        #expect(await second.value == .exited(0))
        #expect(await process.terminate() == firstStatus)
    }

    @Test func stderrRetainsBoundedTailAndFinalUnterminatedText() async throws {
        let script =
            "/usr/bin/awk 'BEGIN { for (i=0; i<100000; i++) printf \"x\"; printf \"\\342\\234\\223\\nfinal tail\" }' >&2"
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        #expect(await process.waitForExit() == .exited(0))
        await process.waitForStderr()
        let log = await process.stderrLog
        #expect(log.utf8.count <= 65_536)
        #expect(log.contains("✓"))
        #expect(log.hasSuffix("final tail"))
        var lines: [String] = []
        for await line in process.stderr { lines.append(line) }
        #expect(lines.last == "final tail")
        #expect(lines.count <= 64)
    }

    @Test func stderrLogTruncationKeepsUtf8BoundaryAndFits64KiB() async throws {
        let marker = "[earlier stderr omitted]\n"
        let tailCount = 65_536 - marker.utf8.count - 2
        let script =
            "/usr/bin/awk 'BEGIN { for (i=0; i<10; i++) printf \"x\"; printf \"\\342\\234\\223\"; for (i=0; i<\(tailCount); i++) printf \"y\" }' >&2"
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        await process.waitForStderr()
        let log = await process.stderrLog
        #expect(log == marker + String(repeating: "y", count: tailCount))
        #expect(log.utf8.count <= 65_536)
        #expect(!log.contains("�"))
    }

    @Test func stderrLineTruncationKeepsUtf8BoundaryAt16KiB() async throws {
        let tailCount = 16_384 - 2
        let script =
            "/usr/bin/awk 'BEGIN { for (i=0; i<10; i++) printf \"x\"; printf \"\\342\\234\\223\"; for (i=0; i<\(tailCount); i++) printf \"y\"; printf \"\\n\" }' >&2"
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        await process.waitForStderr()
        var lines: [String] = []
        for await line in process.stderr { lines.append(line) }
        #expect(lines == ["[line truncated] " + String(repeating: "y", count: tailCount)])
        #expect(lines.first?.contains("�") == false)
        #expect((await process.stderrLog).contains("✓"))
    }

    @Test func stderrStreamDropsOldLinesWhileRetainingLatest() async throws {
        let script = "/usr/bin/awk 'BEGIN { for (i=0; i<1000; i++) printf \"line %d\\n\", i }' >&2"
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        #expect(await process.waitForExit() == .exited(0))
        await process.waitForStderr()
        var lines: [String] = []
        for await line in process.stderr { lines.append(line) }
        #expect(lines.count == 64)
        #expect(lines.first == "line 936")
        #expect(lines.last == "line 999")
        let log = await process.stderrLog
        #expect(log.contains("line 999"))
        #expect(log.utf8.count <= 65_536)
    }

    @Test func cancelledExitWaiterDoesNotLoseExit() async throws {
        let process = try AgentProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "sleep 0.1"]))
        let first = Task { await process.waitForExit() }
        let second = Task { await process.waitForExit() }
        first.cancel()
        #expect(await first.value == .exited(0))
        #expect(await second.value == .exited(0))
    }

    @Test func stderrIsCapturedWhileProcessIsStillRunning() async throws {
        let process = try AgentProcess(
            launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "echo ready >&2; exec /bin/sleep 30"])
        )
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await process.stderrLog).contains("ready") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((await process.stderrLog).contains("ready"))
        #expect(await process.isRunning)
        _ = await process.terminate(gracePeriod: .milliseconds(50))
    }

    @Test func stderrDrainIsBoundedAfterLeaderExitWhenDescendantKeepsPipeOpen() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-stderr-descendant-\(UUID().uuidString).pid"
        )
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
            /bin/sh -c 'trap "" TERM; echo $$ > "\(pidFile.path(percentEncoded: false))"; exec /bin/sleep 5' 1>&2 &
            attempt=0
            while [ ! -s "\(pidFile.path(percentEncoded: false))" ] && [ "$attempt" -lt 100 ]; do
                /bin/sleep 0.01
                attempt=$((attempt + 1))
            done
            echo leader >&2
            """
        let process = try AgentProcess(
            launching: AgentCommand(
                executable: "/bin/sh",
                arguments: ["-c", script]
            )
        )
        let child: Int32
        do { child = try await waitForChildPID(at: pidFile) } catch {
            _ = await process.terminate(gracePeriod: .milliseconds(50))
            throw error
        }
        defer { kill(child, SIGKILL) }
        #expect(await process.waitForExit() == .exited(0))
        #expect(getpgid(child) == process.processIdentifier)
        let start = ContinuousClock.now
        await process.waitForStderr()
        #expect(ContinuousClock.now - start >= .milliseconds(400))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect((await process.stderrLog).contains("leader"))
        _ = await process.terminate(gracePeriod: .milliseconds(50))
    }

    @Test func stderrDrainCalledWhileRunningPreservesLaterOutput() async throws {
        let process = try AgentProcess(
            launching: AgentCommand(
                executable: "/bin/sh",
                arguments: ["-c", "echo ready; /bin/sleep 0.8; echo later >&2"]
            )
        )
        var messages = process.transport.messages.makeAsyncIterator()
        #expect(try await messages.next() == Data("ready".utf8))
        await process.waitForStderr()
        #expect(await process.waitForExit() == .exited(0))
        #expect((await process.stderrLog).contains("later"))
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

private func waitForChildPID(at file: URL) async throws -> Int32 {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if let text = try? String(contentsOf: file, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return pid
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TestProcessError.timeout
}

private func waitUntilInactive(_ pid: Int32) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if kill(pid, 0) != 0 { return true }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", String(pid)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let state = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        process.waitUntilExit()
        if state.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z") { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private enum TestProcessError: Error { case timeout }

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
