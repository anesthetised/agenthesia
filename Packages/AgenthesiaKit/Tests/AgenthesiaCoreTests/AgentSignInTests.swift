import ACP
import AgentRuntime
import Darwin
import Foundation
import JSONRPC
import Testing

@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct AgentSignInTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "agh-sign-in-\(UUID())")
        var requests: URL { root.appending(path: "requests") }
        var workingDirectory: URL { root.appending(path: "cwd") }
        var pid: URL { root.appending(path: "pid") }

        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(at: root) }

        func command(
            methods: String = #"[{"id":"login","name":"Test login"}]"#,
            response: String? = #"{"jsonrpc":"2.0","id":2,"result":{}}"#
        ) -> AgentCommand {
            AgentCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    """
                    echo $$ > "$1/pid"
                    pwd -P > "$1/cwd"
                    IFS= read -r line
                    printf '%s\\n' "$line" >> "$1/requests"
                    printf '%s\\n' '\(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":\#(methods)}}"#)'
                    while IFS= read -r line; do
                        printf '%s\\n' "$line" >> "$1/requests"
                        \(response.map { "printf '%s\\n' '\($0)'" } ?? ":")
                    done
                    """,
                    "sh", root.path(percentEncoded: false),
                ],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }

        func messages() throws -> [JSONValue] {
            try String(contentsOf: requests, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
            }
        }

        func mockCommand() throws -> AgentCommand {
            let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
            let binary = try #require(
                [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                    .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            )
            return AgentCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c", #"echo $$ >> "$1/pids"; pwd -P >> "$1/cwds"; shift; exec "$@""#,
                    "sh", root.path(percentEncoded: false), binary.path(percentEncoded: false),
                    "--auth", "--auth-file", root.appending(path: "signed-in").path(percentEncoded: false),
                ],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }

        func assertMockClean(
            processCount: Int,
            directoryCount: Int = 1,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let directories = try String(contentsOf: root.appending(path: "cwds"), encoding: .utf8).split(
                separator: "\n"
            )
            #expect(directories.count == processCount, sourceLocation: sourceLocation)
            #expect(Set(directories).count == directoryCount, sourceLocation: sourceLocation)
            for directory in directories {
                #expect(!FileManager.default.fileExists(atPath: String(directory)), sourceLocation: sourceLocation)
            }
            let pids = try String(contentsOf: root.appending(path: "pids"), encoding: .utf8).split(separator: "\n")
            for value in pids {
                let pid = try #require(Int32(value))
                #expect(kill(pid, 0) == -1 && errno == ESRCH, sourceLocation: sourceLocation)
            }
        }

        func assertClean(sourceLocation: SourceLocation = #_sourceLocation) throws {
            let directory = try String(contentsOf: workingDirectory, encoding: .utf8).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            #expect(!FileManager.default.fileExists(atPath: directory), sourceLocation: sourceLocation)
            let pid = try #require(
                Int32(String(contentsOf: pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            )
            #expect(kill(pid, 0) == -1 && errno == ESRCH, sourceLocation: sourceLocation)
        }
    }

    @Test func authenticatesWithoutCreatingASessionAndCleansUpBeforeSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let flow = AgentSignIn(name: "Test") { _ in (fixture.command(), nil) }
        await flow.prepare()
        #expect(flow.state == .ready)
        #expect(flow.methods.compactMap(\.id) == ["login"])
        await flow.signIn(with: "login")
        #expect(flow.state == .completed)
        let messages = try fixture.messages()
        #expect(messages.compactMap { $0["method"]?.stringValue } == ["initialize", "authenticate"])
        #expect(messages.first?["params"]?["clientCapabilities"]?["auth"]?["terminal"] == true)
        #expect(messages.first?["params"]?["clientCapabilities"]?["fs"] == nil)
        try fixture.assertClean()
        await flow.close()
    }

    @Test func authenticationErrorsAreNotSuccessAndRetryFetchesMethodsAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = fixture.command(
            response: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Please try again"}}"#
        )
        let flow = AgentSignIn(name: "Test") { _ in (command, nil) }
        await flow.prepare()
        await flow.signIn(with: "login")
        #expect(flow.state == .failed("Please try again"))
        try fixture.assertClean()
        await flow.prepare()
        #expect(flow.state == .ready)
        #expect(
            try fixture.messages().compactMap { $0["method"]?.stringValue } == [
                "initialize", "authenticate", "initialize",
            ]
        )
        await flow.close()
        try fixture.assertClean()
    }

    @Test(arguments: ["[]", #"[{"id":"future","name":"Future","type":"_future"}]"#])
    func absentAndUnsupportedMethodsCannotReportSuccess(methods: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let flow = AgentSignIn(name: "Test") { _ in (fixture.command(methods: methods), nil) }
        await flow.prepare()
        await flow.signIn(with: "missing")
        await flow.signIn(with: "future")
        #expect(flow.state == .ready)
        #expect(try fixture.messages().count == 1)
        await flow.close()
        try fixture.assertClean()
    }

    @Test(arguments: ["yes", "skip", "no"])
    func terminalReportsItsResultAndReinitializesOnlyOnSuccess(answer: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try fixture.mockCommand()
        let flow = AgentSignIn(name: "Mock") { _ in (command, nil) }
        await flow.prepare()
        #expect(flow.methods.compactMap(\.id) == ["mock-login", "mock-terminal"])
        let signingIn = Task { await flow.signIn(with: "mock-terminal") }
        let terminal = try await waitFor { flow.terminal }
        var output = ""
        for await chunk in terminal.output() {
            output += String(decoding: chunk, as: UTF8.self)
            if output.contains("Type yes") { break }
        }
        terminal.write(Data("\(answer)\n".utf8))
        await signingIn.value
        if answer == "no" {
            #expect(flow.state == .failed("Sign-in exited with code 1."))
            #expect(flow.terminal === terminal)
            #expect(terminal.exitMessage == "Sign-in exited with status 1.")
            try fixture.assertMockClean(processCount: 2)
            flow.dismissTerminal()
            #expect(flow.terminal == nil)
            await flow.prepare()
            #expect(flow.state == .ready)
            #expect(flow.terminal == nil)
            await flow.close()
        } else {
            // A successful login command is not proof of persistent credentials ("skip" writes none).
            #expect(flow.state == .completed)
            #expect(flow.terminal == nil)
            await flow.close()
        }
        try fixture.assertMockClean(processCount: 3, directoryCount: answer == "no" ? 2 : 1)
        #expect(
            FileManager.default.fileExists(atPath: fixture.root.appending(path: "signed-in").path) == (answer == "yes")
        )
    }

    @Test func closeStopsAnInteractiveTerminalAndCannotReportSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try fixture.mockCommand()
        let flow = AgentSignIn(name: "Mock") { _ in (command, nil) }
        await flow.prepare()
        let signingIn = Task { await flow.signIn(with: "mock-terminal") }
        let terminal = try await waitFor { flow.terminal }
        for await chunk in terminal.output() {
            if String(decoding: chunk, as: UTF8.self).contains("Type yes") { break }
        }
        await flow.close()
        await signingIn.value
        #expect(flow.state == .closed)
        #expect(flow.terminal == nil)
        try fixture.assertMockClean(processCount: 2)
    }

    @Test func cancellingTheCallerStopsAPendingAuthenticate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let flow = AgentSignIn(name: "Test") { _ in (fixture.command(response: nil), nil) }
        await flow.prepare()
        let signingIn = Task { await flow.signIn(with: "login") }
        _ = try await waitFor { (try? fixture.messages().count) == 2 ? true : nil }
        signingIn.cancel()
        await signingIn.value
        _ = try await waitFor { flow.state == .closed ? true : nil }
        try fixture.assertClean()
    }

    @Test func closeWaitsForAProcessStillBeingLaunched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = SignInGate()
        let flow = AgentSignIn(
            name: "Test",
            launch: { command in
                let process = try await Task.detached { try AgentProcess(launching: command) }.value
                await gate.wait(directory: command.currentDirectory, process: process)
                return process
            },
            prepare: { _ in (fixture.command(), nil) }
        )
        let preparing = Task { await flow.prepare() }
        await gate.waitUntilEntered()
        let process = try #require(gate.process)
        let directory = try #require(gate.directory)
        #expect(await process.isRunning)
        let closing = Task { await flow.close() }
        _ = try await waitFor { flow.state == .closing ? true : nil }
        gate.release()
        await closing.value
        await preparing.value
        #expect(flow.state == .closed)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(await process.isRunning == false)
        #expect(kill(process.processIdentifier, 0) == -1 && errno == ESRCH)
    }

    @Test func closeWaitsForALeaseBeingAcquiredAndReleasesIt() async throws {
        let fixture = try InstalledMockFixture()
        defer { fixture.remove() }
        let installation = try await fixture.installer.install(fixture.agent(version: "1.0.0"))
        let gate = SignInGate()
        let flow = AgentSignIn(name: "Mock") { directory in
            let lease = try await fixture.installer.acquire(installation, directory: directory)
            await gate.wait(directory: directory)
            return (lease.command, lease)
        }
        let preparing = Task { await flow.prepare() }
        await gate.waitUntilEntered()
        await #expect(throws: AgentInstallation.Failure.installationInUse) {
            try await fixture.installer.remove(installation)
        }
        let closing = Task { await flow.close() }
        _ = try await waitFor { flow.state == .closing ? true : nil }
        let directory = try #require(gate.directory)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        gate.release()
        await closing.value
        await preparing.value
        #expect(flow.state == .closed)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try await fixture.library.history().isEmpty)
        try await fixture.installer.remove(installation)
    }

    @Test func initializeTimeoutCleansUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = AgentCommand(
            executable: "/bin/sh",
            arguments: [
                "-c", #"echo $$ > "$1/pid"; pwd -P > "$1/cwd"; while read line; do :; done"#, "sh", fixture.root.path,
            ],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let flow = AgentSignIn(name: "Silent", timeout: .seconds(1)) { _ in (command, nil) }
        await flow.prepare()
        #expect(flow.state == .failed(AgentProbe.Failure.timedOut(seconds: 1).localizedDescription))
        try fixture.assertClean()
        await flow.close()
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Not ACP"}}"#,
        "",
    ])
    func initializationFailureNeverOffersMethods(response: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = AgentCommand(
            executable: "/bin/sh",
            arguments: ["-c", "read line; printf '%s\\n' '$response'".replacing("$response", with: response)]
        )
        let flow = AgentSignIn(name: "Test") { _ in (command, nil) }
        await flow.prepare()
        guard case .failed(let message) = flow.state else { Issue.record("\(flow.state)"); await flow.close(); return }
        if response.contains("protocolVersion") {
            #expect(message == AgentProbe.Failure.unsupportedProtocol(2).localizedDescription)
        } else if response.contains("Not ACP") {
            #expect(message == "Not ACP")
        } else {
            #expect(message.contains("closed its connection"))
        }
        #expect(flow.methods.isEmpty)
        await flow.close()
    }

    @Test func aMissingExecutableReleasesItsTemporaryDirectory() async throws {
        let gate = SignInGate()
        let flow = AgentSignIn(name: "Missing") { directory in
            await gate.wait(directory: directory)
            return (AgentCommand(executable: "/nonexistent/agent"), nil)
        }
        let preparing = Task { await flow.prepare() }
        await gate.waitUntilEntered()
        let directory = try #require(gate.directory)
        gate.release()
        await preparing.value
        guard case .failed = flow.state else { Issue.record("\(flow.state)"); await flow.close(); return }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await flow.close()
    }

    @Test func anAgentExitingWhileMethodsAreShownIsCleanedUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = AgentCommand(
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"echo $$ > "$1/pid"; pwd -P > "$1/cwd"; read line; echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":[]}}'; while [ ! -f "$1/exit" ]; do sleep 0.01; done"#,
                "sh", fixture.root.path,
            ]
        )
        let flow = AgentSignIn(name: "Test") { _ in (command, nil) }
        await flow.prepare()
        #expect(flow.state == .ready)
        try Data().write(to: fixture.root.appending(path: "exit"))
        do {
            _ = try await waitFor {
                if case .failed = flow.state { true } else { nil }
            }
        } catch { await flow.close(); throw error }
        try fixture.assertClean()
        await flow.close()
    }

    private func waitFor<T>(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ value: () -> T?
    ) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let value = value() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(value(), sourceLocation: sourceLocation)
    }
}

@MainActor private final class SignInGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    var directory: URL?
    var process: AgentProcess?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(directory: URL? = nil, process: AgentProcess? = nil) async {
        self.directory = directory
        self.process = process
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            for waiter in enteredWaiters { waiter.resume() }
            enteredWaiters.removeAll()
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() { continuation?.resume(); continuation = nil }
}
