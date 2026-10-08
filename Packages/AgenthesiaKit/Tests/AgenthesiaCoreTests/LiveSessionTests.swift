import ACP
import Foundation
import Persistence
import Testing

@testable import AgenthesiaCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveSessionTests {
    private func fixture() throws -> (URL, SessionLibrary) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "live-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, SessionLibrary(databaseURL: directory.appending(path: "data/history.sqlite")))
    }

    private func mock(arguments: [String] = []) throws -> AgentInstallRecord {
        let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
        let binary = try #require(
            [".build/debug/MockAgent", ".build/out/Products/Debug/MockAgent"]
                .map { package.appending(path: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        return AgentInstallRecord(name: "Mock", executable: binary.path, arguments: arguments)
    }

    @Test func echoStopCloseAndReplay() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(directory: directory, agent: try mock())
        let controller = try #require(owner.controller)
        #expect(controller.status == .idle)
        await owner.send("hello")
        #expect(controller.transcript.items.last?.message?.text == "Echo: hello")
        let turn = Task { await owner.send("slow") }
        while controller.status == .idle { await Task.yield() }
        await owner.stop()
        await turn.value
        #expect(controller.transcript.lastStopReason == .cancelled)
        await owner.close()
        await owner.close()
        #expect(controller.status == .closed)
        let history = try await library.history()
        #expect(history.count == 1)
        let restored = try await SessionController.restore(id: controller.session.id, store: library.store())
        #expect(restored.transcript == controller.transcript)
        #expect(restored.status == .readOnly)
    }

    @Test func mockAgentPermissionAnswerContinuesTheTurnAndReplays() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(directory: directory, agent: try mock())
        let controller = try #require(owner.controller)
        let path = directory.appending(path: "written.txt").path
        let turn = Task { await owner.send("write \(path) text") }
        while controller.pendingPermissions.isEmpty { await Task.yield() }
        let request = controller.pendingPermissions[0]
        #expect(request.options.map(\.kind) == [.allowOnce, .rejectOnce])
        #expect(controller.answerPermission(request.id, with: "allow"))
        await turn.value
        #expect(controller.status == .idle)
        #expect(controller.transcript.lastStopReason == .endTurn)
        #expect(controller.transcript.items.compactMap(\.toolCall).first?.status == .completed)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "text")
        await owner.send("read \(path)")
        let read = controller.transcript.items.compactMap(\.toolCall).last
        #expect(read?.status == .completed)
        #expect(read?.content == [.content(.init(content: .init(text: "text")))])
        await owner.send("hello")
        #expect(controller.transcript.items.last?.message?.text == "Echo: hello")
        let pendingTurn = Task { await owner.send("write \(path) again") }
        while controller.pendingPermissions.isEmpty { await Task.yield() }
        await owner.close()
        await pendingTurn.value
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "text")
        let rows = controller.transcript.items.compactMap(\.permission)
        #expect(rows.map(\.outcome) == [.selected("allow"), .cancelled])
        #expect(rows.first?.selectedOption?.kind == .allowOnce)
        let restored = try await SessionController.restore(id: controller.session.id, store: library.store())
        #expect(restored.transcript == controller.transcript)
        #expect(restored.pendingPermissions.isEmpty)
    }

    @Test func failedLaunchAndAuthenticationAreVisible() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for agent in [
            AgentInstallRecord(name: "Missing", executable: "/does-not-exist"), try mock(arguments: ["--auth"]),
        ] {
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            await owner.start(directory: directory, agent: agent)
            #expect(owner.errorMessage != nil)
            #expect(!owner.isStarting)
            await owner.close()
        }
        #expect(try await library.history().isEmpty)
    }

    @Test func missingExecutableFailsBeforeCreatingAWorktree() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(filePath: "/bin/sh")
        git.arguments = [
            "-c",
            "git init -q && git -c user.name=T -c user.email=t@example.com -c commit.gpgsign=false "
                + "commit -q --allow-empty -m Initial",
        ]
        git.currentDirectoryURL = repo
        // Waiting synchronously would block the main actor shared by the other suites.
        let status = try await withCheckedThrowingContinuation { continuation in
            git.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try git.run() } catch { continuation.resume(throwing: error) }
        }
        #expect(status == 0)
        let trees = directory.appending(path: "trees")
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(
            directory: repo,
            agent: AgentInstallRecord(name: "Missing", executable: "agenthesia-missing-agent"),
            worktreesRoot: trees
        )
        #expect(owner.errorMessage?.contains("agenthesia-missing-agent") == true)
        #expect(!FileManager.default.fileExists(atPath: trees.path))
        await owner.close()
    }

    @Test func executablesResolveLikeTheRuntime() {
        #expect(LiveSession.isExecutable("/bin/sh", path: nil))
        #expect(LiveSession.isExecutable("sh", path: "/does-not-exist:/bin"))
        #expect(!LiveSession.isExecutable("sh", path: nil))
        #expect(!LiveSession.isExecutable("/does-not-exist", path: "/bin"))
    }

    @Test func closeDuringEnvironmentResolutionNeverLaunches() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LiveSession(library: library)
        let gate = EnvironmentGate()
        owner.environment = { (await gate.wait(), nil) }
        let agent = try mock()
        let start = Task { await owner.start(directory: directory, agent: agent) }
        while !gate.entered { await Task.yield() }
        let close = Task { await owner.close() }
        while !owner.isClosed { await Task.yield() }
        gate.release()
        await close.value
        await start.value
        #expect(owner.controller == nil)
        #expect(owner.errorMessage == nil)
        #expect(try await library.history().isEmpty)
    }

    @Test func closeDuringTurnAndTurnFailureFinishCleanup() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for prompt in ["slow", "fail"] {
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            await owner.start(directory: directory, agent: try mock())
            let controller = try #require(owner.controller)
            let turn = Task { await owner.send(prompt) }
            if prompt == "slow" {
                while controller.status == .idle { await Task.yield() }
                await owner.close()
                #expect(owner.errorMessage == nil)
            } else {
                await turn.value
                #expect(owner.errorMessage != nil)
                await owner.close()
            }
            await turn.value
            #expect(controller.status == .closed)
        }
    }
}

@MainActor private final class EnvironmentGate {
    var entered = false
    var continuation: CheckedContinuation<[String: String], Never>?
    func wait() async -> [String: String] {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: ProcessInfo.processInfo.environment) }
}

extension LiveSessionTests {
    @Test func unexpectedIdleExitAndWindowCloseReapTheProcess() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for terminateExternally in [true, false] {
            let pidFile = directory.appending(path: UUID().uuidString)
            let agent = AgentInstallRecord(
                name: "Mock",
                executable: "/bin/sh",
                arguments: [
                    "-c", "echo $$ > \"$1\"; exec \"$2\"", "test", pidFile.path, try mock().executable,
                ]
            )
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, "Test environment diagnostic") }
            await owner.start(directory: directory, agent: agent)
            let controller = try #require(owner.controller)
            #expect(controller.status == .idle)
            #expect(owner.diagnostic == "Test environment diagnostic")
            let pid = try #require(
                Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            )
            if terminateExternally {
                #expect(kill(pid, SIGTERM) == 0)
                while controller.status != .closed { await Task.yield() }
                #expect(owner.errorMessage != nil)
            }
            await owner.close()
            #expect(kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
        #expect(try await library.store().projects().count == 1)
    }
}
