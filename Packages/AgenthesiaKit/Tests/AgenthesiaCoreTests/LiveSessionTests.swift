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

    @Test func initialGitRevisionSurvivesStartHistoryAndContinue() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "feature/x"], in: repo)
        try "initial".write(to: repo.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: repo)
        try await git(["commit", "-qm", "Initial"], in: repo)
        let initial = try await git(["rev-parse", "HEAD"], in: repo)
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(
            directory: repo,
            agent: try mock(arguments: ["--reopen"]),
            worktreesRoot: directory.appending(path: "trees")
        )
        let launched = owner.controller?.session
        await owner.close()
        let session = try #require(launched)
        #expect(session.baseRevision == initial)
        #expect(session.baseBranch == "feature/x")
        #expect(try await library.history().first?.baseRevision == initial)
        #expect(try await library.history().first?.baseBranch == "feature/x")
        let resumed = LiveSession(library: library)
        resumed.environment = { (ProcessInfo.processInfo.environment, nil) }
        await resumed.resume(session)
        let continued = resumed.controller?.session
        await resumed.close()
        #expect(continued?.baseRevision == initial)
        #expect(continued?.baseBranch == "feature/x")
    }

    @discardableResult private func git(_ arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let process = Process()
                        process.executableURL = URL(filePath: "/usr/bin/git")
                        process.currentDirectoryURL = directory
                        process.arguments =
                            [
                                "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c",
                                "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                            ] + arguments
                        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                        let output = Pipe()
                        process.standardOutput = output
                        process.standardError = output
                        try process.run()
                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                    }
                )
            }
        }
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

    @Test func submissionReportsDurableAcceptanceAndClearsRecoverableErrors() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(directory: directory, agent: try mock())
        let controller = try #require(owner.controller)
        #expect(await owner.submit(" ") == false)
        #expect(owner.errorMessage != nil)
        #expect(await owner.submit("hello"))
        #expect(owner.errorMessage == nil)
        while controller.status != .idle { await Task.yield() }
        #expect(controller.transcript.items.last?.message?.text == "Echo: hello")
        await owner.close()
        #expect(await owner.submit("closed") == false)
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

    @Test func invalidAdditionalDirectoryHasAReadableLaunchFailure() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "not-a-directory.txt")
        try "text".write(to: file, atomically: true, encoding: .utf8)
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(directory: directory, agent: try mock(), additionalDirectories: [file])
        #expect(owner.errorMessage?.contains("existing directories") == true)
        #expect(owner.errorMessage?.contains(file.lastPathComponent) == true)
        #expect(try await library.history().isEmpty)
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

    @Test func promptErrorsKeepAgentsWithoutResumeOrLoadAlive() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(directory: directory, agent: try mock(arguments: ["--no-resume", "--no-load"]))
        let controller = try #require(owner.controller)
        let record = controller.session
        await owner.send("fail")
        #expect(controller.status == .idle && owner.isLive)
        #expect(owner.activity == .idle && !owner.hasUnseenResult)
        #expect(controller.queuePaused && controller.transcript.items.last?.notice != nil)
        await owner.send("again")
        #expect(owner.controller === controller && controller.session == record)
        #expect(controller.transcript.items.last?.message?.text == "Echo: again")
        await owner.close()
    }

    @Test func closeDuringTurnAndProcessExitFinishCleanup() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for prompt in ["slow", "exit"] {
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

extension LiveSessionTests {
    private func savedSession(
        in directory: URL,
        library: SessionLibrary,
        agent: AgentInstallRecord
    ) async throws -> SessionRecord {
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.start(directory: directory, agent: agent)
        await owner.send("hello")
        let session = try #require(owner.controller?.session)
        await owner.close()
        return session
    }

    @Test func continuesASavedSession() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try await savedSession(in: directory, library: library, agent: try mock(arguments: ["--reopen"]))
        let owner = LiveSession(library: library)
        owner.environment = { (ProcessInfo.processInfo.environment, nil) }
        await owner.resume(session)
        let controller = try #require(owner.controller)
        #expect(owner.errorMessage == nil)
        #expect(controller.status == .idle)
        #expect(owner.workingDirectory?.path == session.workingDirectory)
        #expect(owner.resuming == session && owner.sessionID == session.id)
        await owner.send("again")
        #expect(
            controller.transcript.items.compactMap { $0.message?.text } == [
                "hello", "Echo: hello", "again", "Echo: again",
            ]
        )
        await owner.close()
        #expect(try await library.history().map(\.id) == [session.id])
    }

    @Test func continueFailuresKeepTheHistory() async throws {
        let (directory, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await library.store()
        let cases: [(agent: [String], removeDirectory: Bool, message: String)] = [
            (["--no-resume", "--no-load"], false, "cannot continue saved sessions"),
            ([], false, "Unknown session"),
            (["--reopen"], true, "no longer exists"),
        ]
        for (arguments, removeDirectory, message) in cases {
            let project = directory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let session = try await savedSession(in: project, library: library, agent: try mock(arguments: arguments))
            if removeDirectory { try FileManager.default.removeItem(at: project) }
            let before = try await store.events(in: session.id)
            let owner = LiveSession(library: library)
            owner.environment = { (ProcessInfo.processInfo.environment, nil) }
            await owner.resume(session)
            #expect(owner.errorMessage?.contains(message) == true, "\(arguments)")
            #expect(!owner.isStarting)
            await owner.close()
            #expect(try await store.events(in: session.id) == before)
        }
    }
}
