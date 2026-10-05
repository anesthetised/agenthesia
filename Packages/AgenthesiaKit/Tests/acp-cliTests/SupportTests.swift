import ACP
import AgentRuntime
import Foundation
import JSONRPC
import Testing

@testable import acp_cli

@Suite struct CLIFileSystemTests {
    @Test func readsAndWritesInsideTheRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cli-fs-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = CLIFileSystem(root: root)
        let file = root.appending(path: "a.txt").path(percentEncoded: false)
        try await fs.writeTextFile(at: file, content: "one\ntwo", in: "s")
        #expect(try await fs.readTextFile(at: file, line: 2, limit: nil, in: "s") == "two")
        await #expect(throws: RPCError.self) {
            try await fs.readTextFile(at: "/etc/hosts", line: nil, limit: nil, in: "s")
        }
        await #expect(throws: RPCError.self) { try await fs.writeTextFile(at: "relative", content: "", in: "s") }
    }

    @Test func mapsFailuresToRPCErrors() {
        #expect(CLIFileSystem.rpcError(.notAbsolute("a")).code == RPCError.invalidParamsCode)
        #expect(CLIFileSystem.rpcError(.outsideScope("/a")).message.contains("outside"))
        #expect(CLIFileSystem.rpcError(.notFound("/a")).code == RPCError.resourceNotFoundCode)
        #expect(CLIFileSystem.rpcError(.notText("/a")).message.contains("UTF-8"))
    }
}

@Suite(.timeLimit(.minutes(1))) struct LineReaderTests {
    @Test func deliversLinesThenEnds() async {
        let reader = LineReader(["a", "b"].async)
        #expect(await reader.next() == "a")
        #expect(await reader.next() == "b")
        #expect(await reader.next() == nil)
        #expect(await reader.next() == nil)
    }

    @Test func cancellingAWaitKeepsTheStream() async throws {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let reader = LineReader(lines)
        let waiting = Task { await reader.next() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        #expect(await waiting.value == nil)
        continuation.yield("later")
        #expect(await reader.next() == "later")

        let interrupted = Task { await reader.next() }
        try await Task.sleep(for: .milliseconds(20))
        await reader.interrupt()
        #expect(await interrupted.value == nil)
        continuation.yield("after interrupt")
        continuation.finish()
        #expect(await reader.next() == "after interrupt")

        let cancelledBeforeWaiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await reader.next()
        }
        #expect(await cancelledBeforeWaiting.value == nil)
    }
}

@Suite struct CLIDelegateTests {
    let options: [ACP.PermissionOption] = [.init(optionId: "ok", name: "OK", kind: .allowOnce)]

    @Test func asksUntilTheAnswerIsValid() async {
        let delegate = CLIDelegate(console: Console(style: .plain), input: LineReader(["nope", "1"].async))
        await delegate.sessionUpdate(.toolCall(.init(toolCallId: "c", title: "Write")), in: "s")
        #expect(
            await delegate.requestPermission(for: .init(toolCallId: "c"), options: options, in: "s") == .selected("ok")
        )
    }

    @Test func endOfInputOrNoOptionsCancel() async {
        let delegate = CLIDelegate(console: Console(style: .plain), input: LineReader([String]().async))
        #expect(
            await delegate.requestPermission(for: .init(toolCallId: "c", title: "T"), options: options, in: "s")
                == .cancelled
        )
        #expect(await delegate.requestPermission(for: .init(toolCallId: "c"), options: [], in: "s") == .cancelled)
    }
}

@Suite struct CommandHelperTests {
    @Test func terminalAuthAppendsArgumentsAndEnvironment() {
        let base = AgentCommand(executable: "npx", arguments: ["agent"], environment: ["A": "1"])
        let method = ACP.TerminalAuthMethod(id: "t", name: "T", args: ["--login"], env: ["B": "2"])
        let command = Login.command(base, adding: method)
        #expect(command.arguments == ["agent", "--login"])
        #expect(command.environment == ["A": "1", "B": "2"])
        let plain = Login.command(base, adding: .init(id: "t", name: "T"))
        #expect(plain.arguments == ["agent"])
        #expect(plain.environment == ["A": "1"])
    }

    @Test func formatsSessions() {
        #expect(Sessions.format([]) == ["No sessions."])
        #expect(
            Sessions.format([
                .init(sessionId: "s", cwd: "/p", title: "T", updatedAt: "now"), .init(sessionId: "u", cwd: "/q"),
            ])
                == ["s  now  T  /p", "u  -  (untitled)  /q"]
        )
    }

    @Test func explainsAuthentication() {
        let profile = ACP.AgentProfile(
            protocolVersion: 1,
            authMethods: [
                .agent(.init(id: "a", name: "Agent login")),
                .terminal(.init(id: "t", name: "Terminal login")),
                .unknown(["id": "x"]),
            ]
        )
        let help = authHelp(profile, command: ["npx", "agent"])
        #expect(help.contains("a  Agent login"))
        #expect(help.contains("t  Terminal login (in the terminal)"))
        #expect(help.contains("x  (unsupported)"))
        #expect(help.contains("acp-cli login --method a -- npx agent"))
        #expect(authHelp(.init(protocolVersion: 1), command: []).contains("no method"))
    }

    @Test func explainsAgentsThatExitEarly() async {
        #expect(
            ConnectedAgent.exitedEarly(.exited(127), log: [])
                == "The agent exited with code 127 before it finished initializing."
        )
        #expect(ConnectedAgent.exitedEarly(.exited(1), log: ["boom"]).hasSuffix("Its last output:\n  boom"))
        let log = AgentLog()
        for index in 0..<12 {
            await log.append("line \(index)")
        }
        #expect(await log.lines.first == "line 2")
        #expect(await log.lines.count == 10)
    }

    @Test func agentOptionsBuildTheCommand() throws {
        let options = try AgentOptions.parse(["--cwd", "/tmp", "--", "agent", "--acp"])
        #expect(options.agentCommand.executable == "agent")
        #expect(options.agentCommand.arguments == ["--acp"])
        #expect(options.directory.path(percentEncoded: false) == "/tmp/")
        #expect(throws: (any Error).self) { try AgentOptions.parse([]) }
    }
}
