import Foundation
import Testing

@testable import AgentRuntime

@Suite(.timeLimit(.minutes(1))) struct TerminalProcessTests {
    @Test func runsAsSessionLeaderWithThePseudoTerminalAsControllingTerminal() async throws {
        let script = "tty; exec 3</dev/tty && echo controlling; stty size; ps -o pgid=,sess=,tpgid= -p $$"
        let terminal = try TerminalProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        #expect(await terminal.waitForExit() == .exited(0))
        let lines = text(terminal.output).split(separator: "\n").map { String($0) }
        #expect(lines.first?.hasPrefix("/dev/ttys") == true)
        #expect(lines.contains("controlling"))
        #expect(lines.contains("24 80"))
        let pid = String(terminal.processIdentifier)
        let ids = lines.last?.split(separator: " ").map(String.init)
        #expect(ids?.first == pid)
        #expect(ids?.last == pid)
    }

    @Test func resolvesBareCommandsThroughTheEnvironmentPath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try executable("#!/bin/sh\necho \"$1 $GREETING\"\n", at: directory.appending(path: "agenthesia-tool"))
        try "not executable".write(to: directory.appending(path: "agenthesia-plain"), atomically: true, encoding: .utf8)
        let path = "/nonexistent:\(directory.path(percentEncoded: false)):/bin:/usr/bin"
        let terminal = try TerminalProcess(
            launching: AgentCommand(
                executable: "agenthesia-tool",
                arguments: ["hello"],
                environment: ["PATH": path, "GREETING": "from env"]
            )
        )
        #expect(await terminal.waitForExit() == .exited(0))
        #expect(text(terminal.output) == "hello from env\n")

        #expect(throws: POSIXError(.ENOENT)) {
            try TerminalProcess(launching: AgentCommand(executable: "agenthesia-plain", environment: ["PATH": path]))
        }
        #expect(throws: POSIXError(.ENOENT)) {
            try TerminalProcess(launching: AgentCommand(executable: "agenthesia-missing", environment: ["PATH": path]))
        }
        #expect(throws: POSIXError(.ENOENT)) {
            try TerminalProcess(launching: AgentCommand(executable: ""))
        }
    }

    @Test func runsInTheGivenDirectoryAndResolvesRelativeCommandsThere() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try executable("#!/bin/sh\n/bin/pwd\n", at: directory.appending(path: "where"))
        let terminal = try TerminalProcess(
            launching: AgentCommand(executable: "./where", environment: [:], currentDirectory: directory)
        )
        #expect(await terminal.waitForExit() == .exited(0))
        let output = text(terminal.output).trimmingCharacters(in: .newlines)
        try #require(!output.isEmpty, "Terminal exited without capturing its working directory.")
        let resolved = URL(filePath: output, directoryHint: .isDirectory).resolvingSymlinksInPath()
        #expect(resolved.path() == directory.resolvingSymlinksInPath().path())
    }

    @Test func failsToLaunchMissingExecutables() {
        #expect(throws: (any Error).self) {
            try TerminalProcess(launching: AgentCommand(executable: "/nonexistent/command"))
        }
    }

    @Test func reportsExitCodesAndSignals() async throws {
        let failing = try TerminalProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "exit 3"]))
        #expect(await failing.waitForExit() == .exited(3))
        #expect(await !failing.isRunning)
        let killed = try TerminalProcess(
            launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "kill -KILL $$"])
        )
        #expect(await killed.waitForExit() == .signaled(SIGKILL))
    }

    @Test func keepsRawOutputOfQuickCommands() async throws {
        let terminal = try TerminalProcess(
            launching: AgentCommand(executable: "/usr/bin/printf", arguments: ["\\033[31mred\\033[0m\\nend"])
        )
        #expect(await terminal.waitForExit() == .exited(0))
        #expect(terminal.output == TerminalOutput(bytes: Data("\u{1B}[31mred\u{1B}[0m\r\nend".utf8)))
    }

    @Test func retainsQuickOutputWhenReaderRegistrationIsDelayed() async throws {
        let queue = DispatchQueue(label: "Agenthesia.TerminalProcessTests.delayed-reader")
        queue.suspend()
        let terminal: TerminalProcess
        do {
            terminal = try TerminalProcess(
                launching: AgentCommand(executable: "/usr/bin/printf", arguments: ["captured-output\\n"]),
                readerQueue: queue,
                afterSpawn: { pid in
                    let exited = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
                    exited.setEventHandler {
                        exited.cancel(); queue.resume()
                    }
                    exited.resume()
                }
            )
        } catch {
            queue.resume()
            throw error
        }
        #expect(await terminal.waitForExit() == .exited(0))
        #expect(terminal.output == TerminalOutput(bytes: Data("captured-output\r\n".utf8)))
    }

    @Test func retainsOnlyTheNewestBytesWithinTheLimit() async throws {
        let script = "/usr/bin/awk 'BEGIN { for (i=0; i<5000; i++) printf \"x\"; printf \"END\" }'"
        let terminal = try TerminalProcess(
            launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]),
            outputLimit: 100
        )
        #expect(await terminal.waitForExit() == .exited(0))
        let output = terminal.output
        #expect(output.truncated)
        #expect(output.bytes == Data((String(repeating: "x", count: 97) + "END").utf8))

        let exact = try TerminalProcess(
            launching: AgentCommand(executable: "/usr/bin/printf", arguments: ["12345"]),
            outputLimit: 5
        )
        #expect(await exact.waitForExit() == .exited(0))
        #expect(exact.output == TerminalOutput(bytes: Data("12345".utf8)))
    }

    @Test func exposesOutputWhileRunningAndNeverWritesInput() async throws {
        let terminal = try TerminalProcess(
            launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "echo ready; read line; echo read"])
        )
        try await waitForOutput("ready", from: terminal)
        try await Task.sleep(for: .milliseconds(100))
        #expect(text(terminal.output) == "ready\n")
        #expect(await terminal.isRunning)
        #expect(await terminal.terminate(gracePeriod: .milliseconds(200)) == .signaled(SIGTERM))
        #expect(await terminal.terminate() == .signaled(SIGTERM))
    }

    @Test func forwardsInputAndTheWindowSize() async throws {
        let terminal = try TerminalProcess(
            launching: AgentCommand(
                executable: "/bin/sh",
                arguments: ["-c", "stty size; read line; echo \"got:$line\"; stty size"]
            ),
            columns: 100,
            rows: 30
        )
        try await waitForOutput("30 100", from: terminal)
        terminal.resize(columns: 120, rows: 40)
        terminal.write(Data("hello\n".utf8))
        #expect(await terminal.waitForExit() == .exited(0))
        let output = text(terminal.output)
        #expect(output.contains("got:hello"))
        #expect(output.hasSuffix("40 120\n"))
        // Input after the end is dropped rather than written to a closed or reused descriptor.
        terminal.write(Data("late\n".utf8))
        terminal.resize(columns: 10, rows: 10)
    }

    @Test func streamsRetainedAndLaterOutputToEachObserver() async throws {
        let terminal = try TerminalProcess(
            launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", "echo one; read line; echo two"])
        )
        try await waitForOutput("one", from: terminal)
        let first = terminal.outputUpdates()
        let second = terminal.outputUpdates()
        terminal.write(Data("\n".utf8))
        #expect(await terminal.waitForExit() == .exited(0))
        for updates in [first, second] {
            var received = Data()
            for await chunk in updates { received += chunk }
            #expect(String(decoding: received, as: UTF8.self) == String(decoding: terminal.output.bytes, as: UTF8.self))
        }
        // An observer arriving after the end gets the retained output and finishes.
        var late = Data()
        for await chunk in terminal.outputUpdates() { late += chunk }
        #expect(text(TerminalOutput(bytes: late)).hasSuffix("two\n"))
    }

    @Test func escalatesToSigkill() async throws {
        let terminal = try TerminalProcess(
            launching: AgentCommand(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; echo ready; while :; do sleep 0.1; done"]
            )
        )
        try await waitForOutput("ready", from: terminal)
        // Escalation is the only way out: the shell ignores SIGTERM, so a missing one hangs until the time limit.
        #expect(await terminal.terminate(gracePeriod: .milliseconds(200)) == .signaled(SIGKILL))
    }

    @Test(arguments: [0, 4])
    func terminatesDescendantsAndBoundsTheOutputWaitAfterTheLeaderExits(observationDelay: Int) async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-terminal-\(UUID().uuidString).pid"
        )
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let file = pidFile.path(percentEncoded: false)
        // The descendant ignores the hangup sent when the leader exits.
        let script = """
            /bin/sh -c 'trap "" HUP TERM; echo $$ > "\(file)"; while :; do /bin/sleep 1; done' &
            attempt=0
            while [ ! -s "\(file)" ] && [ "$attempt" -lt 100 ]; do
                /bin/sleep 0.01
                attempt=$((attempt + 1))
            done
            read release
            echo leader
            """
        let terminal = try TerminalProcess(launching: AgentCommand(executable: "/bin/sh", arguments: ["-c", script]))
        let child: Int32
        do { child = try await waitForChildPID(at: pidFile) } catch {
            _ = await terminal.terminate(gracePeriod: .milliseconds(50))
            throw error
        }
        defer { kill(child, SIGKILL) }
        do { try await Task.sleep(for: .seconds(observationDelay)) } catch {
            _ = await terminal.terminate(gracePeriod: .milliseconds(50))
            throw error
        }
        #expect(getpgid(child) == terminal.processIdentifier)
        terminal.write(Data("release\n".utf8))
        // The descendant retains the pseudo-terminal after the leader exits.
        #expect(await terminal.waitForExit() == .exited(0))
        #expect(text(terminal.output).contains("leader"))
        #expect(await terminal.terminate(gracePeriod: .milliseconds(50)) == .exited(0))
        #expect(try await waitUntilInactive(child))
    }

    private func waitForOutput(_ expected: String, from terminal: TerminalProcess) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !text(terminal.output).contains(expected) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func text(_ output: TerminalOutput) -> String {
        String(decoding: output.bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "agenthesia-terminal-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func executable(_ contents: String, at url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }
}
